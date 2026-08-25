import Foundation

enum CloudKitUnknownItemSaveDisposition: Equatable {
    case deferredRetry(StickyNote)
    case retryImmediately(StickyNote)
    case permanentlyRejected
    case ignored
}

struct CloudKitSendBatchTracker {
    private var activeContext: CloudKitSendBatchContext?

    var hasActiveBatch: Bool {
        activeContext != nil
    }

    var expectedSaveNoteIDs: Set<String> {
        activeContext?.expectedSaveNoteIDs ?? []
    }

    var unresolvedSaveNoteIDs: Set<String> {
        activeContext?.unresolvedSaveNoteIDs ?? []
    }

    var limitExceededSaveFailures: [String: String] {
        activeContext?.limitExceededSaveFailuresInCurrentAttempt ?? [:]
    }

    var saveNoteIDsAwaitingResponseInCurrentAttempt: Set<String> {
        activeContext?.saveNoteIDsAwaitingResponseInCurrentAttempt ?? []
    }

    var hasResolvedSaveFailureRootInCurrentAttempt: Bool {
        activeContext?.resolvedSaveFailureRootNoteIDsInCurrentAttempt.isEmpty == false
    }

    func hasResolvedSaveFailureRoot(noteIDs: Set<String>) -> Bool {
        guard let activeContext else { return false }
        return !activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt
            .isDisjoint(with: noteIDs)
    }

    mutating func beginSendAttempt(noteIDs: Set<String>) {
        sealSendAttempt()
        guard var activeContext else { return }
        activeContext.activeAttemptSaveNoteIDs = noteIDs.intersection(
            activeContext.expectedSaveNoteIDs
        )
        activeContext.handledSaveFailureNoteIDs.removeAll()
        activeContext.limitExceededSaveFailuresInCurrentAttempt.removeAll()
        activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt.removeAll()
        activeContext.saveNoteIDsAwaitingResponseInCurrentAttempt.removeAll()
        self.activeContext = activeContext
    }

    mutating func markMaterializedSaveNoteIDs(_ noteIDs: Set<String>) {
        guard var activeContext else { return }
        let materializedNoteIDs = noteIDs
            .intersection(activeContext.activeAttemptSaveNoteIDs)
            .intersection(activeContext.unresolvedSaveNoteIDs)
        activeContext.saveNoteIDsAwaitingResponseInCurrentAttempt.formUnion(
            materializedNoteIDs
        )
        self.activeContext = activeContext
    }

    mutating func markSaveResponsesReceived(noteIDs: Set<String>) {
        guard var activeContext else { return }
        activeContext.saveNoteIDsAwaitingResponseInCurrentAttempt.subtract(noteIDs)
        self.activeContext = activeContext
    }

    func hasHandledSaveFailure(noteID: String) -> Bool {
        activeContext?.handledSaveFailureNoteIDs.contains(noteID) == true
    }

    mutating func claimSaveFailure(noteID: String) -> Bool {
        guard var activeContext else { return false }
        guard activeContext.expectedSaveNoteIDs.contains(noteID),
              activeContext.activeAttemptSaveNoteIDs.contains(noteID)
        else {
            return false
        }

        if activeContext.provisionalBatchFailureMessagesByNoteID.removeValue(
            forKey: noteID
        ) != nil {
            activeContext.handledSaveFailureNoteIDs.remove(noteID)
        }
        let insertion = activeContext.handledSaveFailureNoteIDs.insert(noteID)
        self.activeContext = activeContext
        return insertion.inserted
    }

    mutating func markLimitExceededSave(noteID: String, message: String) {
        guard var activeContext else { return }
        guard activeContext.expectedSaveNoteIDs.contains(noteID),
              activeContext.activeAttemptSaveNoteIDs.contains(noteID),
              activeContext.unresolvedSaveNoteIDs.contains(noteID)
        else {
            return
        }

        activeContext.handledSaveFailureNoteIDs.insert(noteID)
        activeContext.limitExceededSaveFailuresInCurrentAttempt[noteID] = message
        activeContext.batchRetryCandidateNoteIDs.remove(noteID)
        activeContext.provisionalBatchFailureMessagesByNoteID.removeValue(forKey: noteID)
        self.activeContext = activeContext
    }

