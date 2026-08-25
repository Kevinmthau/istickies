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
            activeContext.failureMessage = activeContext.failureMessage ?? message
            self.activeContext = activeContext
            return .permanentlyRejected
        }

        let retriableNote = note.resettingCloudKitSystemFields()
        guard activeContext.forcedBlockedSaveNoteIDs.contains(note.id) else {
            activeContext.pendingNotesRequiringRetryByID[note.id] = retriableNote
            self.activeContext = activeContext
            return .deferredRetry(retriableNote)
        }

        guard !activeContext.freshRetryAttemptedNoteIDs.contains(note.id) else {
            activeContext.permanentlyRejectedSaveNoteIDs.insert(note.id)
            activeContext.unresolvedSaveNoteIDs.remove(note.id)
            activeContext.freshRetryCandidatesByID.removeValue(forKey: note.id)
            activeContext.failureMessage = activeContext.failureMessage ?? message
            self.activeContext = activeContext
            return .permanentlyRejected
        }

        activeContext.freshRetryCandidatesByID[note.id] = retriableNote
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
