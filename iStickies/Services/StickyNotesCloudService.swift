import CloudKit
import Foundation
#if os(macOS)
import Security
#endif

struct CloudSyncConflict: Sendable {
    let localNoteID: String
    let remoteNote: StickyNote
}

struct CloudSyncBatchResult: Sendable {
    var savedNotes: [StickyNote] = []
    var deletedNoteIDs: [String] = []
    var pendingNotesRequiringRetry: [StickyNote] = []
    var conflicts: [CloudSyncConflict] = []
    var failureMessage: String?
}

struct CloudRemoteSnapshot: Sendable, Equatable {
    var notes: [StickyNote]
    var completeness: CloudRemoteSnapshotCompleteness

    static func complete(notes: [StickyNote]) -> CloudRemoteSnapshot {
        CloudRemoteSnapshot(notes: notes, completeness: .complete)
    }
}

enum CloudRemoteSnapshotCompleteness: Sendable, Equatable {
    case complete
    case unavailable(String)
    case partial(String)

    var allowsRemoteDeletions: Bool {
        self == .complete
    }

    var failureMessage: String? {
        switch self {
        case .complete:
            return nil
        case let .partial(message), let .unavailable(message):
            return message
        }
    }
}

protocol StickyNotesCloudSyncing: Sendable {
    func restore(stateSerializationData: Data?) async
    func currentStateSerializationData() async -> Data?
    func fetchAllNotes() async throws -> CloudRemoteSnapshot
    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult
}

enum StickyNotesCloudServiceFactory {
    static func makeDefaultService() -> any StickyNotesCloudSyncing {
        guard hasCloudKitEntitlement else {
            return DisabledStickyNotesCloudService()
        }

        return CloudKitStickyNotesCloudService()
    }

    private static var hasCloudKitEntitlement: Bool {
        #if !os(macOS)
        // SecTask entitlement inspection is not available to Swift on iOS builds.
        // The app target already declares CloudKit entitlements for iPhone/iPad.
        return true
        #else
        guard let task = SecTaskCreateFromSelf(nil) else {
            return false
        }

        let entitlement = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        )

        guard let services = entitlement as? [String] else {
            return false
        }

        return services.contains("CloudKit") || services.contains("CloudKit-Anonymous")
        #endif
    }
}

actor DisabledStickyNotesCloudService: StickyNotesCloudSyncing {
    func restore(stateSerializationData: Data?) async {}

    func currentStateSerializationData() async -> Data? {
        nil
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        CloudRemoteSnapshot(
            notes: [],
            completeness: .unavailable("CloudKit is unavailable.")
        )
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        CloudSyncBatchResult()
    }
}

