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
    var permanentlyRejectedSaveNoteIDs: [String] = []
    var conflicts: [CloudSyncConflict] = []
    var failureMessage: String?
}

struct CloudRemoteSnapshot: Sendable, Equatable {
    var notes: [StickyNote]
    var completeness: CloudRemoteSnapshotCompleteness
    var saveVerifications: [CloudSaveVerification] = []

    static func complete(notes: [StickyNote]) -> CloudRemoteSnapshot {
        CloudRemoteSnapshot(notes: notes, completeness: .complete, saveVerifications: [])
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
    private var remoteCache = CloudKitRemoteNoteCache()

    func restore(persistedState: StickyNotesCloudPersistedState) async {
        remoteCache.replaceAll(with: persistedState.remoteNotes)
    }

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        StickyNotesCloudPersistedState(remoteNotes: remoteCache.notes)
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        remoteCache.snapshot(completeness: .complete)
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        var result = CloudSyncBatchResult()

        for note in saves {
            let cleanNote = note.markedClean()
            remoteCache.upsert(cleanNote)
            result.savedNotes.append(cleanNote)
        }

        for id in deletions {
            remoteCache.remove(noteID: id)
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
    private var remoteCache = CloudKitRemoteNoteCache()
    private var pendingNotesByID: [String: StickyNote] = [:]
    private var saveVerificationsByNoteID: [String: CloudSaveVerification] = [:]
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
        remoteCache.replaceAll(with: persistedState.remoteNotes)
        saveVerificationsByNoteID = Dictionary(
            persistedState.saveVerifications.map {
                ($0.noteID, $0)
            },
            uniquingKeysWith: { _, latest in latest }
        )
        hadPersistedSyncStateSerialization = persistedState.stateSerializationData != nil
        didHydrateRemoteZoneSnapshot = false
        needsRemoteZoneSnapshotHydration = persistedState.stateSerializationData != nil
            && persistedState.remoteNotes.isEmpty
        StickyNotesLog.cloudKit.info(
            """
            Restored CloudKit persisted state hasSyncState: \(persistedState.stateSerializationData != nil, privacy: .public) \
            hasAccount: \(persistedState.accountIdentifier != nil, privacy: .public) \
            remoteCacheCount: \(self.remoteCache.count, privacy: .public) \
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
                : remoteCache.notes,
            saveVerifications: saveVerificationsByNoteID.values.sorted {
                $0.noteID < $1.noteID
            }
        )
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        StickyNotesLog.cloudKit.info(
            """
            CloudKit fetch started remoteCacheCount: \(self.remoteCache.count, privacy: .public) \
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
            let saveVerifications = reconcileAmbiguousSavesAfterAuthoritativeFetch(
                syncEngine: syncEngine
            )
            StickyNotesLog.cloudKit.warning(
                "CloudKit remote zone reset detected: \(remoteResetMessage, privacy: .private)"
            )
            return remoteSnapshot(
                completeness: .remoteReset(remoteResetMessage),
                saveVerifications: saveVerifications
            )
        }

        issueMessages.append(contentsOf: hydrationOutcome.issueMessages)
        issueMessages.append(contentsOf: try await importLegacyDefaultZoneNotesIfNeeded(syncEngine: syncEngine))

        let completeness: CloudRemoteSnapshotCompleteness =
            issueMessages.isEmpty ? .complete : .partial(Self.issueSummary(issueMessages))
        var saveVerifications = currentSaveVerifications
        if completeness == .complete {
            saveVerifications = reconcileAmbiguousSavesAfterAuthoritativeFetch(
                syncEngine: syncEngine
            )
        }
        if issueMessages.isEmpty {
            StickyNotesLog.cloudKit.info(
                """
                CloudKit fetch completed completeness: \(completeness.observabilityName, privacy: .public) \
                remoteNoteCount: \(self.remoteCache.count, privacy: .public)
                """
            )
        } else {
            StickyNotesLog.cloudKit.warning(
                """
                CloudKit fetch completed with partial snapshot issueCount: \(issueMessages.count, privacy: .public) \
                remoteNoteCount: \(self.remoteCache.count, privacy: .public)
                """
            )
        }
        return remoteSnapshot(
            completeness: completeness,
            saveVerifications: saveVerifications
        )
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        let eligibleSaves = CloudSaveVerificationPolicy.eligibleSaves(
            saves,
            quarantinedNoteIDs: Set(saveVerificationsByNoteID.keys)
        )
        let quarantinedSaveCount = saves.count - eligibleSaves.count
        guard !eligibleSaves.isEmpty || !deletions.isEmpty else {
            if quarantinedSaveCount > 0 {
                StickyNotesLog.cloudKit.info(
                    "CloudKit syncChanges quarantined ambiguous saves count: \(quarantinedSaveCount, privacy: .public)"
                )
            }
            StickyNotesLog.cloudKit.debug("CloudKit syncChanges skipped because there are no pending changes")
            return CloudSyncBatchResult()
        }
        StickyNotesLog.cloudKit.info(
            """
            CloudKit syncChanges started saveCount: \(eligibleSaves.count, privacy: .public) \
            quarantinedSaveCount: \(quarantinedSaveCount, privacy: .public) \
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
            for noteID in deletions where saveVerificationsByNoteID[noteID] != nil {
                saveVerificationsByNoteID.removeValue(forKey: noteID)
                pendingNotesByID.removeValue(forKey: noteID)
                syncEngine.state.remove(
                    pendingRecordZoneChanges: [.saveRecord(recordID(for: noteID))]
                )
            }
            let forcedBlockedSaveNoteIDs = Set(
                eligibleSaves.lazy
                    .filter { $0.cloudUploadBlock != nil }
                    .map(\.id)
            )
            let expectedSaveNoteIDs = Set(eligibleSaves.map(\.id))

            if !eligibleSaves.isEmpty {
                try await ensureZoneExistsForWrites(syncEngine: syncEngine)
            }

            for note in eligibleSaves {
                pendingNotesByID[note.id] = note
            }

            let pendingChanges =
                deletions.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID(for: $0)) }
                + eligibleSaves.map {
                    CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID(for: $0.id))
                }

            syncEngine.state.add(pendingRecordZoneChanges: pendingChanges)
            sendBatchTracker.begin(
                expectedSaveNoteIDs: expectedSaveNoteIDs,
                expectedDeleteNoteIDs: Set(deletions),
                forcedBlockedSaveNoteIDs: forcedBlockedSaveNoteIDs
            )
            defer {
                discardForcedBlockedSaves(
                    noteIDs: forcedBlockedSaveNoteIDs,
                    syncEngine: syncEngine
                )
            }

            let initialLimitFailures = await performSendAttempt(
                noteIDs: expectedSaveNoteIDs,
                syncEngine: syncEngine
            )
            await recoverLimitExceededSaves(initialLimitFailures, syncEngine: syncEngine)
            await retryBatchRequestFailedSaves(syncEngine: syncEngine)
            sendBatchTracker.closeBatchRetryPhase()

            let freshRetryNotes = sendBatchTracker.takeFreshRetryCandidates()
            if !freshRetryNotes.isEmpty {
                for note in freshRetryNotes {
                    pendingNotesByID[note.id] = note
                }

                let freshRetryRecordIDs = freshRetryNotes.map { recordID(for: $0.id) }
                StickyNotesLog.cloudKit.info(
                    "Retrying blocked CloudKit saves as fresh records count: \(freshRetryRecordIDs.count, privacy: .public)"
                )

                let freshRetryLimitFailures = await performSendAttempt(
                    noteIDs: Set(freshRetryNotes.map(\.id)),
                    scopeRecordIDs: freshRetryRecordIDs,
                    syncEngine: syncEngine
                )
                await recoverLimitExceededSaves(
                    freshRetryLimitFailures,
                    syncEngine: syncEngine
                )
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

        for note in mappedRecords.notesByID.values where remoteCache.note(withID: note.id) == nil {

            let importedNote = note.markedClean()
            remoteCache.upsert(importedNote)
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
            remoteCache.replaceAll(with: Array(mappedRecords.notesByID.values))
            didResolveZoneExistence = true
            zoneExistsRemotely = true
            didHydrateRemoteZoneSnapshot = issueMessages.isEmpty
            needsRemoteZoneSnapshotHydration = !issueMessages.isEmpty
            if issueMessages.isEmpty {
                StickyNotesLog.cloudKit.info(
                    "Remote-zone snapshot hydrated noteCount: \(self.remoteCache.count, privacy: .public)"
                )
            } else {
                StickyNotesLog.cloudKit.warning(
                    """
                    Remote-zone snapshot hydrated with issues \
                    noteCount: \(self.remoteCache.count, privacy: .public) \
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

            remoteCache.removeAll()
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
                remoteCache.removeAll()
                pendingNotesByID.removeAll()
                saveVerificationsByNoteID.removeAll()
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

    private var currentSaveVerifications: [CloudSaveVerification] {
        saveVerificationsByNoteID.values.sorted { $0.noteID < $1.noteID }
    }

    private func remoteSnapshot(
        completeness: CloudRemoteSnapshotCompleteness,
        saveVerifications: [CloudSaveVerification]? = nil
    ) -> CloudRemoteSnapshot {
        CloudRemoteSnapshot(
            notes: remoteCache.notes,
            completeness: completeness,
            saveVerifications: saveVerifications ?? currentSaveVerifications
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

    private func discardForcedBlockedSaves(
        noteIDs: Set<String>,
        syncEngine: CKSyncEngine
    ) {
        guard !noteIDs.isEmpty else { return }

        syncEngine.state.remove(
            pendingRecordZoneChanges: noteIDs.map { .saveRecord(recordID(for: $0)) }
        )
        for noteID in noteIDs {
            pendingNotesByID.removeValue(forKey: noteID)
        }
        StickyNotesLog.cloudKit.info(
            "Discarded one-shot blocked CloudKit saves count: \(noteIDs.count, privacy: .public)"
        )
    }

    private func markUnresolvedSavesForRemoteVerificationIfNeeded(
        after error: Error,
        attemptedNoteIDs: Set<String>
    ) {
        guard CloudKitErrorClassifier.isServerResponseLost(error) else { return }
        let noteIDsRequiringVerification = CloudSaveVerificationPolicy
            .noteIDsRequiringVerification(
                attemptedNoteIDs: attemptedNoteIDs,
                materializedNoteIDs: sendBatchTracker
                    .saveNoteIDsAwaitingResponseInCurrentAttempt,
                unresolvedNoteIDs: sendBatchTracker.unresolvedSaveNoteIDs
            )
        for noteID in noteIDsRequiringVerification {
            guard let pendingNote = pendingNotesByID[noteID] else { continue }
            saveVerificationsByNoteID[noteID] = CloudSaveVerification(note: pendingNote)
        }
    }

    private func performSendAttempt(
        noteIDs: Set<String>,
        scopeRecordIDs: [CKRecord.ID]? = nil,
        syncEngine: CKSyncEngine
    ) async -> [String: String] {
        sendBatchTracker.beginSendAttempt(noteIDs: noteIDs)

        do {
            if let scopeRecordIDs {
                syncEngine.state.add(
                    pendingRecordZoneChanges: CloudKitScopedSaveRetry.pendingChanges(
                        for: scopeRecordIDs
                    )
                )
                try await syncEngine.sendChanges(
                    CKSyncEngine.SendChangesOptions(scope: .recordIDs(scopeRecordIDs))
                )
            } else {
                try await syncEngine.sendChanges()
            }
        } catch {
            markUnresolvedSavesForRemoteVerificationIfNeeded(
                after: error,
                attemptedNoteIDs: noteIDs
            )
            let recovered = recoverRecordSaveFailures(from: error, syncEngine: syncEngine)
            let operationLimitExceeded = CloudKitErrorClassifier.isLimitExceeded(error)
            if operationLimitExceeded {
                let unresolvedNoteIDs = noteIDs.intersection(
                    sendBatchTracker.unresolvedSaveNoteIDs
                )
                for noteID in unresolvedNoteIDs {
                    sendBatchTracker.markLimitExceededSave(
                        noteID: noteID,
                        message: error.localizedDescription
                    )
                }
                if unresolvedNoteIDs.isEmpty {
                    sendBatchTracker.markFailure(error.localizedDescription)
                }
            } else if !recovered {
                sendBatchTracker.markFailure(error.localizedDescription)
            }

            StickyNotesLog.cloudKit.error(
                """
                CloudKit sendChanges failed handledRecordSaveFailures: \(recovered, privacy: .public) \
                limitExceeded: \(operationLimitExceeded, privacy: .public) \
                error: \(error.localizedDescription, privacy: .private)
                """
            )
        }

        sendBatchTracker.sealSendAttempt()
        return sendBatchTracker.limitExceededSaveFailures
    }

    private func recoverLimitExceededSaves(
        _ failures: [String: String],
        syncEngine: CKSyncEngine
    ) async {
        let result = await CloudKitLimitExceededRecoveryExecutor.recover(
            initialFailures: failures,
            unresolvedNoteIDs: sendBatchTracker.unresolvedSaveNoteIDs,
            performScopedRetry: { noteIDs in
                let retryFailures = await self.performSendAttempt(
                    noteIDs: Set(noteIDs),
                    scopeRecordIDs: noteIDs.map(self.recordID(for:)),
                    syncEngine: syncEngine
                )
                return CloudKitLimitExceededRetryOutcome(
                    failures: retryFailures,
                    unresolvedNoteIDs: self.sendBatchTracker.unresolvedSaveNoteIDs
                )
            }
        )

        for failure in result.blockedFailures {
            blockPendingSave(
                noteID: failure.noteID,
                message: failure.message,
                syncEngine: syncEngine
            )
        }
    }

    private func retryBatchRequestFailedSaves(syncEngine: CKSyncEngine) async {
        let retryNoteIDs = sendBatchTracker.takeBatchRetryCandidates()
            .filter { pendingNotesByID[$0] != nil }
        guard !retryNoteIDs.isEmpty else { return }

        let recordIDs = retryNoteIDs.sorted().map(recordID(for:))
        StickyNotesLog.cloudKit.info(
            "Retrying CloudKit batch-dependent saves count: \(recordIDs.count, privacy: .public)"
        )

        let limitFailures = await performSendAttempt(
            noteIDs: retryNoteIDs,
            scopeRecordIDs: recordIDs,
            syncEngine: syncEngine
        )
        await recoverLimitExceededSaves(limitFailures, syncEngine: syncEngine)
    }

    private func reconcileAmbiguousSavesAfterAuthoritativeFetch(
        syncEngine: CKSyncEngine
    ) -> [CloudSaveVerification] {
        let saveVerifications = currentSaveVerifications
        let noteIDs = Set(saveVerifications.map(\.noteID))
        guard !noteIDs.isEmpty else { return [] }

        let remotelyPresentNoteIDs = noteIDs.filter { remoteCache.note(withID: $0) != nil }
        let matchingPayloadCount = saveVerifications.filter { verification in
            guard let remoteNote = remoteCache.note(withID: verification.noteID) else {
                return false
            }
            return verification.matches(remoteNote)
        }.count
        syncEngine.state.remove(
            pendingRecordZoneChanges: noteIDs.map {
                .saveRecord(recordID(for: $0))
            }
        )
        for noteID in noteIDs {
            pendingNotesByID.removeValue(forKey: noteID)
        }
        saveVerificationsByNoteID.removeAll()
        StickyNotesLog.cloudKit.info(
            """
            Reconciled ambiguous CloudKit saves from authoritative snapshot count: \
            \(noteIDs.count, privacy: .public) \
            remotelyPresentCount: \(remotelyPresentNoteIDs.count, privacy: .public) \
            matchingPayloadCount: \(matchingPayloadCount, privacy: .public)
            """
        )
        return saveVerifications
    }

    private func recoverRecordSaveFailures(
        from error: Error,
        syncEngine: CKSyncEngine
    ) -> Bool {
        let pendingSaveNoteIDs = sendBatchTracker.expectedSaveNoteIDs
        guard let classification = CloudKitErrorClassifier.classifyPartialRecordSaveFailures(
            error,
            targetZoneID: StickyNotesCloudKitConfig.zoneID,
            pendingSaveNoteIDs: pendingSaveNoteIDs
        ) else {
            return false
        }

        return applyRecordSaveFailurePlan(classification, syncEngine: syncEngine)
    }

    @discardableResult
    private func applyRecordSaveFailurePlan(
        _ classification: CloudKitPartialRecordSaveFailureClassification,
        syncEngine: CKSyncEngine
    ) -> Bool {

        for rejectedFailure in classification.permanentlyRejectedSaveFailures {
            guard sendBatchTracker.claimSaveFailure(noteID: rejectedFailure.noteID) else {
                continue
            }
            blockPendingSave(
                noteID: rejectedFailure.noteID,
                message: rejectedFailure.message,
                syncEngine: syncEngine
            )
        }

        for noteID in classification.unknownItemRetryNoteIDs {
            guard sendBatchTracker.claimSaveFailure(noteID: noteID) else {
                continue
            }
            guard let pendingNote = pendingNotesByID[noteID] else {
                sendBatchTracker.markFailure("CloudKit could not find the pending local note.")
                continue
            }
            let disposition = sendBatchTracker.handleUnknownItemSave(
                pendingNote,
                message: "CloudKit could not find the record."
            )
            switch disposition {
            case let .deferredRetry(retriableNote), let .retryImmediately(retriableNote):
                pendingNotesByID[noteID] = retriableNote
            case .permanentlyRejected:
                blockPendingSave(
                    noteID: noteID,
                    message: "CloudKit could not find the record.",
                    syncEngine: syncEngine
                )
            case .ignored:
                sendBatchTracker.markFailure("CloudKit could not retry the missing record.")
            }
        }

        for conflictFailure in classification.conflictSaveFailures {
            guard sendBatchTracker.claimSaveFailure(noteID: conflictFailure.noteID) else {
                continue
            }
            resolveConflictSaveFailure(conflictFailure, syncEngine: syncEngine)
        }

        for noteID in classification.serverResponseLostNoteIDs {
            guard sendBatchTracker.claimSaveFailure(noteID: noteID) else {
                continue
            }
            if let pendingNote = pendingNotesByID[noteID] {
                saveVerificationsByNoteID[noteID] = CloudSaveVerification(note: pendingNote)
            }
        }

        for noteID in classification.missingZoneSaveNoteIDs {
            guard sendBatchTracker.claimSaveFailure(noteID: noteID) else {
                continue
            }
            didResolveZoneExistence = true
            zoneExistsRemotely = false
            sendBatchTracker.markFailure("The CloudKit record zone is missing.")
        }

        let limitExceededRetryFailures = classification.limitExceededRetrySaveFailures
        let limitExceededRetryNoteIDs = Set(limitExceededRetryFailures.map(\.noteID))
        sendBatchTracker.handleLimitExceededSaveFailures(limitExceededRetryFailures)

        if classification.limitExceededSaveFailures.isEmpty {
            let batchRootNoteIDs = Set(classification.unknownItemRetryNoteIDs)
                .union(classification.permanentlyRejectedSaveFailures.map(\.noteID))
                .union(classification.conflictSaveFailures.map(\.noteID))
            let canRetryBatchDependents = classification.canRetryBatchDependents
                && sendBatchTracker.hasResolvedSaveFailureRoot(
                    noteIDs: batchRootNoteIDs
                )
            sendBatchTracker.handleBatchRequestFailedSaveFailures(
                classification.batchRequestFailedSaveFailures,
                canRetry: canRetryBatchDependents
            )
        }

        let stillUnhandledNoteIDs = Set(classification.unhandledSaveFailureNoteIDs).filter {
            !sendBatchTracker.hasHandledSaveFailure(noteID: $0)
        }
        let hasUnhandledFailures = classification.hasUnattributedFailures
            || !stillUnhandledNoteIDs.isEmpty
            || !classification.missingZoneSaveNoteIDs.isEmpty
            || (!classification.batchRequestFailedSaveFailures.isEmpty
                && classification.limitExceededSaveFailures.isEmpty
                && !classification.canRetryBatchDependents)

        StickyNotesLog.cloudKit.info(
            """
            Classified partial CloudKit save failures unknownItemCount: \
            \(classification.unknownItemRetryNoteIDs.count, privacy: .public) \
            rejectedCount: \(classification.permanentlyRejectedSaveFailures.count, privacy: .public) \
            conflictCount: \(classification.conflictSaveFailures.count, privacy: .public) \
            limitRetryCount: \(limitExceededRetryNoteIDs.count, privacy: .public) \
            batchRetryCount: \(classification.batchRequestFailedSaveFailures.count, privacy: .public) \
            hasUnhandled: \(hasUnhandledFailures, privacy: .public)
            """
        )
        return !hasUnhandledFailures
    }

    private func resolveConflictSaveFailure(
        _ failure: CloudKitConflictSaveFailure,
        syncEngine: CKSyncEngine
    ) {
        let recordID = recordID(for: failure.noteID)
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        pendingNotesByID.removeValue(forKey: failure.noteID)
        saveVerificationsByNoteID.removeValue(forKey: failure.noteID)

        if let serverRecord = failure.serverRecord,
           let remoteNote = StickyNoteRecordMapper.note(from: serverRecord)
        {
            let cleanRemoteNote = remoteNote.markedClean()
            remoteCache.upsert(cleanRemoteNote)
            sendBatchTracker.markConflict(
                noteID: failure.noteID,
                remoteNote: cleanRemoteNote
            )
        } else if let remoteNote = remoteCache.note(withID: failure.noteID) {
            sendBatchTracker.markConflict(noteID: failure.noteID, remoteNote: remoteNote)
        } else {
            sendBatchTracker.markFailure(failure.message)
        }
    }

    private func blockPendingSave(
        noteID: String,
        message: String,
        syncEngine: CKSyncEngine
    ) {
        syncEngine.state.remove(
            pendingRecordZoneChanges: [.saveRecord(recordID(for: noteID))]
        )
        pendingNotesByID.removeValue(forKey: noteID)
        saveVerificationsByNoteID.removeValue(forKey: noteID)
        sendBatchTracker.markPermanentlyRejectedSave(noteID: noteID, message: message)
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
            remoteCache.removeAll()
            pendingNotesByID.removeAll()
            saveVerificationsByNoteID.removeAll()
            deletedZoneCount += 1
        }

        if Self.anyNonzero(savedZoneCount, deletedZoneCount) {
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

            remoteCache.upsert(note)
            modifiedRecordCount += 1
        }

        for deletion in event.deletions
        where deletion.recordID.zoneID == StickyNotesCloudKitConfig.zoneID
            && deletion.recordType == StickyNoteRecordMapper.recordType
        {
            remoteCache.remove(noteID: deletion.recordID.recordName)
            deletedRecordCount += 1
        }

        if Self.anyNonzero(modifiedRecordCount, deletedRecordCount, decodeFailureCount) {
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
            remoteCache.removeAll()
            pendingNotesByID.removeAll()
            saveVerificationsByNoteID.removeAll()
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
        let failedRecordSaves = event.failedRecordSaves.filter {
            $0.record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID
        }
        let respondedSaveNoteIDs = Set(
            event.savedRecords.lazy
                .filter { $0.recordID.zoneID == StickyNotesCloudKitConfig.zoneID }
                .map { $0.recordID.recordName }
        ).union(failedRecordSaves.map { $0.record.recordID.recordName })
        sendBatchTracker.markSaveResponsesReceived(noteIDs: respondedSaveNoteIDs)

        var savedRecordCount = 0
        var deletedRecordCount = 0
        var conflictCount = 0
        var retryCount = 0
        var rejectedSaveCount = 0
        var failedSaveCount = 0
        var failedDeleteCount = 0

        for record in event.savedRecords {
            guard record.recordID.zoneID == StickyNotesCloudKitConfig.zoneID,
                  let note = StickyNoteRecordMapper.note(from: record)
            else {
                continue
            }

            remoteCache.upsert(note)
            pendingNotesByID.removeValue(forKey: note.id)
            saveVerificationsByNoteID.removeValue(forKey: note.id)
            sendBatchTracker.markSaved(note)
            savedRecordCount += 1
        }

        for recordID in event.deletedRecordIDs where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName
            remoteCache.remove(noteID: noteID)
            pendingNotesByID.removeValue(forKey: noteID)
            sendBatchTracker.markDeleted(noteID: noteID)
            deletedRecordCount += 1
        }

        if !failedRecordSaves.isEmpty {
            let classification = CloudKitErrorClassifier.classifyRecordSaveFailures(
                failedRecordSaves.map { ($0.record.recordID, $0.error) },
                targetZoneID: StickyNotesCloudKitConfig.zoneID,
                pendingSaveNoteIDs: sendBatchTracker.expectedSaveNoteIDs
            )
            applyRecordSaveFailurePlan(classification, syncEngine: syncEngine)

            conflictCount += classification.conflictSaveFailures.count
            retryCount += classification.unknownItemRetryNoteIDs.count
                + classification.limitExceededRetrySaveFailures.count
                + (classification.canRetryBatchDependents
                    ? classification.batchRequestFailedSaveFailures.count
                    : 0)
            rejectedSaveCount += classification.permanentlyRejectedSaveFailures.count
            failedSaveCount += classification.serverResponseLostNoteIDs.count
                + classification.missingZoneSaveNoteIDs.count
                + classification.unhandledSaveFailureNoteIDs.count
                + (classification.canRetryBatchDependents
                    ? 0
                    : classification.batchRequestFailedSaveFailures.count)
        }

        for (recordID, error) in event.failedRecordDeletes where recordID.zoneID == StickyNotesCloudKitConfig.zoneID {
            let noteID = recordID.recordName
            let classification = CloudKitErrorClassifier.classifyRecordDeleteFailure(error)

            switch classification.kind {
            case .alreadyDeleted:
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                remoteCache.remove(noteID: noteID)
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

        if Self.anyNonzero(
            savedRecordCount,
            deletedRecordCount,
            conflictCount,
            retryCount,
            rejectedSaveCount,
            failedSaveCount,
            failedDeleteCount
        ) {
            StickyNotesLog.cloudKit.info(
                """
                Sent CloudKit record-zone changes applied savedCount: \(savedRecordCount, privacy: .public) \
                deletedCount: \(deletedRecordCount, privacy: .public) \
                conflictCount: \(conflictCount, privacy: .public) \
                retryCount: \(retryCount, privacy: .public) \
                rejectedSaveCount: \(rejectedSaveCount, privacy: .public) \
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

    private static func anyNonzero(_ counts: Int...) -> Bool {
        counts.contains { $0 > 0 }
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
                remoteCache.removeAll()
                pendingNotesByID.removeAll()
                saveVerificationsByNoteID.removeAll()
                stateSerializationData = nil
                self.syncEngine = nil
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
            case .signOut, .switchAccounts:
                StickyNotesLog.cloudKit.warning("CloudKit account sign-out or switch event received")
                remoteCache.removeAll()
                pendingNotesByID.removeAll()
                saveVerificationsByNoteID.removeAll()
                stateSerializationData = nil
                self.syncEngine = nil
                didResolveZoneExistence = false
                zoneExistsRemotely = false
                didHydrateRemoteZoneSnapshot = false
                needsRemoteZoneSnapshotHydration = true
            @unknown default:
                StickyNotesLog.cloudKit.warning("Unknown CloudKit account-change event received")
                remoteCache.removeAll()
                pendingNotesByID.removeAll()
                saveVerificationsByNoteID.removeAll()
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
        let quarantinedNoteIDs = Set(saveVerificationsByNoteID.keys)
        let pendingChanges = CloudKitPendingRecordZoneChangeFilter.customZoneChanges(
            from: syncEngine.state.pendingRecordZoneChanges,
            targetZoneID: StickyNotesCloudKitConfig.zoneID,
            shouldInclude: { pendingChange in
                guard context.options.scope.contains(pendingChange) else { return false }

                switch pendingChange {
                case let .saveRecord(recordID):
                    guard CloudSaveVerificationPolicy.shouldSend(
                        noteID: recordID.recordName,
                        quarantinedNoteIDs: quarantinedNoteIDs
                    ) else {
                        return false
                    }
                    guard let pendingNote = pendingNotesByID[recordID.recordName] else {
                        return false
                    }
                    guard pendingNote.cloudUploadBlock != nil else {
                        return true
                    }
                    return sendBatchTracker.shouldIncludeBlockedSave(noteID: recordID.recordName)
                case .deleteRecord:
                    return true
                @unknown default:
                    return true
                }
            }
        )

        if pendingChanges.skippedUnsupportedCount > 0 {
            StickyNotesLog.cloudKit.warning(
                """
                Skipped unsupported CloudKit pending record-zone changes \
                count: \(pendingChanges.skippedUnsupportedCount, privacy: .public)
                """
            )
        }

        guard let batch = await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: pendingChanges.changes,
            recordProvider: { [weak self] recordID in
                guard let self else { return nil }
                return await self.recordProvider(for: recordID)
            }
        ) else {
            return nil
        }

        let materializedSaveNoteIDs = Set(
            batch.recordsToSave.lazy
                .filter { $0.recordID.zoneID == StickyNotesCloudKitConfig.zoneID }
                .map { $0.recordID.recordName }
        )
        sendBatchTracker.markMaterializedSaveNoteIDs(materializedSaveNoteIDs)
        return batch
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

struct CloudKitPendingRecordZoneChangeFilterResult {
    var changes: [CKSyncEngine.PendingRecordZoneChange]
    var skippedUnsupportedCount: Int
}

enum CloudKitPendingRecordZoneChangeFilter {
    static func customZoneChanges(
        from pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        targetZoneID: CKRecordZone.ID,
        shouldInclude: (CKSyncEngine.PendingRecordZoneChange) -> Bool
    ) -> CloudKitPendingRecordZoneChangeFilterResult {
        customZoneChanges(
            from: pendingChanges,
            targetZoneID: targetZoneID,
            shouldInclude: shouldInclude,
            recordID: recordID(for:)
        )
    }

    static func customZoneChanges(
        from pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        targetZoneID: CKRecordZone.ID,
        shouldInclude: (CKSyncEngine.PendingRecordZoneChange) -> Bool,
        recordID: (CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID?
    ) -> CloudKitPendingRecordZoneChangeFilterResult {
        var filteredChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        var skippedUnsupportedCount = 0

        for pendingChange in pendingChanges where shouldInclude(pendingChange) {
            guard let pendingRecordID = recordID(pendingChange) else {
                skippedUnsupportedCount += 1
                continue
            }

            guard pendingRecordID.zoneID == targetZoneID else {
                continue
            }

            filteredChanges.append(pendingChange)
        }

        return CloudKitPendingRecordZoneChangeFilterResult(
            changes: filteredChanges,
            skippedUnsupportedCount: skippedUnsupportedCount
        )
    }

    static func recordID(for pendingChange: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch pendingChange {
        case let .saveRecord(recordID), let .deleteRecord(recordID):
            return recordID
        @unknown default:
            return nil
        }
    }
}

enum CloudSaveVerificationPolicy {
    static func eligibleSaves(
        _ saves: [StickyNote],
        quarantinedNoteIDs: Set<String>
    ) -> [StickyNote] {
        saves.filter { !quarantinedNoteIDs.contains($0.id) }
    }

    static func shouldSend(noteID: String, quarantinedNoteIDs: Set<String>) -> Bool {
        !quarantinedNoteIDs.contains(noteID)
    }

    static func noteIDsRequiringVerification(
        attemptedNoteIDs: Set<String>,
        materializedNoteIDs: Set<String>,
        unresolvedNoteIDs: Set<String>
    ) -> Set<String> {
        attemptedNoteIDs
            .intersection(materializedNoteIDs)
            .intersection(unresolvedNoteIDs)
    }
}

enum CloudKitScopedSaveRetry {
    static func pendingChanges(
        for recordIDs: [CKRecord.ID]
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        recordIDs.map { .saveRecord($0) }
    }
}
