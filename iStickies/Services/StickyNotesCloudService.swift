import CloudKit
import Foundation
import OSLog
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
    case remoteReset(String)

    var allowsRemoteDeletions: Bool {
        self == .complete
    }

    var shouldReuploadLocalNotes: Bool {
        if case .remoteReset = self {
            return true
        }

        return false
    }

    var failureMessage: String? {
        switch self {
        case .complete, .remoteReset:
            return nil
        case let .partial(message), let .unavailable(message):
            return message
        }
    }

    var observabilityName: String {
        switch self {
        case .complete:
            return "complete"
        case .partial:
            return "partial"
        case .unavailable:
            return "unavailable"
        case .remoteReset:
            return "remoteReset"
        }
    }
}

protocol StickyNotesCloudSyncing: Sendable {
    func restore(persistedState: StickyNotesCloudPersistedState) async
    func currentPersistedState() async -> StickyNotesCloudPersistedState
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
    private var persistedState = StickyNotesCloudPersistedState()

    func restore(persistedState: StickyNotesCloudPersistedState) async {
        self.persistedState = persistedState
    }

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        persistedState
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        StickyNotesLog.cloudKit.warning("Disabled CloudKit service returned unavailable snapshot")
        return CloudRemoteSnapshot(
            notes: [],
            completeness: .unavailable("CloudKit is unavailable.")
        )
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        if !saves.isEmpty || !deletions.isEmpty {
            StickyNotesLog.cloudKit.warning(
                """
                Disabled CloudKit service suppressed outgoing changes \
                saveCount: \(saves.count, privacy: .public) \
                deleteCount: \(deletions.count, privacy: .public)
                """
            )
        }
        return CloudSyncBatchResult()
    }
}

actor LocalOnlyStickyNotesCloudService: StickyNotesCloudSyncing {
    private var remoteNotesByID: [String: StickyNote] = [:]

    func restore(persistedState: StickyNotesCloudPersistedState) async {
        remoteNotesByID = Dictionary(uniqueKeysWithValues: persistedState.remoteNotes.map {
            ($0.id, $0.markedClean())
        })
    }

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        StickyNotesCloudPersistedState(remoteNotes: Array(remoteNotesByID.values).map {
            $0.markedClean()
        })
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        CloudRemoteSnapshot.complete(notes: Array(remoteNotesByID.values))
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        var result = CloudSyncBatchResult()

        for note in saves {
            let cleanNote = note.markedClean()
            remoteNotesByID[note.id] = cleanNote
            result.savedNotes.append(cleanNote)
        }

        for id in deletions {
            remoteNotesByID.removeValue(forKey: id)
            result.deletedNoteIDs.append(id)
        }

        return result
    }
}

