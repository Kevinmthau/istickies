import Foundation
import SwiftUI

enum StickyNotesSyncState: Equatable {
    case idle
    case syncing
    case failed(String)
}

@MainActor
final class StickyNotesStore: ObservableObject {
    @Published private(set) var notes: [StickyNote] = []
    @Published private(set) var syncState: StickyNotesSyncState = .idle
    @Published private(set) var lastSuccessfulCloudSync: Date?
    @Published private(set) var hasFinishedInitialLoad = false
    @Published var lastErrorMessage: String?

    private let fileStore: StickyNotesFileStore
    private let cloudService: any StickyNotesCloudSyncing
    private var pendingDeletionIDs: Set<String> = []
    private var hasLoaded = false
    private var isSynchronizing = false
    private var scheduledSyncTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var snapshotGeneration = 0
    private var cachedCloudKitStateSerializationData: Data?

    init(
        fileStore: StickyNotesFileStore = StickyNotesFileStore(),
        cloudService: any StickyNotesCloudSyncing = CloudKitStickyNotesCloudService(),
        autoLoad: Bool = true
    ) {
        self.fileStore = fileStore
        self.cloudService = cloudService

        if autoLoad {
            loadIfNeeded()
        }
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }

        Task {
            await load()
            await syncNow()
        }
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        defer { hasFinishedInitialLoad = true }

