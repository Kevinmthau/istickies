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

protocol StickyNotesCloudSyncing: Sendable {
    func restore(stateSerializationData: Data?) async
    func currentStateSerializationData() async -> Data?
    func fetchAllNotes() async throws -> [StickyNote]
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

    func fetchAllNotes() async throws -> [StickyNote] {
        []
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
    private var activeSendContext: ActiveSendContext?
    private var didResolveZoneExistence = false
    private var zoneExistsRemotely = false
    private var restoredFromPersistedSyncState = false
    private var didHydrateRemoteZoneSnapshot = false
    private var didAttemptLegacyDefaultZoneImport = false

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
        restoredFromPersistedSyncState = stateSerializationData != nil
        didHydrateRemoteZoneSnapshot = false
    }

    func currentStateSerializationData() async -> Data? {
        stateSerializationData
    }

    func fetchAllNotes() async throws -> [StickyNote] {
        let syncEngine = try await ensureSyncEngine()
        try await syncEngine.fetchChanges()
        try await hydrateRemoteZoneSnapshotIfNeeded()
        try await importLegacyDefaultZoneNotesIfNeeded(syncEngine: syncEngine)
        return Array(remoteNotesByID.values).map { $0.markedClean() }
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
            activeSendContext = ActiveSendContext(
                expectedSaveNoteIDs: Set(saves.map(\.id)),
                expectedDeleteNoteIDs: Set(deletions)
            )

            do {
                try await syncEngine.sendChanges()
            } catch {
                if !recoverRetriableSaves(from: error) {
                    markActiveSendFailure(error.localizedDescription)
                }
            }

            return finalizeActiveSendContext()
        } catch {
            activeSendContext = nil
            return CloudSyncBatchResult(failureMessage: error.localizedDescription)
        }
    }

    private func ensureSyncEngine() async throws -> CKSyncEngine {
        if let syncEngine {
            return syncEngine
        }

        let stateSerialization: CKSyncEngine.State.Serialization?
        if let stateSerializationData {
            stateSerialization = try JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: stateSerializationData
            )
        } else {
            stateSerialization = nil
        }

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: stateSerialization,
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

    private func importLegacyDefaultZoneNotesIfNeeded(syncEngine: CKSyncEngine) async throws {
        guard !restoredFromPersistedSyncState, !didAttemptLegacyDefaultZoneImport else { return }
        didAttemptLegacyDefaultZoneImport = true

        let query = CKQuery(recordType: StickyNote.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: StickyNoteRecordField.lastModified, ascending: false)]

        let legacyRecords = try await fetchRecords(query: query, zoneID: CKRecordZone.ID.default)
        var importedNoteIDs: [String] = []

        for record in legacyRecords {
            guard record.recordID.zoneID == CKRecordZone.ID.default,
                  let note = StickyNote(record: record),
                  remoteNotesByID[note.id] == nil
            else {
                continue
            }

            let importedNote = note.markedClean()
            remoteNotesByID[note.id] = importedNote
            pendingNotesByID[note.id] = importedNote
            importedNoteIDs.append(note.id)
        }

        guard !importedNoteIDs.isEmpty else { return }

        try await ensureZoneExistsForWrites(syncEngine: syncEngine)
        syncEngine.state.add(
            pendingRecordZoneChanges: importedNoteIDs.map { .saveRecord(recordID(for: $0)) }
        )
    }

    private func hydrateRemoteZoneSnapshotIfNeeded() async throws {
        guard restoredFromPersistedSyncState, !didHydrateRemoteZoneSnapshot else { return }

        let query = CKQuery(recordType: StickyNote.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: StickyNoteRecordField.lastModified, ascending: false)]

        do {
            let records = try await fetchRecords(query: query, zoneID: StickyNotesCloudKitConfig.zoneID)
            var hydratedNotesByID: [String: StickyNote] = [:]

            for record in records {
                guard let note = StickyNote(record: record) else { continue }
                hydratedNotesByID[note.id] = note.markedClean()
            }

            remoteNotesByID = hydratedNotesByID
            didResolveZoneExistence = true
            zoneExistsRemotely = true
            didHydrateRemoteZoneSnapshot = true
        } catch {
            guard isMissingZoneError(error) else {
                didHydrateRemoteZoneSnapshot = false
                throw error
            }

            remoteNotesByID.removeAll()
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = true
        }
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

        return note.makeRecord(zoneID: StickyNotesCloudKitConfig.zoneID)
    }

    private func finalizeActiveSendContext() -> CloudSyncBatchResult {
        guard let activeSendContext else {
            return CloudSyncBatchResult()
        }

        var result = CloudSyncBatchResult(
            savedNotes: Array(activeSendContext.savedNotesByID.values),
            deletedNoteIDs: Array(activeSendContext.deletedNoteIDs).sorted(),
            pendingNotesRequiringRetry: Array(activeSendContext.pendingNotesRequiringRetryByID.values),
            conflicts: activeSendContext.conflictsByNoteID.keys.sorted().compactMap { noteID in
                guard let remoteNote = activeSendContext.conflictsByNoteID[noteID] else {
                    return nil
                }

                return CloudSyncConflict(localNoteID: noteID, remoteNote: remoteNote)
            },
            failureMessage: activeSendContext.failureMessage
        )

        let unresolvedRetrySaveIDs = activeSendContext.unresolvedSaveNoteIDs
            .subtracting(activeSendContext.pendingNotesRequiringRetryByID.keys)

        if result.failureMessage == nil,
           (!unresolvedRetrySaveIDs.isEmpty || !activeSendContext.unresolvedDeleteNoteIDs.isEmpty)
        {
            result.failureMessage = "Some CloudKit changes are still pending."
        }

        self.activeSendContext = nil
        return result
    }

    private func markActiveSendFailure(_ message: String) {
        guard var activeSendContext else { return }
        activeSendContext.failureMessage = activeSendContext.failureMessage ?? message
        self.activeSendContext = activeSendContext
    }

    private func markSaved(_ note: StickyNote) {
        guard var activeSendContext else { return }
        guard activeSendContext.expectedSaveNoteIDs.contains(note.id) else { return }

        activeSendContext.savedNotesByID[note.id] = note.markedClean()
        activeSendContext.unresolvedSaveNoteIDs.remove(note.id)
        self.activeSendContext = activeSendContext
    }

    private func markDeleted(noteID: String) {
        guard var activeSendContext else { return }
        guard activeSendContext.expectedDeleteNoteIDs.contains(noteID) else { return }

        activeSendContext.deletedNoteIDs.insert(noteID)
        activeSendContext.unresolvedDeleteNoteIDs.remove(noteID)
        self.activeSendContext = activeSendContext
    }

    private func markConflict(noteID: String, remoteNote: StickyNote) {
        guard var activeSendContext else { return }
        guard activeSendContext.expectedSaveNoteIDs.contains(noteID) else { return }

        activeSendContext.conflictsByNoteID[noteID] = remoteNote.markedClean()
        activeSendContext.unresolvedSaveNoteIDs.remove(noteID)
        self.activeSendContext = activeSendContext
    }

    private func markPendingSaveForRetry(_ note: StickyNote) {
        guard var activeSendContext else { return }
        guard activeSendContext.expectedSaveNoteIDs.contains(note.id) else { return }

        activeSendContext.pendingNotesRequiringRetryByID[note.id] = note
        self.activeSendContext = activeSendContext
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
            markPendingSaveForRetry(retriableNote)
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
            remoteNotesByID.removeAll()
        }
    }

    private func applyFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in event.modifications {
            let record = modification.record
            guard record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID,
                  let note = StickyNote(record: record)
            else {
                continue
            }

            remoteNotesByID[note.id] = note.markedClean()
        }

        for deletion in event.deletions
        where deletion.recordID.zoneID == StickyNotesCloudKitConfig.zoneID
            && deletion.recordType == StickyNote.recordType
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
            markActiveSendFailure(failedZoneSave.error.localizedDescription)
        }

        for deletedZoneID in event.deletedZoneIDs where deletedZoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = false
            remoteNotesByID.removeAll()
        }

        for (zoneID, error) in event.failedZoneDeletes where zoneID == StickyNotesCloudKitConfig.zoneID {
            markActiveSendFailure(error.localizedDescription)
        }
    }

    private func applySentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        for record in event.savedRecords {
            guard record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID,
                  let note = StickyNote(record: record)
            else {
                continue
            }

            remoteNotesByID[note.id] = note.markedClean()
            pendingNotesByID.removeValue(forKey: note.id)
            markSaved(note)
        }

        for recordID in event.deletedRecordIDs where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName
            remoteNotesByID.removeValue(forKey: noteID)
            pendingNotesByID.removeValue(forKey: noteID)
            markDeleted(noteID: noteID)
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
                   let remoteNote = StickyNote(record: serverRecord)
                {
                    let cleanRemoteNote = remoteNote.markedClean()
                    remoteNotesByID[noteID] = cleanRemoteNote
                    markConflict(noteID: noteID, remoteNote: cleanRemoteNote)
                } else if let remoteNote = remoteNotesByID[noteID] {
                    markConflict(noteID: noteID, remoteNote: remoteNote)
                } else {
                    markActiveSendFailure(failedRecordSave.error.localizedDescription)
                }

                continue
            }

            if failedRecordSave.error.code == .unknownItem {
                if let pendingNote = pendingNotesByID[noteID] {
                    let retriableNote = pendingNote.resettingCloudKitSystemFields()
                    pendingNotesByID[noteID] = retriableNote
                    markPendingSaveForRetry(retriableNote)
                } else {
                    markActiveSendFailure(failedRecordSave.error.localizedDescription)
                }

                continue
            }

            markActiveSendFailure(failedRecordSave.error.localizedDescription)
        }

        for (recordID, error) in event.failedRecordDeletes where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName

            if error.code == .unknownItem {
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                remoteNotesByID.removeValue(forKey: noteID)
                pendingNotesByID.removeValue(forKey: noteID)
                markDeleted(noteID: noteID)
                continue
            }

            if error.code == .zoneNotFound || error.code == .userDeletedZone {
                didResolveZoneExistence = true
                zoneExistsRemotely = false
            }

            markActiveSendFailure(error.localizedDescription)
        }
    }

    private func isMissingZoneError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .zoneNotFound || ckError.code == .userDeletedZone
    }

    private func fetchRecords(query: CKQuery, zoneID: CKRecordZone.ID?) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { continuation in
            var collectedRecords: [CKRecord] = []

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
                    if case let .success(record) = result {
                        collectedRecords.append(record)
                    }
                }
                operation.queryResultBlock = { result in
                    switch result {
                    case let .success(nextCursor):
                        if let nextCursor {
                            run(cursor: nextCursor)
                        } else {
                            continuation.resume(returning: collectedRecords)
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
            case .signOut, .switchAccounts:
                remoteNotesByID.removeAll()
                pendingNotesByID.removeAll()
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
            @unknown default:
                remoteNotesByID.removeAll()
                pendingNotesByID.removeAll()
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
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

private struct ActiveSendContext {
    let expectedSaveNoteIDs: Set<String>
    let expectedDeleteNoteIDs: Set<String>
    var savedNotesByID: [String: StickyNote] = [:]
    var deletedNoteIDs: Set<String> = []
    var pendingNotesRequiringRetryByID: [String: StickyNote] = [:]
    var conflictsByNoteID: [String: StickyNote] = [:]
    var failureMessage: String?
    var unresolvedSaveNoteIDs: Set<String>
    var unresolvedDeleteNoteIDs: Set<String>

    init(expectedSaveNoteIDs: Set<String>, expectedDeleteNoteIDs: Set<String>) {
        self.expectedSaveNoteIDs = expectedSaveNoteIDs
        self.expectedDeleteNoteIDs = expectedDeleteNoteIDs
        unresolvedSaveNoteIDs = expectedSaveNoteIDs
        unresolvedDeleteNoteIDs = expectedDeleteNoteIDs
    }
}

private enum StickyNoteRecordField {
    static let content = "content"
    static let titleOverride = "titleOverride"
    static let color = "color"
    static let createdAt = "createdAt"
    static let lastModified = "lastModified"
    static let isOpen = "isOpen"
    static let frameX = "frameX"
    static let frameY = "frameY"
    static let frameWidth = "frameWidth"
    static let frameHeight = "frameHeight"
}

extension StickyNote {
    static let recordType = "StickyNote"

    init?(record: CKRecord) {
        guard record.recordType == StickyNote.recordType,
              let content = record[StickyNoteRecordField.content] as? String,
              let lastModified = record[StickyNoteRecordField.lastModified] as? Date
        else {
            return nil
        }

        // Fall back to server metadata when the deployed schema is missing `createdAt`.
        let createdAt =
            (record[StickyNoteRecordField.createdAt] as? Date)
            ?? record.creationDate
            ?? lastModified

        let color: StickyNoteColor
        if let colorRawValue = record[StickyNoteRecordField.color] as? String,
           let decodedColor = StickyNoteColor(rawValue: colorRawValue)
        {
            color = decodedColor
        } else {
            color = .yellow
        }

        self.init(
            id: record.recordID.recordName,
            content: content,
            titleOverride: record[StickyNoteRecordField.titleOverride] as? String,
            color: color,
            createdAt: createdAt,
            lastModified: lastModified,
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: record.encodedSystemFieldsData()
        )
    }

    func makeRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        let expectedRecordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record =
            restoredRecord(expectedRecordID: expectedRecordID)
            ?? CKRecord(recordType: StickyNote.recordType, recordID: expectedRecordID)

        write(to: record)
        return record
    }

    func write(to record: CKRecord) {
        record[StickyNoteRecordField.content] = content as CKRecordValue
        if let titleOverride, !titleOverride.isEmpty {
            record[StickyNoteRecordField.titleOverride] = titleOverride as CKRecordValue
        } else {
            record[StickyNoteRecordField.titleOverride] = nil
        }
        // Keep writes compatible with the deployed production schema. Shared CloudKit records
        // only store note content metadata; window visibility and frame are local device state.
        record[StickyNoteRecordField.color] = nil
        record[StickyNoteRecordField.createdAt] = nil
        record[StickyNoteRecordField.lastModified] = lastModified as CKRecordValue
        record[StickyNoteRecordField.isOpen] = nil
        record[StickyNoteRecordField.frameX] = nil
        record[StickyNoteRecordField.frameY] = nil
        record[StickyNoteRecordField.frameWidth] = nil
        record[StickyNoteRecordField.frameHeight] = nil
    }

    private func restoredRecord(expectedRecordID: CKRecord.ID) -> CKRecord? {
        guard let cloudKitSystemFieldsData else { return nil }

        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: cloudKitSystemFieldsData)
            unarchiver.requiresSecureCoding = true
            defer { unarchiver.finishDecoding() }

            guard let record = CKRecord(coder: unarchiver),
                  record.recordID == expectedRecordID,
                  record.recordType == StickyNote.recordType
            else {
                return nil
            }

            return record
        } catch {
            return nil
        }
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

private extension CKRecord {
    func encodedSystemFieldsData() -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