actor CloudKitStickyNotesCloudService: StickyNotesCloudSyncing {
    private let database: CKDatabase

    private var syncEngine: CKSyncEngine?
    private var stateSerializationData: Data?
    private var remoteNotesByID: [String: StickyNote] = [:]
    private var pendingNotesByID: [String: StickyNote] = [:]
    private var sendBatchTracker = CloudKitSendBatchTracker()
    private var didResolveZoneExistence = false
    private var zoneExistsRemotely = false
    private var hadPersistedSyncStateSerialization = false
    private var didHydrateRemoteZoneSnapshot = false
    private var needsRemoteZoneSnapshotHydration = false
    private var didAttemptLegacyDefaultZoneImport = false
    private var remoteSnapshotIssueMessages: [String] = []

    init(container: CKContainer = CloudKitStickyNotesCloudService.defaultContainer()) {
        database = container.privateCloudDatabase
    }

    private static func defaultContainer() -> CKContainer {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .default()
        }

        return CKContainer(identifier: "iCloud.\(bundleIdentifier)")
    }

    func restore(stateSerializationData: Data?) async {
        guard syncEngine == nil else { return }
        self.stateSerializationData = stateSerializationData
        hadPersistedSyncStateSerialization = stateSerializationData != nil
        didHydrateRemoteZoneSnapshot = false
        needsRemoteZoneSnapshotHydration = stateSerializationData != nil
    }

    func currentStateSerializationData() async -> Data? {
        stateSerializationData
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        let syncEngine = try await ensureSyncEngine()
        remoteSnapshotIssueMessages.removeAll()

        do {
            try await syncEngine.fetchChanges()
        } catch {
            return remoteSnapshot(completeness: .unavailable(error.localizedDescription))
        }

        var issueMessages = remoteSnapshotIssueMessages
        remoteSnapshotIssueMessages.removeAll()
        issueMessages.append(contentsOf: try await hydrateRemoteZoneSnapshotIfNeeded())
        issueMessages.append(contentsOf: try await importLegacyDefaultZoneNotesIfNeeded(syncEngine: syncEngine))

        let completeness: CloudRemoteSnapshotCompleteness =
            issueMessages.isEmpty ? .complete : .partial(Self.issueSummary(issueMessages))
        return remoteSnapshot(completeness: completeness)
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        guard !saves.isEmpty || !deletions.isEmpty else {
            return CloudSyncBatchResult()
        }

        do {
            let syncEngine = try await ensureSyncEngine()

            if !saves.isEmpty {
                try await ensureZoneExistsForWrites(syncEngine: syncEngine)
            }

            for note in saves {
                pendingNotesByID[note.id] = note
            }

            let pendingChanges =
                deletions.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID(for: $0)) }
                + saves.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(for: $0.id)) }

            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
            sendBatchTracker.begin(
                expectedSaveNoteIDs: Set(saves.map(\.id)),
                expectedDeleteNoteIDs: Set(deletions)
            )

            do {
                try await syncEngine.sendChanges()
            } catch {
                if !recoverRetriableSaves(from: error) {
                    sendBatchTracker.markFailure(error.localizedDescription)
                }
            }

            return sendBatchTracker.finalize()
        } catch {
            sendBatchTracker.cancel()
            return CloudSyncBatchResult(failureMessage: error.localizedDescription)
        }
    }

    private func ensureSyncEngine() async throws -> CKSyncEngine {
        if let syncEngine {
            return syncEngine
        }

        let restoredState = CloudKitSyncEngineStateRecovery.restore(from: stateSerializationData)
        hadPersistedSyncStateSerialization = restoredState.hadPersistedSyncStateSerialization
        if restoredState.recoveredFromCorruptSerialization {
            stateSerializationData = nil
            didHydrateRemoteZoneSnapshot = false
            needsRemoteZoneSnapshotHydration = true
        }

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: restoredState.stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = false

        let syncEngine = CKSyncEngine(configuration)
        self.syncEngine = syncEngine
        return syncEngine
    }

    private func ensureZoneExistsForWrites(syncEngine: CKSyncEngine) async throws {
        if !didResolveZoneExistence {
            let zoneResults = try await database.recordZones(for: [StickyNotesCloudKitConfig.zoneID])

            didResolveZoneExistence = true
            if let zoneResult = zoneResults[StickyNotesCloudKitConfig.zoneID] {
                switch zoneResult {
                case .success:
                    zoneExistsRemotely = true
                case let .failure(error):
                    if isMissingZoneError(error) {
                        zoneExistsRemotely = false
                    } else {
                        throw error
                    }
                }
            } else {
                zoneExistsRemotely = false
            }
        }

        guard !zoneExistsRemotely else { return }
        syncEngine.state.add(
            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: StickyNotesCloudKitConfig.zoneID))]
        )
    }

    private func importLegacyDefaultZoneNotesIfNeeded(syncEngine: CKSyncEngine) async throws -> [String] {
        guard CloudKitLegacyDefaultZoneImportPolicy.shouldImport(
            hadPersistedSyncStateSerialization: hadPersistedSyncStateSerialization,
            didAttemptLegacyDefaultZoneImport: didAttemptLegacyDefaultZoneImport
        ) else { return [] }

        let query = CKQuery(recordType: StickyNoteRecordMapper.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: StickyNoteRecordMapper.lastModifiedSortKey, ascending: false)]

        let fetchedRecords = try await fetchRecords(query: query, zoneID: CKRecordZone.ID.default)
        let mappedRecords = StickyNoteRecordMapper.map(
            records: fetchedRecords.records,
            expectedZoneID: CKRecordZone.ID.default
        )
        let issueMessages = fetchedRecords.partialFailureMessages + mappedRecords.issueMessages
        didAttemptLegacyDefaultZoneImport = issueMessages.isEmpty
        var importedNoteIDs: [String] = []

        for note in mappedRecords.notesByID.values where remoteNotesByID[note.id] == nil {

            let importedNote = note.markedClean()
            remoteNotesByID[note.id] = importedNote
            pendingNotesByID[note.id] = importedNote
            importedNoteIDs.append(note.id)
        }

        guard !importedNoteIDs.isEmpty else { return issueMessages }

        try await ensureZoneExistsForWrites(syncEngine: syncEngine)
        syncEngine.state.add(
            pendingRecordZoneChanges: importedNoteIDs.map { .saveRecord(recordID(for: $0)) }
        )
        return issueMessages
    }

    private func hydrateRemoteZoneSnapshotIfNeeded() async throws -> [String] {
        guard needsRemoteZoneSnapshotHydration else { return [] }

        let query = CKQuery(recordType: StickyNoteRecordMapper.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: StickyNoteRecordMapper.lastModifiedSortKey, ascending: false)]

        do {
            let fetchedRecords = try await fetchRecords(query: query, zoneID: StickyNotesCloudKitConfig.zoneID)
            let mappedRecords = StickyNoteRecordMapper.map(
                records: fetchedRecords.records,
                expectedZoneID: StickyNotesCloudKitConfig.zoneID
            )
            let issueMessages = fetchedRecords.partialFailureMessages + mappedRecords.issueMessages
            let hydratedNotesByID = mappedRecords.notesByID.mapValues { $0.markedClean() }

            remoteNotesByID = hydratedNotesByID
            didResolveZoneExistence = true
            zoneExistsRemotely = true
            didHydrateRemoteZoneSnapshot = issueMessages.isEmpty
            needsRemoteZoneSnapshotHydration = !issueMessages.isEmpty
            return issueMessages
        } catch {
            guard isMissingZoneError(error) else {
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
                throw error
            }

            remoteNotesByID.removeAll()
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = true
            needsRemoteZoneSnapshotHydration = false
            return []
        }
    }

    private func remoteSnapshot(completeness: CloudRemoteSnapshotCompleteness) -> CloudRemoteSnapshot {
        CloudRemoteSnapshot(
            notes: Array(remoteNotesByID.values).map { $0.markedClean() },
            completeness: completeness
        )
    }

    private func recordID(for noteID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: noteID, zoneID: StickyNotesCloudKitConfig.zoneID)
    }

    private func recordProvider(for recordID: CKRecord.ID) -> CKRecord? {
        guard recordID.zoneID == StickyNotesCloudKitConfig.zoneID,
              let note = pendingNotesByID[recordID.recordName]
        else {
            return nil
        }

        return StickyNoteRecordMapper.record(for: note, zoneID: StickyNotesCloudKitConfig.zoneID)
    }

    private func recoverRetriableSaves(from error: Error) -> Bool {
        let nsError = error as NSError
        guard let partialErrors = nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] else {
            return false
        }

        var recoveredAnySave = false
        var encounteredUnhandledError = false

        for (itemID, itemError) in partialErrors {
            guard let recordID = itemID as? CKRecord.ID else {
                encounteredUnhandledError = true
                continue
            }

            guard recordID.zoneID == StickyNotesCloudKitConfig.zoneID else {
                encounteredUnhandledError = true
                continue
            }

            let itemCKError = itemError as? CKError
            guard itemCKError?.code == .unknownItem,
                  let pendingNote = pendingNotesByID[recordID.recordName]
            else {
                encounteredUnhandledError = true
                continue
            }

            let retriableNote = pendingNote.resettingCloudKitSystemFields()
            pendingNotesByID[recordID.recordName] = retriableNote
            sendBatchTracker.markPendingSaveForRetry(retriableNote)
            recoveredAnySave = true
        }

        return recoveredAnySave && !encounteredUnhandledError
    }

    private func applyFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for modification in event.modifications where modification.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = true
        }

        for deletion in event.deletions where deletion.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = false
            needsRemoteZoneSnapshotHydration = false
            remoteNotesByID.removeAll()
        }
    }

    private func applyFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in event.modifications {
            let record = modification.record
            guard record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID else {
                continue
            }

            guard let note = StickyNoteRecordMapper.note(from: record) else {
                remoteSnapshotIssueMessages.append("A CloudKit record could not be decoded.")
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
                continue
            }

            remoteNotesByID[note.id] = note.markedClean()
        }

        for deletion in event.deletions
        where deletion.recordID.zoneID == StickyNotesCloudKitConfig.zoneID
            && deletion.recordType == StickyNoteRecordMapper.recordType
        {
            remoteNotesByID.removeValue(forKey: deletion.recordID.recordName)
        }
    }

    private func applySentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
        for zone in event.savedZones where zone.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = true
        }

        for failedZoneSave in event.failedZoneSaves where failedZoneSave.zone.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            sendBatchTracker.markFailure(failedZoneSave.error.localizedDescription)
        }

        for deletedZoneID in event.deletedZoneIDs where deletedZoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = false
            needsRemoteZoneSnapshotHydration = false
            remoteNotesByID.removeAll()
        }

        for (zoneID, error) in event.failedZoneDeletes where zoneID == StickyNotesCloudKitConfig.zoneID {
            sendBatchTracker.markFailure(error.localizedDescription)
        }
    }

    private func applySentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        for record in event.savedRecords {
            guard record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID,
                  let note = StickyNoteRecordMapper.note(from: record)
            else {
                continue
            }

            remoteNotesByID[note.id] = note.markedClean()
            pendingNotesByID.removeValue(forKey: note.id)
            sendBatchTracker.markSaved(note)
        }

        for recordID in event.deletedRecordIDs where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName
            remoteNotesByID.removeValue(forKey: noteID)
            pendingNotesByID.removeValue(forKey: noteID)
            sendBatchTracker.markDeleted(noteID: noteID)
        }

        for failedRecordSave in event.failedRecordSaves where failedRecordSave.record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let recordID = failedRecordSave.record.recordID
            let noteID = recordID.recordName

            if failedRecordSave.error.code == .zoneNotFound || failedRecordSave.error.code == .userDeletedZone {
                didResolveZoneExistence = true
                zoneExistsRemotely = false
            }

            if failedRecordSave.error.code == .serverRecordChanged {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                pendingNotesByID.removeValue(forKey: noteID)

                if let serverRecord = failedRecordSave.error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                   let remoteNote = StickyNoteRecordMapper.note(from: serverRecord)
                {
                    let cleanRemoteNote = remoteNote.markedClean()
                    remoteNotesByID[noteID] = cleanRemoteNote
                    sendBatchTracker.markConflict(noteID: noteID, remoteNote: cleanRemoteNote)
                } else if let remoteNote = remoteNotesByID[noteID] {
                    sendBatchTracker.markConflict(noteID: noteID, remoteNote: remoteNote)
                } else {
                    sendBatchTracker.markFailure(failedRecordSave.error.localizedDescription)
                }

                continue
            }

            if failedRecordSave.error.code == .unknownItem {
                if let pendingNote = pendingNotesByID[noteID] {
                    let retriableNote = pendingNote.resettingCloudKitSystemFields()
                    pendingNotesByID[noteID] = retriableNote
                    sendBatchTracker.markPendingSaveForRetry(retriableNote)
                } else {
                    sendBatchTracker.markFailure(failedRecordSave.error.localizedDescription)
                }

                continue
            }

            sendBatchTracker.markFailure(failedRecordSave.error.localizedDescription)
        }

        for (recordID, error) in event.failedRecordDeletes where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName

            if error.code == .unknownItem {
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                remoteNotesByID.removeValue(forKey: noteID)
                pendingNotesByID.removeValue(forKey: noteID)
                sendBatchTracker.markDeleted(noteID: noteID)
                continue
            }

            if error.code == .zoneNotFound || error.code == .userDeletedZone {
                didResolveZoneExistence = true
                zoneExistsRemotely = false
            }

            sendBatchTracker.markFailure(error.localizedDescription)
        }
    }

    private func isMissingZoneError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .zoneNotFound || ckError.code == .userDeletedZone
    }

    private func fetchRecords(query: CKQuery, zoneID: CKRecordZone.ID?) async throws -> CloudFetchedRecords {
        try await withCheckedThrowingContinuation { continuation in
            var collectedRecords: [CKRecord] = []
            var partialFailureMessages: [String] = []

            func run(cursor: CKQueryOperation.Cursor?) {
                let operation: CKQueryOperation
                if let cursor {
                    operation = CKQueryOperation(cursor: cursor)
                } else {
                    operation = CKQueryOperation(query: query)
                    operation.zoneID = zoneID
                }

                operation.resultsLimit = CKQueryOperation.maximumResults
                operation.recordMatchedBlock = { _, result in
                    switch result {
                    case let .success(record):
                        collectedRecords.append(record)
                    case let .failure(error):
                        partialFailureMessages.append(error.localizedDescription)
                    }
                }
                operation.queryResultBlock = { result in
                    switch result {
                    case let .success(nextCursor):
                        if let nextCursor {
                            run(cursor: nextCursor)
                        } else {
                            continuation.resume(
                                returning: CloudFetchedRecords(
                                    records: collectedRecords,
                                    partialFailureMessages: partialFailureMessages
                                )
                            )
                        }
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(operation)
            }

            run(cursor: nil)
        }
    }

    private static func issueSummary(_ issueMessages: [String]) -> String {
        Array(Set(issueMessages)).sorted().joined(separator: " ")
    }
}

extension CloudKitStickyNotesCloudService: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(stateUpdate):
            stateSerializationData = try? JSONEncoder().encode(stateUpdate.stateSerialization)
        case let .accountChange(accountChange):
            switch accountChange.changeType {
            case .signIn:
                remoteNotesByID.removeAll()
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
            case .signOut, .switchAccounts:
                remoteNotesByID.removeAll()
                pendingNotesByID.removeAll()
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
            @unknown default:
                remoteNotesByID.removeAll()
                pendingNotesByID.removeAll()
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
            }
        case let .fetchedDatabaseChanges(fetchedDatabaseChanges):
            applyFetchedDatabaseChanges(fetchedDatabaseChanges)
        case let .fetchedRecordZoneChanges(fetchedRecordZoneChanges):
            applyFetchedRecordZoneChanges(fetchedRecordZoneChanges)
        case let .sentDatabaseChanges(sentDatabaseChanges):
            applySentDatabaseChanges(sentDatabaseChanges)
        case let .sentRecordZoneChanges(sentRecordZoneChanges):
            applySentRecordZoneChanges(sentRecordZoneChanges, syncEngine: syncEngine)
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges.filter { pendingChange in
            context.options.scope.contains(pendingChange)
                && pendingChange.recordID.zoneID == StickyNotesCloudKitConfig.zoneID
        }

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges,
            recordProvider: { [weak self] recordID in
                guard let self else { return nil }
                return await self.recordProvider(for: recordID)
            }
        )
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.prioritizedZoneIDs = [StickyNotesCloudKitConfig.zoneID]
        return options
    }
}

