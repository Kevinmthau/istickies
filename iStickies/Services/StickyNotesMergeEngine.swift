import Foundation

struct StickyNotesMergeOutcome: Sendable {
    var notes: [StickyNote]
}

struct StickyNotesSyncApplicationOutcome: Sendable {
    var notes: [StickyNote]
    var pendingDeletionIDs: Set<String>
}

enum StickyNotesMergeEngine {
    static func merge(
        localNotes: [StickyNote],
        remoteNotes: [StickyNote],
        pendingDeletionIDs: Set<String>
    ) -> StickyNotesMergeOutcome {
        var unmatchedLocal = Dictionary(uniqueKeysWithValues: localNotes.map { ($0.id, $0) })
        var mergedNotes: [StickyNote] = []

        for remoteNote in remoteNotes {
            guard !pendingDeletionIDs.contains(remoteNote.id) else {
                unmatchedLocal.removeValue(forKey: remoteNote.id)
                continue
            }

            guard let localNote = unmatchedLocal.removeValue(forKey: remoteNote.id) else {
                mergedNotes.append(remoteNote.markedClean())
                continue
            }

            if localNote.needsCloudUpload
                && remoteNote.lastModified > localNote.lastModified
                && remoteNote.content != localNote.content
            {
                mergedNotes.append(remoteReplacement(from: remoteNote, preservingWindowStateFrom: localNote))
                mergedNotes.append(makeConflictCopy(from: localNote))
                continue
            }

            if localNote.needsCloudUpload {
                mergedNotes.append(localNote)
            } else if remoteNote.lastModified >= localNote.lastModified || remoteNote.content != localNote.content {
                mergedNotes.append(remoteReplacement(from: remoteNote, preservingWindowStateFrom: localNote))
            } else {
                mergedNotes.append(localNote)
            }
        }

        for remainingLocalNote in unmatchedLocal.values where remainingLocalNote.needsCloudUpload {
            mergedNotes.append(remainingLocalNote)
        }

        return StickyNotesMergeOutcome(notes: mergedNotes)
    }

    static func apply(
        syncResult: CloudSyncBatchResult,
        to localNotes: [StickyNote],
        pendingDeletionIDs: Set<String>
    ) -> StickyNotesSyncApplicationOutcome {
        var notes = localNotes
        var pendingDeletionIDs = pendingDeletionIDs

        for deletedID in syncResult.deletedNoteIDs {
            pendingDeletionIDs.remove(deletedID)
        }

        for savedNote in syncResult.savedNotes {
            replace(note: savedNote.markedClean(), in: &notes)
        }

        for pendingNote in syncResult.pendingNotesRequiringRetry {
            replace(note: pendingNote, in: &notes)
        }

        for conflict in syncResult.conflicts {
            guard let localNote = notes.first(where: { $0.id == conflict.localNoteID }) else { continue }
            replace(
                note: remoteReplacement(from: conflict.remoteNote, preservingWindowStateFrom: localNote),
                in: &notes
            )
            notes.append(makeConflictCopy(from: localNote))
        }

        return StickyNotesSyncApplicationOutcome(
            notes: notes,
            pendingDeletionIDs: pendingDeletionIDs
        )
    }

    private static func replace(note: StickyNote, in notes: inout [StickyNote]) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
    }

    private static func remoteReplacement(
        from remote: StickyNote,
        preservingWindowStateFrom local: StickyNote
    ) -> StickyNote {
        var merged = remote.markedClean()
        merged.isOpen = local.isOpen
        merged.preferredFrame = local.preferredFrame ?? remote.preferredFrame
        return merged
    }

    private static func makeConflictCopy(from note: StickyNote) -> StickyNote {
        StickyNote(
            content: note.content,
            titleOverride: "Conflict Copy",
            color: note.color,
            createdAt: note.createdAt,
            lastModified: note.lastModified,
            isOpen: true,
            preferredFrame: note.preferredFrame,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: nil
        )
    }
}