    mutating func handleLimitExceededSaveFailures(
        _ failures: [CloudKitAttributedSaveFailure]
    ) {
        for failure in failures {
            markLimitExceededSave(noteID: failure.noteID, message: failure.message)
        }
    }

    mutating func stageBatchRequestFailedSave(noteID: String, message: String) {
        guard var activeContext else { return }
        guard activeContext.expectedSaveNoteIDs.contains(noteID),
              activeContext.activeAttemptSaveNoteIDs.contains(noteID),
              activeContext.unresolvedSaveNoteIDs.contains(noteID)
        else {
            return
        }

        guard !activeContext.batchRetryAttemptedNoteIDs.contains(noteID),
              activeContext.acceptsBatchRetryCandidates
        else {
            activeContext.failureMessage = activeContext.failureMessage ?? message
            self.activeContext = activeContext
            return
        }

        activeContext.batchRetryCandidateNoteIDs.insert(noteID)
        activeContext.provisionalBatchFailureMessagesByNoteID.removeValue(forKey: noteID)
        self.activeContext = activeContext
    }

    mutating func deferBatchRequestFailedSave(noteID: String, message: String) {
        guard var activeContext else { return }
        guard activeContext.expectedSaveNoteIDs.contains(noteID),
              activeContext.activeAttemptSaveNoteIDs.contains(noteID),
              activeContext.unresolvedSaveNoteIDs.contains(noteID)
        else {
            return
        }

        activeContext.provisionalBatchFailureMessagesByNoteID[noteID] = message
        self.activeContext = activeContext
    }

    mutating func handleBatchRequestFailedSaveFailures(
        _ failures: [CloudKitAttributedSaveFailure],
        canRetry: Bool
    ) {
        for failure in failures {
            guard claimSaveFailure(noteID: failure.noteID) else { continue }
            if canRetry {
                stageBatchRequestFailedSave(
                    noteID: failure.noteID,
                    message: failure.message
                )
            } else {
                deferBatchRequestFailedSave(
                    noteID: failure.noteID,
                    message: failure.message
                )
            }
        }
    }

    mutating func sealSendAttempt() {
        guard var activeContext else { return }
        if activeContext.failureMessage == nil {
            activeContext.failureMessage = activeContext
                .provisionalBatchFailureMessagesByNoteID
                .sorted { $0.key < $1.key }
                .first?
                .value
        }
        activeContext.provisionalBatchFailureMessagesByNoteID.removeAll()
        self.activeContext = activeContext
    }

    mutating func takeBatchRetryCandidates() -> Set<String> {
        guard var activeContext else { return [] }

        let candidates = activeContext.batchRetryCandidateNoteIDs
            .intersection(activeContext.unresolvedSaveNoteIDs)
        activeContext.batchRetryCandidateNoteIDs.removeAll()
        activeContext.batchRetryAttemptedNoteIDs.formUnion(candidates)
        self.activeContext = activeContext
        return candidates
    }

    mutating func closeBatchRetryPhase() {
        guard var activeContext else { return }
        activeContext.acceptsBatchRetryCandidates = false
        activeContext.batchRetryCandidateNoteIDs.removeAll()
        self.activeContext = activeContext
    }

    mutating func begin(
        expectedSaveNoteIDs: Set<String>,
        expectedDeleteNoteIDs: Set<String>,
        forcedBlockedSaveNoteIDs: Set<String> = []
    ) {
        activeContext = CloudKitSendBatchContext(
            expectedSaveNoteIDs: expectedSaveNoteIDs,
            expectedDeleteNoteIDs: expectedDeleteNoteIDs,
            forcedBlockedSaveNoteIDs: forcedBlockedSaveNoteIDs
        )
    }

    mutating func cancel() {
        activeContext = nil
    }

    mutating func markFailure(_ message: String) {
        guard var activeContext else { return }
        activeContext.failureMessage = activeContext.failureMessage ?? message
        self.activeContext = activeContext
    }