private enum StickyNotesCloudKitConfig {
    static let zoneID = CKRecordZone.ID(zoneName: "StickyNotes")
}

private struct CloudFetchedRecords {
    var records: [CKRecord]
    var partialFailureMessages: [String]
}

struct CloudKitSyncEngineStateRecoveryResult {
    var stateSerialization: CKSyncEngine.State.Serialization?
    var hadPersistedSyncStateSerialization: Bool
    var recoveredFromCorruptSerialization: Bool

    var restoredFromPersistedSyncState: Bool {
        stateSerialization != nil
    }
}

enum CloudKitSyncEngineStateRecovery {
    static func restore(from stateSerializationData: Data?) -> CloudKitSyncEngineStateRecoveryResult {
        guard let stateSerializationData else {
            return CloudKitSyncEngineStateRecoveryResult(
                stateSerialization: nil,
                hadPersistedSyncStateSerialization: false,
                recoveredFromCorruptSerialization: false
            )
        }

        do {
            let stateSerialization = try JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: stateSerializationData
            )
            return CloudKitSyncEngineStateRecoveryResult(
                stateSerialization: stateSerialization,
                hadPersistedSyncStateSerialization: true,
                recoveredFromCorruptSerialization: false
            )
        } catch {
            return CloudKitSyncEngineStateRecoveryResult(
                stateSerialization: nil,
                hadPersistedSyncStateSerialization: true,
                recoveredFromCorruptSerialization: true
            )
        }
    }
}

enum CloudKitLegacyDefaultZoneImportPolicy {
    static func shouldImport(
        hadPersistedSyncStateSerialization: Bool,
        didAttemptLegacyDefaultZoneImport: Bool
    ) -> Bool {
        !hadPersistedSyncStateSerialization && !didAttemptLegacyDefaultZoneImport
    }
}

private extension CKSyncEngine.PendingRecordZoneChange {
    var recordID: CKRecord.ID {
        switch self {
        case let .saveRecord(recordID), let .deleteRecord(recordID):
            return recordID
        @unknown default:
            fatalError("Unhandled CKSyncEngine.PendingRecordZoneChange case")
        }
    }
}
