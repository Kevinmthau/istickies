import Foundation
import OSLog
import SwiftUI

private let stickyNotesDefaultCloudSyncDelay: TimeInterval = 0.75

enum StickyNotesSyncState: Equatable {
    case idle
    case syncing
    case failed(String)
}

enum StickyNoteDraftPersistenceResult: Equatable {
    case persisted(primaryContent: String)
    case conflicted(primaryContent: String, conflictCopyID: String)
    case missing

    var primaryContent: String? {
        switch self {
        case let .persisted(primaryContent), let .conflicted(primaryContent, _):
            return primaryContent
        case .missing:
            return nil
        }
    }
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
    private var cachedCloudPersistedState = StickyNotesCloudPersistedState()
    private var hasLocalLoadFailure = false

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
        StickyNotesLog.persistence.info("Local snapshot load started")
        defer {
            hasLoaded = true
            hasFinishedInitialLoad = true
        }

        do {
            let snapshot = try await fileStore.load()
            cachedCloudPersistedState = StickyNotesCloudPersistedState(
                stateSerializationData: snapshot.cloudKitStateSerializationData,
                accountIdentifier: snapshot.cloudAccountIdentifier,
                remoteNotes: snapshot.cloudRemoteCache
            )
            await cloudService.restore(persistedState: cachedCloudPersistedState)
            applyLoadedSnapshot(snapshot)
            StickyNotesLog.persistence.info(
                """
                Local snapshot loaded noteCount: \(snapshot.notes.count, privacy: .public) \
                pendingDeletionCount: \(snapshot.pendingDeletionIDs.count, privacy: .public) \
                remoteCacheCount: \(snapshot.cloudRemoteCache.count, privacy: .public) \
                hasCloudState: \(snapshot.cloudKitStateSerializationData != nil, privacy: .public) \
                hasCloudAccount: \(snapshot.cloudAccountIdentifier != nil, privacy: .public)
                """
            )
        } catch {
            hasLocalLoadFailure = true
            syncState = .failed(error.localizedDescription)
            lastErrorMessage = "Failed to restore notes locally: \(error.localizedDescription)"
            StickyNotesLog.persistence.error(
                "Local snapshot load failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func note(withID id: String) -> StickyNote? {
        notesByID[id]
    }

    func notes(orderedBy ids: [String]) -> [StickyNote] {
        ids.compactMap { notesByID[$0] }
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

    @discardableResult
    func updateContent(
        id: String,
        content: String,
        expectedBaseContent: String
    ) -> StickyNoteDraftPersistenceResult {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return .missing }

        let currentNote = notes[index]
        guard currentNote.content != content else {
            return .persisted(primaryContent: currentNote.content)
        }

        guard currentNote.content == expectedBaseContent else {
            let conflictCopy = makeDraftConflictCopy(from: currentNote, content: content)
            commitStateChange(
                CommitOptions(resortNotes: true, syncDelay: stickyNotesDefaultCloudSyncDelay)
            ) {
                notes.append(conflictCopy)
                return true
            }
            StickyNotesLog.sync.info("Editor draft conflict copy created")
            return .conflicted(
                primaryContent: currentNote.content,
                conflictCopyID: conflictCopy.id
            )
        }

        mutateNote(
            id: id,
            touchModifiedAt: true,
            commitOptions: CommitOptions(resortNotes: true, syncDelay: stickyNotesDefaultCloudSyncDelay)
        ) { note in
            note.content = content
        }
        return .persisted(primaryContent: content)
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
        guard hasLoaded else { return }
        guard !isSynchronizing else {
            StickyNotesLog.sync.debug("Sync request ignored because a sync is already running")
            return
        }
        guard !hasLocalLoadFailure else {
            StickyNotesLog.sync.warning("Sync blocked after unrecoverable local snapshot load failure")
            return
        }

        isSynchronizing = true
        syncState = .syncing
        var remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness?
        StickyNotesLog.sync.info(
            """
            Sync started localNoteCount: \(self.notes.count, privacy: .public) \
            pendingDeletionCount: \(self.pendingDeletionIDs.count, privacy: .public) \
            dirtyNoteCount: \(self.notes.filter(\.needsCloudUpload).count, privacy: .public)
            """
        )

        do {
            let remoteSnapshot = try await cloudService.fetchAllNotes()
            remoteSnapshotCompleteness = remoteSnapshot.completeness
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
            let mergeOutcome = StickyNotesMergeEngine.merge(
                localNotes: notes,
                remoteNotes: remoteSnapshot.notes,
                pendingDeletionIDs: pendingDeletionIDs,
                remoteSnapshotCompleteness: remoteSnapshot.completeness
            )
            var mergedNotes = enforceYellowNotes(mergeOutcome.notes)
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
            if mergedNotes != notes {
                notes = sortNotes(mergedNotes)
                persistSnapshot()
            }
            if case let .unavailable(message) = remoteSnapshot.completeness {
                throw StickyNotesCloudSyncError(message: message)
            }
            let outgoingSaves = notes.filter(\.needsCloudUpload)
            let outgoingSavesByID = Dictionary(uniqueKeysWithValues: outgoingSaves.map { ($0.id, $0) })
            let outgoingDeletionIDs = Array(pendingDeletionIDs)
            StickyNotesLog.sync.info(
                """
                Sending CloudKit changes saveCount: \(outgoingSaves.count, privacy: .public) \
                deleteCount: \(outgoingDeletionIDs.count, privacy: .public)
                """
            )
            let syncResult = await cloudService.syncChanges(
                saves: outgoingSaves,
                deletions: outgoingDeletionIDs
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
            cachedCloudPersistedState = trustedCloudPersistedState(
                await cloudService.currentPersistedState(),
                after: remoteSnapshot.completeness
            )
            lastErrorMessage = nil
            syncState = .idle
            persistSnapshot()
            StickyNotesLog.sync.info(
                """
                Sync completed noteCount: \(self.notes.count, privacy: .public) \
                pendingDeletionCount: \(self.pendingDeletionIDs.count, privacy: .public) \
                dirtyNoteCount: \(self.notes.filter(\.needsCloudUpload).count, privacy: .public)
                """
            )

            if hasPendingCloudChanges {
                StickyNotesLog.sync.info("Scheduling follow-up sync delaySeconds: \(1.0, privacy: .public)")
                scheduleCloudSync(after: 1.0)
            }
        } catch {
            syncState = .failed(error.localizedDescription)
            let persistedState = await cloudService.currentPersistedState()
            if let remoteSnapshotCompleteness {
                cachedCloudPersistedState = trustedCloudPersistedState(
                    persistedState,
                    after: remoteSnapshotCompleteness
                )
            } else {
                cachedCloudPersistedState = persistedState
            }
            lastErrorMessage = "Cloud sync failed: \(error.localizedDescription)"
            persistSnapshot()
            StickyNotesLog.sync.error(
                """
                Sync failed pendingDeletionCount: \(self.pendingDeletionIDs.count, privacy: .public) \
                dirtyNoteCount: \(self.notes.filter(\.needsCloudUpload).count, privacy: .public) \
                error: \(error.localizedDescription, privacy: .private)
                """
            )

            if hasPendingCloudChanges {
                StickyNotesLog.sync.info("Scheduling sync retry delaySeconds: \(5.0, privacy: .public)")
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

        if commitOptions.resortNotes {
            var updatedNotes = notes
            updatedNotes[index] = updated
            let sortedNotes = sortNotes(updatedNotes)
            commitStateChange(
                CommitOptions(resortNotes: false, syncDelay: commitOptions.syncDelay)
            ) {
                guard sortedNotes != notes else { return false }
                notes = sortedNotes
                return true
            }
        } else {
            commitStateChange(commitOptions) {
                notes[index] = updated
                return true
            }
        }
    }

    private var hasPendingCloudChanges: Bool {
        notes.contains(where: \.needsCloudUpload) || !pendingDeletionIDs.isEmpty
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

    private func sortNotes(_ unsortedNotes: [StickyNote]) -> [StickyNote] {
        unsortedNotes.sorted {
            if $0.lastModified != $1.lastModified {
                return $0.lastModified > $1.lastModified
            }

            return $0.createdAt > $1.createdAt
        }
    }

    private func makeDraftConflictCopy(from note: StickyNote, content: String) -> StickyNote {
        StickyNote(
            content: content,
            titleOverride: "Conflict Copy",
            color: note.color,
            createdAt: note.createdAt,
            lastModified: Date(),
            isOpen: true,
            preferredFrame: note.preferredFrame,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: nil
        )
    }

    private func applyLoadedSnapshot(_ snapshot: StickyNotesSnapshot) {
        let loadedNotes = sortNotes(
            enforceYellowNotes(
                requeueLoadedNotesIfNeeded(
                    snapshot.notes,
                    needsCloudBootstrap: snapshot.cloudKitStateSerializationData == nil
                        && snapshot.cloudAccountIdentifier == nil
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
        guard !hasLocalLoadFailure else {
            StickyNotesLog.persistence.warning(
                "Snapshot persistence skipped after unrecoverable local load failure"
            )
            return
        }

        snapshotGeneration += 1
        let snapshotGeneration = snapshotGeneration
        let snapshot = StickyNotesSnapshot(
            notes: notes,
            pendingDeletionIDs: Array(pendingDeletionIDs).sorted(),
            lastSuccessfulCloudSync: lastSuccessfulCloudSync,
            cloudKitStateSerializationData: cachedCloudPersistedState.stateSerializationData,
            cloudAccountIdentifier: cachedCloudPersistedState.accountIdentifier,
            cloudRemoteCache: cachedCloudPersistedState.remoteNotes
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
                StickyNotesLog.persistence.error(
                    """
                    Local snapshot save failed generation: \(snapshotGeneration, privacy: .public) \
                    noteCount: \(snapshot.notes.count, privacy: .public) \
                    pendingDeletionCount: \(snapshot.pendingDeletionIDs.count, privacy: .public) \
                    error: \(error.localizedDescription, privacy: .private)
                    """
                )
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