actor CloudKitStickyNotesCloudService: StickyNotesCloudSyncing {
    private let container: CKContainer
    private let database: CKDatabase

    private var syncEngine: CKSyncEngine?
    private var stateSerializationData: Data?
    private var acceptedAccountIdentifier: String?
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
        self.container = container
        database = container.privateCloudDatabase
    }

    private static func defaultContainer() -> CKContainer {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .default()
        }

        return CKContainer(identifier: "iCloud.\(bundleIdentifier)")
    }

    func restore(persistedState: StickyNotesCloudPersistedState) async {
        guard syncEngine == nil else { return }
        stateSerializationData = persistedState.stateSerializationData
        acceptedAccountIdentifier = persistedState.accountIdentifier
        remoteNotesByID = Dictionary(uniqueKeysWithValues: persistedState.remoteNotes.map {
            ($0.id, $0.markedClean())
        })
        hadPersistedSyncStateSerialization = persistedState.stateSerializationData != nil
        didHydrateRemoteZoneSnapshot = false
        needsRemoteZoneSnapshotHydration = persistedState.stateSerializationData != nil
            && persistedState.remoteNotes.isEmpty
        StickyNotesLog.cloudKit.info(
            """
            Restored CloudKit persisted state hasSyncState: \(persistedState.stateSerializationData != nil, privacy: .public) \
            hasAccount: \(persistedState.accountIdentifier != nil, privacy: .public) \
            remoteCacheCount: \(persistedState.remoteNotes.count, privacy: .public) \
            needsHydration: \(self.needsRemoteZoneSnapshotHydration, privacy: .public)
            """
        )
    }

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        StickyNotesCloudPersistedState(
            stateSerializationData: stateSerializationData,
            accountIdentifier: acceptedAccountIdentifier,
            remoteNotes: needsRemoteZoneSnapshotHydration
                ? []
                : Array(remoteNotesByID.values).map { $0.markedClean() }
        )
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        StickyNotesLog.cloudKit.info(
            """
            CloudKit fetch started remoteCacheCount: \(self.remoteNotesByID.count, privacy: .public) \
            needsHydration: \(self.needsRemoteZoneSnapshotHydration, privacy: .public)
            """
        )
        switch await resolveAccountAccess() {
        case .available:
            break
        case let .unavailable(message), let .changed(message):
            StickyNotesLog.cloudKit.warning(
                "CloudKit fetch unavailable before sync-engine fetch: \(message, privacy: .private)"
            )
            return remoteSnapshot(completeness: .unavailable(message))
        }

        let syncEngine = try await ensureSyncEngine()
        remoteSnapshotIssueMessages.removeAll()

        do {
            try await syncEngine.fetchChanges()
        } catch {
            StickyNotesLog.cloudKit.error(
                "CloudKit fetchChanges failed: \(error.localizedDescription, privacy: .private)"
            )
            return remoteSnapshot(completeness: .unavailable(error.localizedDescription))
        }

        var issueMessages = remoteSnapshotIssueMessages
        remoteSnapshotIssueMessages.removeAll()
        let hydrationOutcome = try await hydrateRemoteZoneSnapshotIfNeeded()
        if let remoteResetMessage = hydrationOutcome.remoteResetMessage {
            StickyNotesLog.cloudKit.warning(
                "CloudKit remote zone reset detected: \(remoteResetMessage, privacy: .private)"
            )
            return remoteSnapshot(completeness: .remoteReset(remoteResetMessage))
        }

        issueMessages.append(contentsOf: hydrationOutcome.issueMessages)
        issueMessages.append(contentsOf: try await importLegacyDefaultZoneNotesIfNeeded(syncEngine: syncEngine))

        let completeness: CloudRemoteSnapshotCompleteness =
            issueMessages.isEmpty ? .complete : .partial(Self.issueSummary(issueMessages))
        if issueMessages.isEmpty {
            StickyNotesLog.cloudKit.info(
                """
                CloudKit fetch completed completeness: \(completeness.observabilityName, privacy: .public) \
                remoteNoteCount: \(self.remoteNotesByID.count, privacy: .public)
                """
            )
        } else {
            StickyNotesLog.cloudKit.warning(
                """
                CloudKit fetch completed with partial snapshot issueCount: \(issueMessages.count, privacy: .public) \
                remoteNoteCount: \(self.remoteNotesByID.count, privacy: .public)
                """
            )
        }
        return remoteSnapshot(completeness: completeness)
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        guard !saves.isEmpty || !deletions.isEmpty else {
            StickyNotesLog.cloudKit.debug("CloudKit syncChanges skipped because there are no pending changes")
            return CloudSyncBatchResult()
        }
        StickyNotesLog.cloudKit.info(
            """
            CloudKit syncChanges started saveCount: \(saves.count, privacy: .public) \
            deleteCount: \(deletions.count, privacy: .public)
            """
        )

        switch await resolveAccountAccess() {
        case .available:
            break
        case let .unavailable(message), let .changed(message):
            StickyNotesLog.cloudKit.warning(
                "CloudKit syncChanges unavailable before send: \(message, privacy: .private)"
            )
            return CloudSyncBatchResult(failureMessage: message)
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
                let recovered = recoverRetriableSaves(from: error)
                StickyNotesLog.cloudKit.error(
                    """
                    CloudKit sendChanges failed recoveredRetriableSaves: \(recovered, privacy: .public) \
                    error: \(error.localizedDescription, privacy: .private)
                    """
                )
                if !recovered {
                    sendBatchTracker.markFailure(error.localizedDescription)
                }
            }

            let result = sendBatchTracker.finalize()
            if result.failureMessage == nil {
                StickyNotesLog.cloudKit.info(
                    """
                    CloudKit syncChanges completed savedCount: \(result.savedNotes.count, privacy: .public) \
                    deletedCount: \(result.deletedNoteIDs.count, privacy: .public) \
                    retryCount: \(result.pendingNotesRequiringRetry.count, privacy: .public) \
                    conflictCount: \(result.conflicts.count, privacy: .public) \
                    hasFailure: \(result.failureMessage != nil, privacy: .public)
                    """
                )
            } else {
                StickyNotesLog.cloudKit.error(
                    """
                    CloudKit syncChanges completed savedCount: \(result.savedNotes.count, privacy: .public) \
                    deletedCount: \(result.deletedNoteIDs.count, privacy: .public) \
                    retryCount: \(result.pendingNotesRequiringRetry.count, privacy: .public) \
                    conflictCount: \(result.conflicts.count, privacy: .public) \
                    hasFailure: \(result.failureMessage != nil, privacy: .public)
                    """
                )
            }
            return result
        } catch {
            sendBatchTracker.cancel()
            StickyNotesLog.cloudKit.error(
                "CloudKit syncChanges failed before send: \(error.localizedDescription, privacy: .private)"
            )
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
            StickyNotesLog.cloudKit.warning(
                "Corrupt persisted CKSyncEngine state discarded; remote hydration required"
            )
        }

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: restoredState.stateSerialization,
            delegate: self
        )
        configuration.automaticallySync = false

        let syncEngine = CKSyncEngine(configuration)
        self.syncEngine = syncEngine
        StickyNotesLog.cloudKit.info(
            """
            CloudKit sync engine initialized restoredFromPersistedState: \(restoredState.restoredFromPersistedSyncState, privacy: .public) \
            needsHydration: \(self.needsRemoteZoneSnapshotHydration, privacy: .public)
            """
        )
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
                    if CloudKitErrorClassifier.isMissingZone(error) {
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
        StickyNotesLog.cloudKit.info("CloudKit custom zone missing; scheduling zone creation")
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

        if issueMessages.isEmpty {
            StickyNotesLog.cloudKit.info(
                "Legacy default-zone import scanned importedCount: \(importedNoteIDs.count, privacy: .public)"
            )
        } else {
            StickyNotesLog.cloudKit.warning(
                """
                Legacy default-zone import scanned with issues \
                importedCount: \(importedNoteIDs.count, privacy: .public) \
                issueCount: \(issueMessages.count, privacy: .public)
                """
            )
        }

        guard !importedNoteIDs.isEmpty else { return issueMessages }

        try await ensureZoneExistsForWrites(syncEngine: syncEngine)
        syncEngine.state.add(
            pendingRecordZoneChanges: importedNoteIDs.map { .saveRecord(recordID(for: $0)) }
        )
        return issueMessages
    }

    private func hydrateRemoteZoneSnapshotIfNeeded() async throws -> CloudRemoteHydrationOutcome {
        guard needsRemoteZoneSnapshotHydration else { return CloudRemoteHydrationOutcome() }
        StickyNotesLog.cloudKit.info("Hydrating CloudKit remote-zone snapshot")

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
            if issueMessages.isEmpty {
                StickyNotesLog.cloudKit.info(
                    "Remote-zone snapshot hydrated noteCount: \(self.remoteNotesByID.count, privacy: .public)"
                )
            } else {
                StickyNotesLog.cloudKit.warning(
                    """
                    Remote-zone snapshot hydrated with issues \
                    noteCount: \(self.remoteNotesByID.count, privacy: .public) \
                    issueCount: \(issueMessages.count, privacy: .public)
                    """
                )
            }
            return CloudRemoteHydrationOutcome(issueMessages: issueMessages)
        } catch {
            guard CloudKitErrorClassifier.isMissingZone(error) else {
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
                StickyNotesLog.cloudKit.error(
                    "Remote-zone snapshot hydration failed: \(error.localizedDescription, privacy: .private)"
                )
                throw error
            }

            remoteNotesByID.removeAll()
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = true
            needsRemoteZoneSnapshotHydration = false
            StickyNotesLog.cloudKit.warning("Remote custom zone is missing; local reupload required")
            return CloudRemoteHydrationOutcome(
                remoteResetMessage: "CloudKit zone was reset and local notes will be uploaded again."
            )
        }
    }

    private func resolveAccountAccess() async -> CloudAccountAccess {
        do {
            let currentAccountIdentifier = try await fetchCurrentAccountIdentifier()

            guard let acceptedAccountIdentifier else {
                self.acceptedAccountIdentifier = currentAccountIdentifier
                StickyNotesLog.cloudKit.info("Accepted current CloudKit account")
                return .available
            }

            guard acceptedAccountIdentifier == currentAccountIdentifier else {
                StickyNotesLog.cloudKit.warning("CloudKit account changed; clearing cached sync state")
                remoteNotesByID.removeAll()
                pendingNotesByID.removeAll()
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
                stateSerializationData = nil
                syncEngine = nil
                return .changed("CloudKit account changed. Local notes were kept on this device and were not uploaded to the new account.")
            }

            return .available
        } catch {
            StickyNotesLog.cloudKit.warning(
                "CloudKit account unavailable: \(error.localizedDescription, privacy: .private)"
            )
            return .unavailable(error.localizedDescription)
        }
    }

    private func fetchCurrentAccountIdentifier() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            container.fetchUserRecordID { recordID, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let recordID else {
                    continuation.resume(throwing: StickyNotesCloudAccountError.missingUserRecordID)
                    return
                }

                continuation.resume(returning: recordID.recordName)
            }
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
        let pendingSaveNoteIDs = Set(pendingNotesByID.keys)
        let classification = CloudKitErrorClassifier.classifyRetriableSavePartialFailure(
            error,
            targetZoneID: StickyNotesCloudKitConfig.zoneID,
            pendingSaveNoteIDs: pendingSaveNoteIDs
        )

        let noteIDs: [String]
        let recoveredAllFailures: Bool
        switch classification {
        case let .recoverableUnknownItemSaves(retriableNoteIDs):
            noteIDs = retriableNoteIDs
            recoveredAllFailures = true
        case let .partiallyRecoverableUnknownItemSaves(retriableNoteIDs):
            noteIDs = retriableNoteIDs
            recoveredAllFailures = false
        case .unhandled:
            return false
        }

        for noteID in noteIDs {
            guard let pendingNote = pendingNotesByID[noteID] else { return false }
            let retriableNote = pendingNote.resettingCloudKitSystemFields()
            pendingNotesByID[noteID] = retriableNote
            sendBatchTracker.markPendingSaveForRetry(retriableNote)
        }

        StickyNotesLog.cloudKit.info(
            """
            Recovered retriable CloudKit saves retryCount: \(noteIDs.count, privacy: .public) \
            recoveredAllFailures: \(recoveredAllFailures, privacy: .public)
            """
        )
        return recoveredAllFailures
    }

    private func applyFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        var savedZoneCount = 0
        for modification in event.modifications where modification.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = true
            savedZoneCount += 1
        }

        var deletedZoneCount = 0
        for deletion in event.deletions where deletion.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = false
            needsRemoteZoneSnapshotHydration = true
            remoteNotesByID.removeAll()
            deletedZoneCount += 1
        }

        if savedZoneCount > 0 || deletedZoneCount > 0 {
            StickyNotesLog.cloudKit.info(
                """
                Fetched CloudKit database changes savedZoneCount: \(savedZoneCount, privacy: .public) \
                deletedZoneCount: \(deletedZoneCount, privacy: .public)
                """
            )
        }
    }

    private func applyFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var modifiedRecordCount = 0
        var decodeFailureCount = 0
        var deletedRecordCount = 0

        for modification in event.modifications {
            let record = modification.record
            guard record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID else {
                continue
            }

            guard let note = StickyNoteRecordMapper.note(from: record) else {
                remoteSnapshotIssueMessages.append("A CloudKit record could not be decoded.")
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
                decodeFailureCount += 1
                continue
            }

            remoteNotesByID[note.id] = note.markedClean()
            modifiedRecordCount += 1
        }

        for deletion in event.deletions
        where deletion.recordID.zoneID == StickyNotesCloudKitConfig.zoneID
            && deletion.recordType == StickyNoteRecordMapper.recordType
        {
            remoteNotesByID.removeValue(forKey: deletion.recordID.recordName)
            deletedRecordCount += 1
        }

        if modifiedRecordCount > 0 || deletedRecordCount > 0 || decodeFailureCount > 0 {
            StickyNotesLog.cloudKit.info(
                """
                Fetched CloudKit record-zone changes modifiedCount: \(modifiedRecordCount, privacy: .public) \
                deletedCount: \(deletedRecordCount, privacy: .public) \
                decodeFailureCount: \(decodeFailureCount, privacy: .public)
                """
            )
        }
    }

    private func applySentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
        for zone in event.savedZones where zone.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = true
            StickyNotesLog.cloudKit.info("CloudKit custom zone save confirmed")
        }

        for failedZoneSave in event.failedZoneSaves where failedZoneSave.zone.zoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            sendBatchTracker.markFailure(failedZoneSave.error.localizedDescription)
            StickyNotesLog.cloudKit.error(
                "CloudKit custom zone save failed: \(failedZoneSave.error.localizedDescription, privacy: .private)"
            )
        }

        for deletedZoneID in event.deletedZoneIDs where deletedZoneID == StickyNotesCloudKitConfig.zoneID {
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            didHydrateRemoteZoneSnapshot = false
            needsRemoteZoneSnapshotHydration = true
            remoteNotesByID.removeAll()
            StickyNotesLog.cloudKit.warning("CloudKit custom zone deletion confirmed; remote cache cleared")
        }

        for (zoneID, error) in event.failedZoneDeletes where zoneID == StickyNotesCloudKitConfig.zoneID {
            sendBatchTracker.markFailure(error.localizedDescription)
            StickyNotesLog.cloudKit.error(
                "CloudKit custom zone delete failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func applySentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        var savedRecordCount = 0
        var deletedRecordCount = 0
        var conflictCount = 0
        var retryCount = 0
        var failedSaveCount = 0
        var failedDeleteCount = 0

        for record in event.savedRecords {
            guard record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID,
                  let note = StickyNoteRecordMapper.note(from: record)
            else {
                continue
            }

            remoteNotesByID[note.id] = note.markedClean()
            pendingNotesByID.removeValue(forKey: note.id)
            sendBatchTracker.markSaved(note)
            savedRecordCount += 1
        }

        for recordID in event.deletedRecordIDs where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName
            remoteNotesByID.removeValue(forKey: noteID)
            pendingNotesByID.removeValue(forKey: noteID)
            sendBatchTracker.markDeleted(noteID: noteID)
            deletedRecordCount += 1
        }

        for failedRecordSave in event.failedRecordSaves where failedRecordSave.record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let recordID = failedRecordSave.record.recordID
            let noteID = recordID.recordName
            let classification = CloudKitErrorClassifier.classifyRecordSaveFailure(failedRecordSave.error)

            switch classification.kind {
            case .missingZone:
                didResolveZoneExistence = true
                zoneExistsRemotely = false
                sendBatchTracker.markFailure(classification.message)
                failedSaveCount += 1
            case .conflict:
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                pendingNotesByID.removeValue(forKey: noteID)

                if let serverRecord = classification.serverRecord,
                   let remoteNote = StickyNoteRecordMapper.note(from: serverRecord)
                {
                    let cleanRemoteNote = remoteNote.markedClean()
                    remoteNotesByID[noteID] = cleanRemoteNote
                    sendBatchTracker.markConflict(noteID: noteID, remoteNote: cleanRemoteNote)
                    conflictCount += 1
                } else if let remoteNote = remoteNotesByID[noteID] {
                    sendBatchTracker.markConflict(noteID: noteID, remoteNote: remoteNote)
                    conflictCount += 1
                } else {
                    sendBatchTracker.markFailure(classification.message)
                    failedSaveCount += 1
                }
            case .unknownItemRetry:
                if let pendingNote = pendingNotesByID[noteID] {
                    let retriableNote = pendingNote.resettingCloudKitSystemFields()
                    pendingNotesByID[noteID] = retriableNote
                    sendBatchTracker.markPendingSaveForRetry(retriableNote)
                    retryCount += 1
                } else {
                    sendBatchTracker.markFailure(classification.message)
                    failedSaveCount += 1
                }
            case .terminal:
                sendBatchTracker.markFailure(classification.message)
                failedSaveCount += 1
            }
        }

        for (recordID, error) in event.failedRecordDeletes where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName
            let classification = CloudKitErrorClassifier.classifyRecordDeleteFailure(error)

            switch classification.kind {
            case .alreadyDeleted:
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                remoteNotesByID.removeValue(forKey: noteID)
                pendingNotesByID.removeValue(forKey: noteID)
                sendBatchTracker.markDeleted(noteID: noteID)
                deletedRecordCount += 1
            case .missingZone:
                didResolveZoneExistence = true
                zoneExistsRemotely = false
                sendBatchTracker.markFailure(classification.message)
                failedDeleteCount += 1
            case .terminal:
                sendBatchTracker.markFailure(classification.message)
                failedDeleteCount += 1
            }
        }

        if savedRecordCount > 0 || deletedRecordCount > 0 || conflictCount > 0
            || retryCount > 0 || failedSaveCount > 0 || failedDeleteCount > 0
        {
            StickyNotesLog.cloudKit.info(
                """
                Sent CloudKit record-zone changes applied savedCount: \(savedRecordCount, privacy: .public) \
                deletedCount: \(deletedRecordCount, privacy: .public) \
                conflictCount: \(conflictCount, privacy: .public) \
                retryCount: \(retryCount, privacy: .public) \
                failedSaveCount: \(failedSaveCount, privacy: .public) \
                failedDeleteCount: \(failedDeleteCount, privacy: .public)
                """
            )
        }
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
                            if partialFailureMessages.isEmpty {
                                StickyNotesLog.cloudKit.debug(
                                    "CloudKit query completed recordCount: \(collectedRecords.count, privacy: .public)"
                                )
                            } else {
                                StickyNotesLog.cloudKit.warning(
                                    """
                                    CloudKit query completed with partial failures \
                                    recordCount: \(collectedRecords.count, privacy: .public) \
                                    partialFailureCount: \(partialFailureMessages.count, privacy: .public)
                                    """
                                )
                            }
                            continuation.resume(
                                returning: CloudFetchedRecords(
                                    records: collectedRecords,
                                    partialFailureMessages: partialFailureMessages
                                )
                            )
                        }
                    case let .failure(error):
                        StickyNotesLog.cloudKit.error(
                            "CloudKit query failed: \(error.localizedDescription, privacy: .private)"
                        )
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
            StickyNotesLog.cloudKit.debug(
                "CloudKit sync-engine state updated hasEncodedState: \(self.stateSerializationData != nil, privacy: .public)"
            )
        case let .accountChange(accountChange):
            switch accountChange.changeType {
            case .signIn:
                StickyNotesLog.cloudKit.info("CloudKit account sign-in event received")
                remoteNotesByID.removeAll()
                stateSerializationData = nil
                self.syncEngine = nil
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
            case .signOut, .switchAccounts:
                StickyNotesLog.cloudKit.warning("CloudKit account sign-out or switch event received")
                remoteNotesByID.removeAll()
                pendingNotesByID.removeAll()
                stateSerializationData = nil
                self.syncEngine = nil
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
            @unknown default:
                StickyNotesLog.cloudKit.warning("Unknown CloudKit account-change event received")
                remoteNotesByID.removeAll()
                pendingNotesByID.removeAll()
                stateSerializationData = nil
                self.syncEngine = nil
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

private struct CloudRemoteHydrationOutcome {
    var issueMessages: [String] = []
    var remoteResetMessage: String?
}

private enum CloudAccountAccess {
    case available
    case unavailable(String)
    case changed(String)
}

private enum StickyNotesCloudAccountError: LocalizedError {
    case missingUserRecordID

    var errorDescription: String? {
        switch self {
        case .missingUserRecordID:
            return "CloudKit account could not be identified."
        }
    }
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
