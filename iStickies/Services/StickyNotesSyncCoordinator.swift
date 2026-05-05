import Foundation

struct StickyNotesSyncLocalState: Equatable, Sendable {
    var notes: [StickyNote]
    var pendingDeletionIDs: Set<String>
}

struct StickyNotesSyncMergeTransition: Sendable {
    var state: StickyNotesSyncLocalState
    var remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness
}

struct StickyNotesOutgoingCloudChanges: Sendable {
    var saves: [StickyNote]
    var deletions: [String]
    var savesByID: [String: StickyNote]
}

struct StickyNotesSyncApplicationTransition: Sendable {
    var state: StickyNotesSyncLocalState
    var syncResult: CloudSyncBatchResult
}

struct StickyNotesSyncCoordinator: Sendable {
    private let cloudService: any StickyNotesCloudSyncing

    init(cloudService: any StickyNotesCloudSyncing) {
        self.cloudService = cloudService
    }

    func fetchRemoteSnapshot() async throws -> CloudRemoteSnapshot {
        let remoteSnapshot = try await cloudService.fetchAllNotes()
        StickyNotesLog.sync.info(
            """
            Remote snapshot fetched completeness: \(remoteSnapshot.completeness.observabilityName, privacy: .public) \
            remoteNoteCount: \(remoteSnapshot.notes.count, privacy: .public)
            """
        )

        if let failureMessage = remoteSnapshot.completeness.failureMessage {
            StickyNotesLog.sync.warning(
                """
                Remote snapshot is incomplete status: \(remoteSnapshot.completeness.observabilityName, privacy: .public) \
                message: \(failureMessage, privacy: .private)
                """
            )
        }

        return remoteSnapshot
    }

    func merge(
        remoteSnapshot: CloudRemoteSnapshot,
        localState: StickyNotesSyncLocalState
    ) -> StickyNotesSyncMergeTransition {
        let mergeOutcome = StickyNotesMergeEngine.merge(
            localNotes: localState.notes,
            remoteNotes: remoteSnapshot.notes,
            pendingDeletionIDs: localState.pendingDeletionIDs,
            remoteSnapshotCompleteness: remoteSnapshot.completeness
        )

        var mergedNotes = enforceYellowNotes(mergeOutcome.notes)
        var pendingDeletionIDs = localState.pendingDeletionIDs

        if remoteSnapshot.completeness.shouldReuploadLocalNotes {
            let clearedDeletionCount = pendingDeletionIDs.count
            mergedNotes = resetCloudStateForRemoteReset(mergedNotes)
            pendingDeletionIDs.removeAll()
            StickyNotesLog.sync.warning(
                """
                Remote zone reset detected; local notes marked for reupload \
                noteCount: \(mergedNotes.count, privacy: .public) \
                clearedDeletionCount: \(clearedDeletionCount, privacy: .public)
                """
            )
        }

        return StickyNotesSyncMergeTransition(
            state: StickyNotesSyncLocalState(
                notes: mergedNotes,
                pendingDeletionIDs: pendingDeletionIDs
            ),
            remoteSnapshotCompleteness: remoteSnapshot.completeness
        )
    }

    func outgoingChanges(
        from localState: StickyNotesSyncLocalState
    ) -> StickyNotesOutgoingCloudChanges {
        let outgoingSaves = localState.notes.filter(\.needsCloudUpload)
        return StickyNotesOutgoingCloudChanges(
            saves: outgoingSaves,
            deletions: Array(localState.pendingDeletionIDs),
            savesByID: Dictionary(uniqueKeysWithValues: outgoingSaves.map { ($0.id, $0) })
        )
    }

    func send(
        _ changes: StickyNotesOutgoingCloudChanges
    ) async -> CloudSyncBatchResult {
        StickyNotesLog.sync.info(
            """
            Sending CloudKit changes saveCount: \(changes.saves.count, privacy: .public) \
            deleteCount: \(changes.deletions.count, privacy: .public)
            """
        )

        let syncResult = await cloudService.syncChanges(
            saves: changes.saves,
            deletions: changes.deletions
        )

        StickyNotesLog.sync.info(
            """
            CloudKit batch result savedCount: \(syncResult.savedNotes.count, privacy: .public) \
            deletedCount: \(syncResult.deletedNoteIDs.count, privacy: .public) \
            retryCount: \(syncResult.pendingNotesRequiringRetry.count, privacy: .public) \
            conflictCount: \(syncResult.conflicts.count, privacy: .public) \
            hasFailure: \(syncResult.failureMessage != nil, privacy: .public)
            """
        )

        return syncResult
    }

    func apply(
        syncResult: CloudSyncBatchResult,
        to localState: StickyNotesSyncLocalState,
        sentNotesByID: [String: StickyNote]
    ) -> StickyNotesSyncApplicationTransition {
        let syncOutcome = StickyNotesMergeEngine.apply(
            syncResult: syncResult,
            to: localState.notes,
            pendingDeletionIDs: localState.pendingDeletionIDs,
            sentNotesByID: sentNotesByID
        )

        return StickyNotesSyncApplicationTransition(
            state: StickyNotesSyncLocalState(
                notes: enforceYellowNotes(syncOutcome.notes),
                pendingDeletionIDs: syncOutcome.pendingDeletionIDs
            ),
            syncResult: syncResult
        )
    }

    func validateSnapshotAllowsOutgoingChanges(
        _ completeness: CloudRemoteSnapshotCompleteness
    ) throws {
        guard case let .unavailable(message) = completeness else { return }
        throw StickyNotesCloudSyncError(message: message)
    }

    func validateCompletion(
        remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness,
        syncResult: CloudSyncBatchResult
    ) throws {
        if let failureMessage = syncResult.failureMessage {
            throw StickyNotesCloudSyncError(message: failureMessage)
        }
        if let failureMessage = remoteSnapshotCompleteness.failureMessage {
            throw StickyNotesCloudSyncError(message: failureMessage)
        }
    }

    func currentPersistedState(
        after remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness?
    ) async -> StickyNotesCloudPersistedState {
        let persistedState = await cloudService.currentPersistedState()
        guard let remoteSnapshotCompleteness else {
            return persistedState
        }

        return trustedCloudPersistedState(
            persistedState,
            after: remoteSnapshotCompleteness
        )
    }

    func followUpSyncDelay(hasPendingCloudChanges: Bool) -> TimeInterval? {
        hasPendingCloudChanges ? 1.0 : nil
    }

    func retrySyncDelay(hasPendingCloudChanges: Bool) -> TimeInterval? {
        hasPendingCloudChanges ? 5.0 : nil
    }

    private func trustedCloudPersistedState(
        _ persistedState: StickyNotesCloudPersistedState,
        after remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness
    ) -> StickyNotesCloudPersistedState {
        guard case .partial = remoteSnapshotCompleteness else {
            return persistedState
        }

        return StickyNotesCloudPersistedState(
            stateSerializationData: persistedState.stateSerializationData,
            accountIdentifier: persistedState.accountIdentifier,
            remoteNotes: []
        )
    }

    private func resetCloudStateForRemoteReset(_ notes: [StickyNote]) -> [StickyNote] {
        notes.map { note in
            note.resettingCloudKitSystemFields()
        }
    }

    private func enforceYellowNotes(_ notes: [StickyNote]) -> [StickyNote] {
        notes.map { note in
            guard note.color != .yellow else { return note }

            var copy = note
            copy.color = .yellow
            copy.needsCloudUpload = true
            return copy
        }
    }
}

struct StickyNotesCloudSyncError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
