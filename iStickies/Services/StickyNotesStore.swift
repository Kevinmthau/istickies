import Foundation
import SwiftUI

private let stickyNotesDefaultCloudSyncDelay: TimeInterval = 0.75

enum StickyNotesSyncState: Equatable {
    case idle
    case syncing
    case failed(String)
}

@MainActor
final class StickyNotesStore: ObservableObject {
    private struct CommitOptions {
        var resortNotes = false
        var syncDelay: TimeInterval?
    }

    @Published private(set) var notes: [StickyNote] = [] {
        didSet { notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) }) }
    }
    private var notesByID: [String: StickyNote] = [:]
    @Published private(set) var syncState: StickyNotesSyncState = .idle
    @Published private(set) var lastSuccessfulCloudSync: Date?
    @Published private(set) var hasFinishedInitialLoad = false
    @Published var lastErrorMessage: String?

    private let fileStore: StickyNotesFileStore
    private let cloudService: any StickyNotesCloudSyncing
    private var pendingDeletionIDs: Set<String> = []
    private var hasStartedLoading = false
    private var hasLoaded = false
    private var isSynchronizing = false
    private var scheduledSyncTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var snapshotGeneration = 0
    private var cachedCloudKitStateSerializationData: Data?

    init(
        fileStore: StickyNotesFileStore = StickyNotesFileStore(),
        cloudService: any StickyNotesCloudSyncing = StickyNotesCloudServiceFactory.makeDefaultService(),
        autoLoad: Bool = true
    ) {
        self.fileStore = fileStore
        self.cloudService = cloudService

        if autoLoad {
            loadIfNeeded()
        }
    }

    func loadIfNeeded() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true

        Task {
            await load()
            await syncNow()
        }
    }

    func load() async {
        guard !hasLoaded else { return }
        hasStartedLoading = true
        defer {
            hasLoaded = true
            hasFinishedInitialLoad = true
        }

        do {
            let snapshot = try await fileStore.load()
            cachedCloudKitStateSerializationData = snapshot.cloudKitStateSerializationData
            await cloudService.restore(stateSerializationData: snapshot.cloudKitStateSerializationData)
            applyLoadedSnapshot(snapshot)
        } catch {
            lastErrorMessage = "Failed to restore notes locally: \(error.localizedDescription)"
        }
    }

    func note(withID id: String) -> StickyNote? {
        notesByID[id]
    }

    @discardableResult
    func createNote() -> String {
        let note = StickyNote(color: .yellow)
        commitStateChange(
            CommitOptions(resortNotes: true, syncDelay: stickyNotesDefaultCloudSyncDelay)
        ) {
            notes.append(note)
            return true
        }
        return note.id
    }

    func updateContent(id: String, content: String) {
        mutateNote(
            id: id,
            touchModifiedAt: true,
            commitOptions: CommitOptions(resortNotes: true, syncDelay: stickyNotesDefaultCloudSyncDelay)
        ) { note in
            note.content = content
        }
    }

    func updateColor(id: String, color: StickyNoteColor) {
        mutateNote(
            id: id,
            touchModifiedAt: true,
            commitOptions: CommitOptions(resortNotes: true, syncDelay: stickyNotesDefaultCloudSyncDelay)
        ) { note in
            note.color = .yellow
        }
    }

    func updatePreferredFrame(id: String, frame: StickyNoteFrame) {
        mutateNote(
            id: id,
            touchModifiedAt: false,
            markNeedsCloudUpload: false,
            commitOptions: CommitOptions()
        ) { note in
            note.preferredFrame = frame
        }
    }

    func openNote(id: String) {
        mutateNote(
            id: id,
            touchModifiedAt: false,
            markNeedsCloudUpload: false,
            commitOptions: CommitOptions()
        ) { note in
            note.isOpen = true
        }
    }

    func openAllNotes() {
        commitStateChange {
            var changed = false
            notes = notes.map { note in
                guard !note.isOpen else { return note }
                changed = true
                var copy = note
                copy.isOpen = true
                return copy
            }
            return changed
        }
    }

    func closeNote(id: String, frame: StickyNoteFrame?) {
        mutateNote(
            id: id,
            touchModifiedAt: false,
            markNeedsCloudUpload: false,
            commitOptions: CommitOptions()
        ) { note in
            note.isOpen = false
            if let frame {
                note.preferredFrame = frame
            }
        }
    }

    func deleteNote(id: String) {
        commitStateChange(CommitOptions(syncDelay: 0.2)) {
            guard notes.contains(where: { $0.id == id }) else { return false }

            notes.removeAll { $0.id == id }
            pendingDeletionIDs.insert(id)
            return true
        }
    }

    func syncNow() async {
        guard hasLoaded, !isSynchronizing else { return }

        isSynchronizing = true
        syncState = .syncing

        do {
            let remoteSnapshot = try await cloudService.fetchAllNotes()
            let mergeOutcome = StickyNotesMergeEngine.merge(
                localNotes: notes,
                remoteNotes: remoteSnapshot.notes,
                pendingDeletionIDs: pendingDeletionIDs,
                remoteSnapshotCompleteness: remoteSnapshot.completeness
            )
            let mergedNotes = enforceYellowNotes(mergeOutcome.notes)
            if mergedNotes != notes {
                notes = sortNotes(mergedNotes)
                persistSnapshot()
            }
            let outgoingSaves = notes.filter(\.needsCloudUpload)
            let outgoingSavesByID = Dictionary(uniqueKeysWithValues: outgoingSaves.map { ($0.id, $0) })
            let outgoingDeletionIDs = Array(pendingDeletionIDs)
            let syncResult = await cloudService.syncChanges(
                saves: outgoingSaves,
                deletions: outgoingDeletionIDs
            )
            let syncOutcome = StickyNotesMergeEngine.apply(
                syncResult: syncResult,
                to: notes,
                pendingDeletionIDs: pendingDeletionIDs,
                sentNotesByID: outgoingSavesByID
            )
            notes = sortNotes(enforceYellowNotes(syncOutcome.notes))
            pendingDeletionIDs = syncOutcome.pendingDeletionIDs

            if let failureMessage = syncResult.failureMessage {
                throw StickyNotesCloudSyncError(message: failureMessage)
            }
            if let failureMessage = remoteSnapshot.completeness.failureMessage {
                throw StickyNotesCloudSyncError(message: failureMessage)
            }

            lastSuccessfulCloudSync = Date()
            cachedCloudKitStateSerializationData = await cloudService.currentStateSerializationData()
            lastErrorMessage = nil
            syncState = .idle
            persistSnapshot()

            if hasPendingCloudChanges {
                scheduleCloudSync(after: 1.0)
            }
        } catch {
            syncState = .failed(error.localizedDescription)
            cachedCloudKitStateSerializationData = await cloudService.currentStateSerializationData()
            lastErrorMessage = "Cloud sync failed: \(error.localizedDescription)"
            persistSnapshot()

            if hasPendingCloudChanges {
                scheduleCloudSync(after: 5.0)
            }
        }

        isSynchronizing = false
    }

    private func mutateNote(
        id: String,
        touchModifiedAt: Bool,
        markNeedsCloudUpload: Bool = true,
        commitOptions: CommitOptions,
        mutation: (inout StickyNote) -> Void
    ) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }

        let original = notes[index]
        var updated = original
        mutation(&updated)
        if markNeedsCloudUpload {
            updated.needsCloudUpload = true
        }
        if touchModifiedAt {
            updated.lastModified = Date()
        }

        guard updated != original else { return }

        commitStateChange(commitOptions) {
            notes[index] = updated
            return true
        }
    }

    private var hasPendingCloudChanges: Bool {
        notes.contains(where: \.needsCloudUpload) || !pendingDeletionIDs.isEmpty
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

    private func enforceYellowNotes(_ notes: [StickyNote]) -> [StickyNote] {
        notes.map { note in
            guard note.color != .yellow else { return note }

            var copy = note
            copy.color = .yellow
            copy.needsCloudUpload = true
            return copy
        }
    }

    private func sortNotes(_ unsortedNotes: [StickyNote]) -> [StickyNote] {
        unsortedNotes.sorted {
            if $0.lastModified != $1.lastModified {
                return $0.lastModified > $1.lastModified
            }

            return $0.createdAt > $1.createdAt
        }
    }

    private func applyLoadedSnapshot(_ snapshot: StickyNotesSnapshot) {
        let loadedNotes = sortNotes(
            enforceYellowNotes(
                requeueLoadedNotesIfNeeded(
                    snapshot.notes,
                    needsCloudBootstrap: snapshot.cloudKitStateSerializationData == nil
                )
            )
        )

        notes = sortNotes(
            StickyNotesMergeEngine.mergeLoadedNotes(
                currentNotes: notes,
                loadedNotes: loadedNotes
            )
        )
        pendingDeletionIDs.formUnion(snapshot.pendingDeletionIDs)

        guard let snapshotLastSuccessfulCloudSync = snapshot.lastSuccessfulCloudSync else { return }
        if let lastSuccessfulCloudSync {
            if snapshotLastSuccessfulCloudSync > lastSuccessfulCloudSync {
                self.lastSuccessfulCloudSync = snapshotLastSuccessfulCloudSync
            }
        } else {
            lastSuccessfulCloudSync = snapshotLastSuccessfulCloudSync
        }
    }

    private func commitStateChange(
        _ options: CommitOptions = CommitOptions(),
        mutation: () -> Bool
    ) {
        guard mutation() else { return }

        if options.resortNotes {
            notes = sortNotes(notes)
        }

        persistSnapshot()

        if let delay = options.syncDelay {
            scheduleCloudSync(after: delay)
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

    private func scheduleCloudSync(after delay: TimeInterval = stickyNotesDefaultCloudSyncDelay) {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
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