    mutating func markSaved(_ note: StickyNote) {
        guard var activeContext else { return }
        guard activeContext.expectedSaveNoteIDs.contains(note.id) else { return }

        activeContext.savedNotesByID[note.id] = note.markedClean()
        activeContext.unresolvedSaveNoteIDs.remove(note.id)
        activeContext.pendingNotesRequiringRetryByID.removeValue(forKey: note.id)
        activeContext.freshRetryCandidatesByID.removeValue(forKey: note.id)
        activeContext.freshRetryAttemptedNoteIDs.remove(note.id)
        activeContext.batchRetryCandidateNoteIDs.remove(note.id)
        activeContext.provisionalBatchFailureMessagesByNoteID.removeValue(forKey: note.id)
        activeContext.saveNoteIDsAwaitingResponseInCurrentAttempt.remove(note.id)
        self.activeContext = activeContext
    }

    mutating func markDeleted(noteID: String) {
        guard var activeContext else { return }
        guard activeContext.expectedDeleteNoteIDs.contains(noteID) else { return }

        activeContext.deletedNoteIDs.insert(noteID)
        activeContext.unresolvedDeleteNoteIDs.remove(noteID)
        self.activeContext = activeContext
    }

    mutating func markConflict(noteID: String, remoteNote: StickyNote) {
        guard var activeContext else { return }
        guard activeContext.expectedSaveNoteIDs.contains(noteID) else { return }

        activeContext.conflictsByNoteID[noteID] = remoteNote.markedClean()
        activeContext.unresolvedSaveNoteIDs.remove(noteID)
        activeContext.pendingNotesRequiringRetryByID.removeValue(forKey: noteID)
        activeContext.freshRetryCandidatesByID.removeValue(forKey: noteID)
        activeContext.freshRetryAttemptedNoteIDs.remove(noteID)
        activeContext.batchRetryCandidateNoteIDs.remove(noteID)
        activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt.insert(noteID)
        self.activeContext = activeContext
    }

    mutating func markPermanentlyRejectedSave(noteID: String, message: String) {
        guard var activeContext else { return }
        guard activeContext.expectedSaveNoteIDs.contains(noteID) else { return }

        activeContext.permanentlyRejectedSaveNoteIDs.insert(noteID)
        activeContext.unresolvedSaveNoteIDs.remove(noteID)
        activeContext.pendingNotesRequiringRetryByID.removeValue(forKey: noteID)
        activeContext.freshRetryCandidatesByID.removeValue(forKey: noteID)
        activeContext.freshRetryAttemptedNoteIDs.remove(noteID)
        activeContext.batchRetryCandidateNoteIDs.remove(noteID)
        activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt.insert(noteID)
        activeContext.failureMessage = activeContext.failureMessage ?? message
        self.activeContext = activeContext
    }

    mutating func handleUnknownItemSave(
        _ note: StickyNote,
        message: String
    ) -> CloudKitUnknownItemSaveDisposition {
        guard var activeContext,
              activeContext.expectedSaveNoteIDs.contains(note.id)
        else {
            return .ignored
        }

        let hasStaleCloudKitSystemFields = note.cloudKitSystemFieldsData != nil
            || note.cloudRevision != nil
        guard hasStaleCloudKitSystemFields else {
            activeContext.permanentlyRejectedSaveNoteIDs.insert(note.id)
            activeContext.unresolvedSaveNoteIDs.remove(note.id)
            activeContext.pendingNotesRequiringRetryByID.removeValue(forKey: note.id)
            activeContext.freshRetryCandidatesByID.removeValue(forKey: note.id)
            activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt.insert(note.id)
            activeContext.failureMessage = activeContext.failureMessage ?? message
            self.activeContext = activeContext
            return .permanentlyRejected
        }

        let retriableNote = note.resettingCloudKitSystemFields()
        guard activeContext.forcedBlockedSaveNoteIDs.contains(note.id) else {
            activeContext.pendingNotesRequiringRetryByID[note.id] = retriableNote
            activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt.insert(note.id)
            self.activeContext = activeContext
            return .deferredRetry(retriableNote)
        }

        guard !activeContext.freshRetryAttemptedNoteIDs.contains(note.id) else {
            activeContext.permanentlyRejectedSaveNoteIDs.insert(note.id)
            activeContext.unresolvedSaveNoteIDs.remove(note.id)
            activeContext.freshRetryCandidatesByID.removeValue(forKey: note.id)
            activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt.insert(note.id)
            activeContext.failureMessage = activeContext.failureMessage ?? message
            self.activeContext = activeContext
            return .permanentlyRejected
        }

        activeContext.freshRetryCandidatesByID[note.id] = retriableNote
        activeContext.resolvedSaveFailureRootNoteIDsInCurrentAttempt.insert(note.id)
        self.activeContext = activeContext
        return .retryImmediately(retriableNote)
    }

