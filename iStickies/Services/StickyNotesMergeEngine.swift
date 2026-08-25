import Foundation

struct StickyNotesMergeOutcome: Sendable {
    var notes: [StickyNote]
}

struct StickyNotesSyncApplicationOutcome: Sendable {
    var notes: [StickyNote]
    var pendingDeletionIDs: Set<String>
}

enum StickyNotesMergeEngine {
    static func mergeLoadedNotes(
        currentNotes: [StickyNote],
        loadedNotes: [StickyNote]
    ) -> [StickyNote] {
        guard !currentNotes.isEmpty else { return loadedNotes }

        var mergedNotesByID = Dictionary(uniqueKeysWithValues: loadedNotes.map { ($0.id, $0) })
        for note in currentNotes where note.needsCloudUpload || mergedNotesByID[note.id] == nil {
            mergedNotesByID[note.id] = note
        }

        return Array(mergedNotesByID.values)
    }

    static func merge(
        localNotes: [StickyNote],
        remoteNotes: [StickyNote],
        pendingDeletionIDs: Set<String>,
        remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness = .complete,
        saveVerifications: [CloudSaveVerification] = []
    ) -> StickyNotesMergeOutcome {
        var unmatchedLocal = Dictionary(uniqueKeysWithValues: localNotes.map { ($0.id, $0) })
        let saveVerificationsByNoteID = Dictionary(
            saveVerifications.map { ($0.noteID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
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

            if let verification = saveVerificationsByNoteID[localNote.id] {
                switch remoteSnapshotCompleteness {
                case .partial, .unavailable:
                    mergedNotes.append(localNote)
                    continue
                case .complete:
                    if verification.matches(remoteNote) {
                        if verification.matches(localNote) {
                            mergedNotes.append(
                                remoteReplacement(
                                    from: remoteNote,
                                    preservingWindowStateFrom: localNote
                                )
                            )
                        } else {
                            mergedNotes.append(
                                refreshedLocalNote(
                                    localNote,
                                    cloudMetadataSource: remoteNote
                                )
                            )
                        }
                        continue
                    }

                    if matchesUploadedCloudPayload(localNote, remoteNote) {
                        mergedNotes.append(
                            remoteReplacement(from: remoteNote, preservingWindowStateFrom: localNote)
                        )
                    } else {
                        mergedNotes.append(
                            remoteReplacement(from: remoteNote, preservingWindowStateFrom: localNote)
                        )
                        mergedNotes.append(makeConflictCopy(from: localNote))
                    }
                    continue
                case .remoteReset:
                    mergedNotes.append(localNote)
                    continue
                }
            }

            if localNote.needsCloudUpload
                && remoteChangedSinceLocalBase(localNote: localNote, remoteNote: remoteNote)
                && hasSharedCloudContentChanges(localNote, remoteNote)
            {
                mergedNotes.append(remoteReplacement(from: remoteNote, preservingWindowStateFrom: localNote))
                mergedNotes.append(makeConflictCopy(from: localNote))
                continue
            }

            if localNote.needsCloudUpload,
               remoteSnapshotCompleteness == .complete,
               matchesUploadedCloudPayload(localNote, remoteNote)
            {
                mergedNotes.append(
                    remoteReplacement(from: remoteNote, preservingWindowStateFrom: localNote)
                )
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

        for remainingLocalNote in unmatchedLocal.values {
            if saveVerificationsByNoteID[remainingLocalNote.id] != nil,
               remoteSnapshotCompleteness == .complete
            {
                mergedNotes.append(remainingLocalNote.resettingCloudKitSystemFields())
            } else if remainingLocalNote.needsCloudUpload
                || !remoteSnapshotCompleteness.allowsRemoteDeletions
            {
                mergedNotes.append(remainingLocalNote)
            }
        }

        return StickyNotesMergeOutcome(notes: mergedNotes)
    }

    static func apply(
        syncResult: CloudSyncBatchResult,
        to localNotes: [StickyNote],
        pendingDeletionIDs: Set<String>,
        sentNotesByID: [String: StickyNote] = [:]
    ) -> StickyNotesSyncApplicationOutcome {
        var notes = localNotes
        var pendingDeletionIDs = pendingDeletionIDs

        for deletedID in syncResult.deletedNoteIDs {
            pendingDeletionIDs.remove(deletedID)
        }

        for savedNote in syncResult.savedNotes {
            applySavedNote(
                savedNote.markedClean(),
                in: &notes,
                sentNotesByID: sentNotesByID
            )
        }

        for pendingNote in syncResult.pendingNotesRequiringRetry {
            applyPendingRetryNote(
                pendingNote,
                in: &notes,
                sentNotesByID: sentNotesByID
            )
        }

        for rejectedNoteID in syncResult.permanentlyRejectedSaveNoteIDs {
            applyPermanentlyRejectedNote(
                noteID: rejectedNoteID,
                in: &notes,
                sentNotesByID: sentNotesByID
            )
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

    private static func applySavedNote(
        _ savedNote: StickyNote,
        in notes: inout [StickyNote],
        sentNotesByID: [String: StickyNote]
    ) {
        guard let index = notes.firstIndex(where: { $0.id == savedNote.id }) else { return }

        let currentNote = notes[index]
        guard hasCloudChangesSinceSend(currentNote, sentNotesByID: sentNotesByID) else {
            notes[index] = remoteReplacement(from: savedNote, preservingWindowStateFrom: currentNote)
            return
        }

        notes[index] = refreshedLocalNote(currentNote, cloudMetadataSource: savedNote)
    }

    private static func applyPendingRetryNote(
        _ pendingNote: StickyNote,
        in notes: inout [StickyNote],
        sentNotesByID: [String: StickyNote]
    ) {
        guard let index = notes.firstIndex(where: { $0.id == pendingNote.id }) else { return }

        let currentNote = notes[index]
        guard hasCloudChangesSinceSend(currentNote, sentNotesByID: sentNotesByID) else {
            notes[index] = pendingNote
            return
        }

        notes[index] = refreshedLocalNote(currentNote, cloudMetadataSource: pendingNote)
    }

    private static func applyPermanentlyRejectedNote(
        noteID: String,
        in notes: inout [StickyNote],
        sentNotesByID: [String: StickyNote]
    ) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }),
              sentNotesByID[noteID] != nil
        else {
            return
        }

        // A local edit made after the send is a different record, so let it try again. Otherwise
        // keep the rejected payload dirty and merge-protected while blocking automatic retries.
        guard !hasCloudChangesSinceSend(notes[index], sentNotesByID: sentNotesByID) else { return }

        notes[index].needsCloudUpload = true
        notes[index].cloudUploadBlock = .permanentlyRejected
    }

    private static func hasCloudChangesSinceSend(
        _ note: StickyNote,
        sentNotesByID: [String: StickyNote]
    ) -> Bool {
        guard let sentNote = sentNotesByID[note.id] else { return false }
        return note.content != sentNote.content
            || note.lastModified != sentNote.lastModified
    }

    private static func remoteChangedSinceLocalBase(
        localNote: StickyNote,
        remoteNote: StickyNote
    ) -> Bool {
        if let localCloudRevision = localNote.cloudRevision,
           let remoteCloudRevision = remoteNote.cloudRevision
        {
            return localCloudRevision != remoteCloudRevision
        }

        return remoteNote.lastModified > localNote.lastModified
    }

    private static func hasSharedCloudContentChanges(
        _ localNote: StickyNote,
        _ remoteNote: StickyNote
    ) -> Bool {
        // `titleOverride` is never synced, so remote notes always decode it as nil. Comparing it
        // here would report a conflict on every sync for locally retitled notes.
        localNote.content != remoteNote.content
    }

    private static func matchesUploadedCloudPayload(
        _ localNote: StickyNote,
        _ remoteNote: StickyNote
    ) -> Bool {
        localNote.content == remoteNote.content
            && StickyNoteCloudTimestamp.representsSameInstant(
                localNote.lastModified,
                remoteNote.lastModified
            )
    }

    private static func refreshedLocalNote(
        _ localNote: StickyNote,
        cloudMetadataSource: StickyNote
    ) -> StickyNote {
        var refreshedNote = localNote
        refreshedNote.cloudKitSystemFieldsData = cloudMetadataSource.cloudKitSystemFieldsData
        refreshedNote.cloudRevision = cloudMetadataSource.cloudRevision
        refreshedNote.needsCloudUpload = true
        return refreshedNote
    }

    private static func remoteReplacement(
        from remote: StickyNote,
        preservingWindowStateFrom local: StickyNote
    ) -> StickyNote {
        var merged = remote.markedClean()
        merged.createdAt = min(local.createdAt, remote.createdAt)
        merged.titleOverride = local.titleOverride
        merged.isOpen = local.isOpen
        merged.preferredFrame = local.preferredFrame
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
            cloudUploadBlock: note.cloudUploadBlock,
            cloudKitSystemFieldsData: nil,
            cloudRevision: nil
        )
    }
}
