import Foundation
import OSLog
import SwiftUI

private let stickyNotesDefaultCloudSyncDelay: TimeInterval = 0.75
private let stickyNotesContentPersistenceDelay: TimeInterval = 0.5

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
        var persistenceDelay: TimeInterval?
        var resortNotes = false
        var resortNoteID: String?
        var syncDelay: TimeInterval?
    }

    private(set) var notes: [StickyNote] = []
    private var notesByID: [String: StickyNote] = [:]
    private var orderedNoteIDs: [String] = []
    @Published private(set) var noteIDs: [String] = []
    @Published private(set) var openNoteIDs: [String] = []
    @Published private(set) var syncState: StickyNotesSyncState = .idle
    @Published private(set) var lastSuccessfulCloudSync: Date?
    @Published private(set) var hasFinishedInitialLoad = false
    @Published var lastErrorMessage: String?

    private let fileStore: StickyNotesFileStore
    private let cloudService: any StickyNotesCloudSyncing
    private let syncCoordinator: StickyNotesSyncCoordinator
    private var pendingDeletionIDs: Set<String> = []
    private var hasStartedLoading = false
    private var hasLoaded = false
    private var isSynchronizing = false
    private var scheduledSyncTask: Task<Void, Never>?
    private var scheduledPersistenceTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var snapshotGeneration = 0
    private var cachedCloudPersistedState = StickyNotesCloudPersistedState()
    private var hasLocalLoadFailure = false
    private var noteObservations: [String: StickyNoteObservation] = [:]

    init(
        fileStore: StickyNotesFileStore = StickyNotesFileStore(),
        cloudService: any StickyNotesCloudSyncing = StickyNotesCloudServiceFactory.makeDefaultService(),
        autoLoad: Bool = true
    ) {
        self.fileStore = fileStore
        self.cloudService = cloudService
        syncCoordinator = StickyNotesSyncCoordinator(cloudService: cloudService)

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

    func noteObservation(withID id: String) -> StickyNoteObservation {
        if let observation = noteObservations[id] {
            observation.update(note: notesByID[id])
            return observation
        }

        let observation = StickyNoteObservation(noteID: id, note: notesByID[id])
        noteObservations[id] = observation
        return observation
    }

    @discardableResult
    func createNote() -> String {
        let note = StickyNote(color: .yellow)
        commitStateChange(
            CommitOptions(resortNoteID: note.id, syncDelay: stickyNotesDefaultCloudSyncDelay)
        ) {
            addStoredNote(note)
            return true
        }
        return note.id
    }

    func updateContent(id: String, content: String) {
        mutateNote(
            id: id,
            touchModifiedAt: true,
            commitOptions: CommitOptions(
                persistenceDelay: stickyNotesContentPersistenceDelay,
                resortNoteID: id,
                syncDelay: stickyNotesDefaultCloudSyncDelay
            )
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
        guard let currentNote = notesByID[id] else { return .missing }

        guard currentNote.content != content else {
            return .persisted(primaryContent: currentNote.content)
        }

        guard currentNote.content == expectedBaseContent else {
            let conflictCopy = makeDraftConflictCopy(from: currentNote, content: content)
            commitStateChange(
                CommitOptions(
                    persistenceDelay: stickyNotesContentPersistenceDelay,
                    resortNoteID: conflictCopy.id,
                    syncDelay: stickyNotesDefaultCloudSyncDelay
                )
            ) {
                addStoredNote(conflictCopy)
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
            commitOptions: CommitOptions(
                persistenceDelay: stickyNotesContentPersistenceDelay,
                resortNoteID: id,
                syncDelay: stickyNotesDefaultCloudSyncDelay
            )
        ) { note in
            note.content = content
        }
        return .persisted(primaryContent: content)
    }

    func updateColor(id: String, color: StickyNoteColor) {
        mutateNote(
            id: id,
            touchModifiedAt: true,
            commitOptions: CommitOptions(resortNoteID: id, syncDelay: stickyNotesDefaultCloudSyncDelay)
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

            for id in orderedNoteIDs {
                guard var note = notesByID[id], !note.isOpen else { continue }
                changed = true
                note.isOpen = true
                notesByID[id] = note
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
            guard notesByID.removeValue(forKey: id) != nil else { return false }

            orderedNoteIDs.removeAll { $0 == id }
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
        defer { isSynchronizing = false }

        var remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness?
        StickyNotesLog.sync.info(
            """
            Sync started localNoteCount: \(self.notes.count, privacy: .public) \
            pendingDeletionCount: \(self.pendingDeletionIDs.count, privacy: .public) \
            dirtyNoteCount: \(self.dirtyNoteCount, privacy: .public)
            """
        )

        do {
            let remoteSnapshot = try await syncCoordinator.fetchRemoteSnapshot()
            let mergeTransition = syncCoordinator.merge(
                remoteSnapshot: remoteSnapshot,
                localState: syncLocalState
            )
            remoteSnapshotCompleteness = mergeTransition.remoteSnapshotCompleteness
            applySyncLocalState(mergeTransition.state, persistIfChanged: true)

            try syncCoordinator.validateSnapshotAllowsOutgoingChanges(
                mergeTransition.remoteSnapshotCompleteness
            )

            let outgoingChanges = syncCoordinator.outgoingChanges(from: syncLocalState)
            let syncResult = await syncCoordinator.send(outgoingChanges)
            let applicationTransition = syncCoordinator.apply(
                syncResult: syncResult,
                to: syncLocalState,
                sentNotesByID: outgoingChanges.savesByID
            )
            applySyncLocalState(applicationTransition.state, persistIfChanged: false)

            try syncCoordinator.validateCompletion(
                remoteSnapshotCompleteness: mergeTransition.remoteSnapshotCompleteness,
                syncResult: syncResult
            )

            lastSuccessfulCloudSync = Date()
            cachedCloudPersistedState = await syncCoordinator.currentPersistedState(
                after: mergeTransition.remoteSnapshotCompleteness
            )
            lastErrorMessage = nil
            syncState = .idle
            persistSnapshot()
            StickyNotesLog.sync.info(
                """
                Sync completed noteCount: \(self.notes.count, privacy: .public) \
                pendingDeletionCount: \(self.pendingDeletionIDs.count, privacy: .public) \
                dirtyNoteCount: \(self.dirtyNoteCount, privacy: .public)
                """
            )

            if let delay = syncCoordinator.followUpSyncDelay(
                hasPendingCloudChanges: hasPendingCloudChanges
            ) {
                StickyNotesLog.sync.info("Scheduling follow-up sync delaySeconds: \(delay, privacy: .public)")
                scheduleCloudSync(after: delay)
            }
        } catch {
            syncState = .failed(error.localizedDescription)
            cachedCloudPersistedState = await syncCoordinator.currentPersistedState(
                after: remoteSnapshotCompleteness
            )
            lastErrorMessage = "Cloud sync failed: \(error.localizedDescription)"
            persistSnapshot()
            StickyNotesLog.sync.error(
                """
                Sync failed pendingDeletionCount: \(self.pendingDeletionIDs.count, privacy: .public) \
                dirtyNoteCount: \(self.dirtyNoteCount, privacy: .public) \
                error: \(error.localizedDescription, privacy: .private)
                """
            )

            if let delay = syncCoordinator.retrySyncDelay(
                hasPendingCloudChanges: hasPendingCloudChanges
            ) {
                StickyNotesLog.sync.info("Scheduling sync retry delaySeconds: \(delay, privacy: .public)")
                scheduleCloudSync(after: delay)
            }
        }
    }

    private func mutateNote(
        id: String,
        touchModifiedAt: Bool,
        markNeedsCloudUpload: Bool = true,
        commitOptions: CommitOptions,
        mutation: (inout StickyNote) -> Void
    ) {
        guard let original = notesByID[id] else { return }

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
            notesByID[id] = updated
            return true
        }
    }

    private var hasPendingCloudChanges: Bool {
        notesByID.values.contains(where: \.needsCloudUpload) || !pendingDeletionIDs.isEmpty
    }

    private var dirtyNoteCount: Int {
        notesByID.values.filter(\.needsCloudUpload).count
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
        unsortedNotes.sorted(by: shouldSortBefore)
    }

    private func shouldSortBefore(_ lhs: StickyNote, _ rhs: StickyNote) -> Bool {
        if lhs.lastModified != rhs.lastModified {
            return lhs.lastModified > rhs.lastModified
        }

        return lhs.createdAt > rhs.createdAt
    }

    private func sortedNoteIDs(_ ids: [String]) -> [String] {
        ids.sorted { lhsID, rhsID in
            guard let lhs = notesByID[lhsID], let rhs = notesByID[rhsID] else {
                return lhsID < rhsID
            }

            return shouldSortBefore(lhs, rhs)
        }
    }

    private var orderedStoredNotes: [StickyNote] {
        orderedNoteIDs.compactMap { notesByID[$0] }
    }

    private func addStoredNote(_ note: StickyNote) {
        notesByID[note.id] = note
        if !orderedNoteIDs.contains(note.id) {
            orderedNoteIDs.append(note.id)
        }
    }

    private func replaceStoredNotes(with newNotes: [StickyNote], sort: Bool) {
        let previousNotesByID = notesByID
        notesByID = Dictionary(uniqueKeysWithValues: newNotes.map { ($0.id, $0) })
        orderedNoteIDs = newNotes.map(\.id)
        if sort {
            orderedNoteIDs = sortedNoteIDs(orderedNoteIDs)
        }
        publishStoredState()
        publishChangedNoteObservations(comparedTo: previousNotesByID)
    }

    private func resortStoredNote(id: String) {
        guard notesByID[id] != nil else {
            orderedNoteIDs.removeAll { $0 == id }
            return
        }

        orderedNoteIDs.removeAll { $0 == id }
        let insertionIndex = orderedNoteIDs.firstIndex { existingID in
            guard let note = notesByID[id], let existingNote = notesByID[existingID] else {
                return false
            }

            return shouldSortBefore(note, existingNote)
        } ?? orderedNoteIDs.endIndex
        orderedNoteIDs.insert(id, at: insertionIndex)
    }

    private func publishStoredState() {
        let orderedNotes = orderedStoredNotes
        if notes != orderedNotes {
            notes = orderedNotes
        }

        if noteIDs != orderedNoteIDs {
            noteIDs = orderedNoteIDs
        }

        let orderedOpenNoteIDs = orderedNoteIDs.filter { notesByID[$0]?.isOpen == true }
        if openNoteIDs != orderedOpenNoteIDs {
            openNoteIDs = orderedOpenNoteIDs
        }
    }

    private func publishChangedNoteObservations(comparedTo previousNotesByID: [String: StickyNote]) {
        let currentIDs = Set(notesByID.keys)
        let previousIDs = Set(previousNotesByID.keys)
        let changedIDs = currentIDs.union(previousIDs).filter { id in
            notesByID[id] != previousNotesByID[id]
        }

        for id in changedIDs {
            noteObservations[id]?.update(note: notesByID[id])
        }

        noteObservations = noteObservations.filter { id, observation in
            notesByID[id] != nil || observation.note != nil
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

        replaceStoredNotes(
            with: StickyNotesMergeEngine.mergeLoadedNotes(
                currentNotes: orderedStoredNotes,
                loadedNotes: loadedNotes
            ),
            sort: true
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
        let previousNotesByID = notesByID
        guard mutation() else { return }

        if let resortNoteID = options.resortNoteID {
            resortStoredNote(id: resortNoteID)
        } else if options.resortNotes {
            orderedNoteIDs = sortedNoteIDs(orderedNoteIDs)
        }

        publishStoredState()
        publishChangedNoteObservations(comparedTo: previousNotesByID)
        scheduleSnapshotPersistence(after: options.persistenceDelay)

        if let delay = options.syncDelay {
            scheduleCloudSync(after: delay)
        }
    }

    private func scheduleSnapshotPersistence(after delay: TimeInterval?) {
        guard let delay, delay > 0 else {
            persistSnapshot()
            return
        }

        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            self?.scheduledPersistenceTask = nil
            self?.persistSnapshotNow()
        }
    }

    private func persistSnapshot() {
        scheduledPersistenceTask?.cancel()
        scheduledPersistenceTask = nil
        persistSnapshotNow()
    }

    private func persistSnapshotNow() {
        guard !hasLocalLoadFailure else {
            StickyNotesLog.persistence.warning(
                "Snapshot persistence skipped after unrecoverable local load failure"
            )
            return
        }

        snapshotGeneration += 1
        let snapshotGeneration = snapshotGeneration
        let snapshot = StickyNotesSnapshot(
            notes: orderedStoredNotes,
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

    private var syncLocalState: StickyNotesSyncLocalState {
        StickyNotesSyncLocalState(
            notes: orderedStoredNotes,
            pendingDeletionIDs: pendingDeletionIDs
        )
    }

    private func applySyncLocalState(
        _ state: StickyNotesSyncLocalState,
        persistIfChanged: Bool
    ) {
        let sortedNotes = sortNotes(state.notes)
        let didChangeNotes = notes != sortedNotes
        let didChangePendingDeletions = pendingDeletionIDs != state.pendingDeletionIDs
        guard didChangeNotes || didChangePendingDeletions else { return }

        if didChangeNotes {
            replaceStoredNotes(with: sortedNotes, sort: false)
        }
        if didChangePendingDeletions {
            pendingDeletionIDs = state.pendingDeletionIDs
        }
        if persistIfChanged {
            persistSnapshot()
        }
    }

    func flushPendingPersistence() async {
        if scheduledPersistenceTask != nil {
            scheduledPersistenceTask?.cancel()
            scheduledPersistenceTask = nil
            persistSnapshotNow()
        }

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