    mutating func takeFreshRetryCandidates() -> [StickyNote] {
        guard var activeContext else { return [] }

        let noteIDs = activeContext.freshRetryCandidatesByID.keys.sorted()
        let notes = noteIDs.compactMap { activeContext.freshRetryCandidatesByID[$0] }
        activeContext.freshRetryAttemptedNoteIDs.formUnion(noteIDs)
        activeContext.freshRetryCandidatesByID.removeAll()
        self.activeContext = activeContext
        return notes
    }

    func shouldIncludeBlockedSave(noteID: String) -> Bool {
        activeContext?.forcedBlockedSaveNoteIDs.contains(noteID) == true
    }

    mutating func finalize() -> CloudSyncBatchResult {
        sealSendAttempt()
        guard let activeContext else {
            return CloudSyncBatchResult()
        }

        var result = CloudSyncBatchResult(
            savedNotes: Array(activeContext.savedNotesByID.values),
            deletedNoteIDs: Array(activeContext.deletedNoteIDs).sorted(),
            pendingNotesRequiringRetry: Array(activeContext.pendingNotesRequiringRetryByID.values),
            permanentlyRejectedSaveNoteIDs: activeContext.permanentlyRejectedSaveNoteIDs.sorted(),
            conflicts: activeContext.conflictsByNoteID.keys.sorted().compactMap { noteID in
                guard let remoteNote = activeContext.conflictsByNoteID[noteID] else {
                    return nil
                }

                return CloudSyncConflict(localNoteID: noteID, remoteNote: remoteNote)
            },
            failureMessage: activeContext.failureMessage
        )

        let unresolvedRetrySaveIDs = activeContext.unresolvedSaveNoteIDs
            .subtracting(activeContext.pendingNotesRequiringRetryByID.keys)

        if result.failureMessage == nil,
           (!unresolvedRetrySaveIDs.isEmpty || !activeContext.unresolvedDeleteNoteIDs.isEmpty)
        {
            result.failureMessage = "Some CloudKit changes are still pending."
        }

        self.activeContext = nil
        return result
    }
}

private struct CloudKitSendBatchContext {
    let expectedSaveNoteIDs: Set<String>
    let expectedDeleteNoteIDs: Set<String>
    let forcedBlockedSaveNoteIDs: Set<String>
    var savedNotesByID: [String: StickyNote] = [:]
    var deletedNoteIDs: Set<String> = []
    var pendingNotesRequiringRetryByID: [String: StickyNote] = [:]
    var permanentlyRejectedSaveNoteIDs: Set<String> = []
    var conflictsByNoteID: [String: StickyNote] = [:]
    var freshRetryCandidatesByID: [String: StickyNote] = [:]
    var freshRetryAttemptedNoteIDs: Set<String> = []
    var activeAttemptSaveNoteIDs: Set<String> = []
    var handledSaveFailureNoteIDs: Set<String> = []
    var limitExceededSaveFailuresInCurrentAttempt: [String: String] = [:]
    var resolvedSaveFailureRootNoteIDsInCurrentAttempt: Set<String> = []
    var saveNoteIDsAwaitingResponseInCurrentAttempt: Set<String> = []
    var batchRetryCandidateNoteIDs: Set<String> = []
    var batchRetryAttemptedNoteIDs: Set<String> = []
    var acceptsBatchRetryCandidates = true
    var provisionalBatchFailureMessagesByNoteID: [String: String] = [:]
    var failureMessage: String?
    var unresolvedSaveNoteIDs: Set<String>
    var unresolvedDeleteNoteIDs: Set<String>

