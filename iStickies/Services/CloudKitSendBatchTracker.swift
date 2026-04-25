import Foundation

struct CloudKitSendBatchTracker {
    private var activeContext: CloudKitSendBatchContext?

    var hasActiveBatch: Bool {
        activeContext != nil
    }

    mutating func begin(expectedSaveNoteIDs: Set<String>, expectedDeleteNoteIDs: Set<String>) {
        activeContext = CloudKitSendBatchContext(
            expectedSaveNoteIDs: expectedSaveNoteIDs,
            expectedDeleteNoteIDs: expectedDeleteNoteIDs
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
        self.activeContext = activeContext
    }

    mutating func markPendingSaveForRetry(_ note: StickyNote) {
        guard var activeContext else { return }
        guard activeContext.expectedSaveNoteIDs.contains(note.id) else { return }

        activeContext.pendingNotesRequiringRetryByID[note.id] = note
        self.activeContext = activeContext
    }

    mutating func finalize() -> CloudSyncBatchResult {
        guard let activeContext else {
            return CloudSyncBatchResult()
        }

        var result = CloudSyncBatchResult(
            savedNotes: Array(activeContext.savedNotesByID.values),
            deletedNoteIDs: Array(activeContext.deletedNoteIDs).sorted(),
            pendingNotesRequiringRetry: Array(activeContext.pendingNotesRequiringRetryByID.values),
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