        do {
            let snapshot = try await fileStore.load()
            cachedCloudKitStateSerializationData = snapshot.cloudKitStateSerializationData
            await cloudService.restore(stateSerializationData: snapshot.cloudKitStateSerializationData)
            notes = sortNotes(requeueLoadedNotesIfNeeded(snapshot.notes, needsCloudBootstrap: snapshot.cloudKitStateSerializationData == nil))
            pendingDeletionIDs = Set(snapshot.pendingDeletionIDs)
            lastSuccessfulCloudSync = snapshot.lastSuccessfulCloudSync
        } catch {
            lastErrorMessage = "Failed to restore notes locally: \(error.localizedDescription)"
        }
    }

    func note(withID id: String) -> StickyNote? {
        notes.first(where: { $0.id == id })
    }

    @discardableResult
    func createNote() -> String {
        let note = StickyNote(color: nextColor())
        notes = sortNotes(notes + [note])
        persistSnapshot()
        scheduleCloudSync()
        return note.id
    }

    func updateContent(id: String, content: String) {
        mutateNote(id: id, touchModifiedAt: true) { note in
            note.content = content
        }
    }

    func updateColor(id: String, color: StickyNoteColor) {
        mutateNote(id: id, touchModifiedAt: true) { note in
            note.color = color
        }
    }

    func updatePreferredFrame(id: String, frame: StickyNoteFrame) {
        mutateNote(id: id, touchModifiedAt: false) { note in
            note.preferredFrame = frame
        }
    }

    func openNote(id: String) {
        mutateNote(id: id, touchModifiedAt: false) { note in
            note.isOpen = true
        }
    }

    func openAllNotes() {
        var changed = false
        notes = sortNotes(notes.map { note in
            guard !note.isOpen else { return note }
            changed = true
            var copy = note
            copy.isOpen = true
            copy.needsCloudUpload = true
            return copy
        })

        guard changed else { return }
        persistSnapshot()
        scheduleCloudSync()
    }

    func closeNote(id: String, frame: StickyNoteFrame?) {
        mutateNote(id: id, touchModifiedAt: false) { note in
            note.isOpen = false
            if let frame {
                note.preferredFrame = frame
            }
        }
    }

    func deleteNote(id: String) {
        guard notes.contains(where: { $0.id == id }) else { return }

        notes.removeAll { $0.id == id }
        pendingDeletionIDs.insert(id)
        persistSnapshot()
        scheduleCloudSync(after: 0.2)
    }

    func syncNow() async {
        guard hasLoaded, !isSynchronizing else { return }

        isSynchronizing = true
        syncState = .syncing

        do {
            let remoteNotes = try await cloudService.fetchAllNotes()
            merge(remoteNotes: remoteNotes)
            let syncResult = await cloudService.syncChanges(
                saves: notes.filter(\.needsCloudUpload),
                deletions: Array(pendingDeletionIDs)
            )
            apply(syncResult)

            if let failureMessage = syncResult.failureMessage {
                throw StickyNotesCloudSyncError(message: failureMessage)
            }

            lastSuccessfulCloudSync = Date()
            cachedCloudKitStateSerializationData = await cloudService.currentStateSerializationData()
            lastErrorMessage = nil
            syncState = .idle
            persistSnapshot()

            if notes.contains(where: \.needsCloudUpload) || !pendingDeletionIDs.isEmpty {
                scheduleCloudSync(after: 1.0)
            }
        } catch {
            syncState = .failed(error.localizedDescription)
            cachedCloudKitStateSerializationData = await cloudService.currentStateSerializationData()
            lastErrorMessage = "Cloud sync failed: \(error.localizedDescription)"
            persistSnapshot()

            if notes.contains(where: \.needsCloudUpload) || !pendingDeletionIDs.isEmpty {
                scheduleCloudSync(after: 5.0)
            }
        }

        isSynchronizing = false
    }

    private func mutateNote(
        id: String,
        touchModifiedAt: Bool,
        mutation: (inout StickyNote) -> Void
    ) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }

        let original = notes[index]
        var updated = original
        mutation(&updated)
        updated.needsCloudUpload = true
        if touchModifiedAt {
            updated.lastModified = Date()
        }

        guard updated != original else { return }

        notes[index] = updated
        notes = sortNotes(notes)
        persistSnapshot()
        scheduleCloudSync()
    }

    private func merge(remoteNotes: [StickyNote]) {
        var unmatchedLocal = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })
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

            if localNote.needsCloudUpload && remoteNote.lastModified > localNote.lastModified
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

        for remainingLocalNote in unmatchedLocal.values {
            if remainingLocalNote.needsCloudUpload {
                mergedNotes.append(remainingLocalNote)
            }
        }

        notes = sortNotes(mergedNotes)
        persistSnapshot()
    }

    private func apply(_ syncResult: CloudSyncBatchResult) {
        for deletedID in syncResult.deletedNoteIDs {
            pendingDeletionIDs.remove(deletedID)
        }

        for savedNote in syncResult.savedNotes {
            replaceLocalNote(savedNote.markedClean())
        }

        for pendingNote in syncResult.pendingNotesRequiringRetry {
            replaceLocalNote(pendingNote)
        }

        for conflict in syncResult.conflicts {
            guard let local = note(withID: conflict.localNoteID) else { continue }
            resolveConflict(local: local, remote: conflict.remoteNote)
        }
    }

    private func resolveConflict(local: StickyNote, remote: StickyNote) {
        replaceLocalNote(remoteReplacement(from: remote, preservingWindowStateFrom: local))
        notes = sortNotes(notes + [makeConflictCopy(from: local)])
        persistSnapshot()
    }

    private func replaceLocalNote(_ note: StickyNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index] = note
        notes = sortNotes(notes)
    }

    private func remoteReplacement(from remote: StickyNote, preservingWindowStateFrom local: StickyNote) -> StickyNote {
        var merged = remote.markedClean()
        merged.isOpen = local.isOpen
        merged.preferredFrame = local.preferredFrame ?? remote.preferredFrame
        return merged
    }

    private func makeConflictCopy(from note: StickyNote) -> StickyNote {
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

    private func requeueLoadedNotesIfNeeded(
        _ loadedNotes: [StickyNote],
        needsCloudBootstrap: Bool
    ) -> [StickyNote] {
        guard needsCloudBootstrap else { return loadedNotes }

        return loadedNotes.map { note in
            guard !note.needsCloudUpload else { return note }
            var copy = note
            copy.needsCloudUpload = true
            return copy
        }
    }

    private func nextColor() -> StickyNoteColor {
        .yellow
    }

    private func sortNotes(_ unsortedNotes: [StickyNote]) -> [StickyNote] {
        unsortedNotes.sorted {
            if $0.lastModified != $1.lastModified {
                return $0.lastModified > $1.lastModified
            }

            return $0.createdAt > $1.createdAt
        }
    }

    private func persistSnapshot() {
        snapshotGeneration += 1
        let snapshotGeneration = snapshotGeneration
        let snapshot = StickyNotesSnapshot(
            notes: notes,
            pendingDeletionIDs: Array(pendingDeletionIDs).sorted(),
            lastSuccessfulCloudSync: lastSuccessfulCloudSync,
            cloudKitStateSerializationData: cachedCloudKitStateSerializationData
        )
        let previousPersistenceTask = persistenceTask
        let fileStore = fileStore

        persistenceTask = Task(priority: .utility) {
            _ = await previousPersistenceTask?.result

            do {
                try await fileStore.save(snapshot, generation: snapshotGeneration)
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = "Failed to save notes locally: \(error.localizedDescription)"
                }
            }
        }
    }

    func flushPendingPersistence() async {
        while true {
            let targetGeneration = snapshotGeneration
            let persistenceTask = persistenceTask
            await persistenceTask?.value

            if snapshotGeneration <= targetGeneration {
                return
            }
        }
    }

    private func scheduleCloudSync(after delay: TimeInterval = 0.75) {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await self?.syncNow()
        }
    }
}

private struct StickyNotesCloudSyncError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