    init(
        expectedSaveNoteIDs: Set<String>,
        expectedDeleteNoteIDs: Set<String>,
        forcedBlockedSaveNoteIDs: Set<String>
    ) {
        self.expectedSaveNoteIDs = expectedSaveNoteIDs
        self.expectedDeleteNoteIDs = expectedDeleteNoteIDs
        self.forcedBlockedSaveNoteIDs = forcedBlockedSaveNoteIDs.intersection(expectedSaveNoteIDs)
        unresolvedSaveNoteIDs = expectedSaveNoteIDs
        unresolvedDeleteNoteIDs = expectedDeleteNoteIDs
    }
}

enum CloudKitRetryScopePartitioner {
    static func halves(_ noteIDs: [String]) -> [[String]] {
        let sortedNoteIDs = noteIDs.sorted()
        guard sortedNoteIDs.count > 1 else { return [] }

        let midpoint = sortedNoteIDs.count / 2
        return [
            Array(sortedNoteIDs[..<midpoint]),
            Array(sortedNoteIDs[midpoint...]),
        ]
    }
}

struct CloudKitLimitExceededRetryOutcome: Equatable {
    var failures: [String: String]
    var unresolvedNoteIDs: Set<String>
}

struct CloudKitLimitExceededRecoveryResult: Equatable {
    var blockedFailures: [CloudKitAttributedSaveFailure]
    var attemptedScopes: [[String]]
    var unresolvedNoteIDs: Set<String>
}

enum CloudKitLimitExceededRecoveryExecutor {
    static func recover(
        initialFailures: [String: String],
        unresolvedNoteIDs initialUnresolvedNoteIDs: Set<String>,
        performScopedRetry: ([String]) async -> CloudKitLimitExceededRetryOutcome
    ) async -> CloudKitLimitExceededRecoveryResult {
        var unresolvedNoteIDs = initialUnresolvedNoteIDs
        var virtuallyBlockedNoteIDs: Set<String> = []
        var queuedScopes = retryScopes(
            for: initialFailures,
            unresolvedNoteIDs: unresolvedNoteIDs
        )
        var attemptedScopes: [[String]] = []
        var blockedFailures: [CloudKitAttributedSaveFailure] = []

        while !queuedScopes.isEmpty {
            let scheduledScope = queuedScopes.removeFirst()
            let scope = scheduledScope
                .filter { unresolvedNoteIDs.contains($0) }
                .sorted()
            guard !scope.isEmpty else { continue }

            attemptedScopes.append(scope)
            let outcome = await performScopedRetry(scope)
            unresolvedNoteIDs.formIntersection(outcome.unresolvedNoteIDs)
            unresolvedNoteIDs.subtract(virtuallyBlockedNoteIDs)

            let scopeNoteIDs = Set(scope)
            let retryFailures = outcome.failures.filter {
                scopeNoteIDs.contains($0.key) && unresolvedNoteIDs.contains($0.key)
            }
            guard !retryFailures.isEmpty else { continue }

            if scope.count == 1,
               let noteID = scope.first,
               let message = retryFailures[noteID]
            {
                blockedFailures.append(
                    CloudKitAttributedSaveFailure(noteID: noteID, message: message)
                )
                virtuallyBlockedNoteIDs.insert(noteID)
                unresolvedNoteIDs.remove(noteID)
                continue
            }

            queuedScopes.append(
                contentsOf: retryScopes(
                    for: retryFailures,
                    unresolvedNoteIDs: unresolvedNoteIDs
                )
            )
        }

        return CloudKitLimitExceededRecoveryResult(
            blockedFailures: blockedFailures.sorted { $0.noteID < $1.noteID },
            attemptedScopes: attemptedScopes,
            unresolvedNoteIDs: unresolvedNoteIDs
        )
    }

    private static func retryScopes(
        for failures: [String: String],
        unresolvedNoteIDs: Set<String>
    ) -> [[String]] {
        let noteIDs = failures.keys
            .filter { unresolvedNoteIDs.contains($0) }
            .sorted()
        guard noteIDs.count > 1 else {
            return noteIDs.map { [$0] }
        }
        return CloudKitRetryScopePartitioner.halves(noteIDs)
    }
}
