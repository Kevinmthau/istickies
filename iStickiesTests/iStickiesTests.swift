//
//  iStickiesTests.swift
//  iStickiesTests
//
//  Created by Kevin Thau on 5/15/25.
//

import Foundation
import Testing
@testable import iStickies
#if os(macOS)
import AppKit
#endif

@MainActor
struct iStickiesTests {
    @Test func syncDownloadsRemoteNotes() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Remote note",
            color: .mint,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: false,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let cloudService = MockCloudService(remoteNotes: [remoteNote])
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()

        #expect(store.notes.count == 1)
        #expect(store.notes.first?.id == remoteNote.id)
        #expect(store.notes.first?.content == "Remote note")
        #expect(store.notes.first?.needsCloudUpload == false)
    }

    @Test func localEditsPersistAndUpload() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let cloudService = MockCloudService()
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        let noteID = store.createNote()
        store.updateContent(id: noteID, content: "Local change")

        let snapshot = try await waitForSnapshot(in: fileStore) { snapshot in
            snapshot.notes.contains(where: { $0.id == noteID && $0.content == "Local change" })
        }
        let persistedNote = try #require(snapshot.notes.first(where: { $0.id == noteID }))
        #expect(persistedNote.content == "Local change")

        await store.syncNow()

        let remoteNotes = await cloudService.snapshot()
        let uploadedLocalChange = remoteNotes.contains(where: { note in
            note.id == noteID && note.content == "Local change"
        })
        #expect(uploadedLocalChange)
        #expect(store.note(withID: noteID)?.needsCloudUpload == false)
    }

    @Test func draftSessionPersistsLatestContentAfterDebounce() async throws {
        var persistedContent = "Original"
        let session = NoteDraftSession()

        session.configure(
            noteID: "note",
            initialContent: persistedContent,
            readPersistedContent: { persistedContent },
            persistDraftContent: { persistedContent = $0 }
        )

        session.updateDraftContent("First draft")
        session.updateDraftContent("Final draft")

        try await Task.sleep(for: .milliseconds(300))

        #expect(persistedContent == "Final draft")
    }

    @Test func switchingDraftSessionNotesFlushesPreviousDraft() {
        var persistedContentByID = [
            "first": "First note",
            "second": "Second note",
        ]
        let session = NoteDraftSession()

        session.configure(
            noteID: "first",
            initialContent: persistedContentByID["first"] ?? "",
            readPersistedContent: { persistedContentByID["first"] },
            persistDraftContent: { persistedContentByID["first"] = $0 }
        )
        session.updateDraftContent("Edited first note")

        session.configure(
            noteID: "second",
            initialContent: persistedContentByID["second"] ?? "",
            force: true,
            readPersistedContent: { persistedContentByID["second"] },
            persistDraftContent: { persistedContentByID["second"] = $0 }
        )

        #expect(persistedContentByID["first"] == "Edited first note")
        #expect(session.draftContent == "Second note")
    }

    @Test func draftSessionIgnoresPersistedChangesWhileLocalEditsArePending() {
        var persistedContent = "Original"
        let session = NoteDraftSession(debounceInterval: .seconds(10))

        session.configure(
            noteID: "note",
            initialContent: persistedContent,
            readPersistedContent: { persistedContent },
            persistDraftContent: { persistedContent = $0 }
        )

        session.updateDraftContent("Local edit")
        session.handlePersistedContentChange("Original")

        #expect(session.draftContent == "Local edit")
    }

    @Test func draftSessionAppliesPersistedChangesAfterLocalEditsFlush() {
        var persistedContent = "Original"
        let session = NoteDraftSession(debounceInterval: .seconds(10))

        session.configure(
            noteID: "note",
            initialContent: persistedContent,
            readPersistedContent: { persistedContent },
            persistDraftContent: { persistedContent = $0 }
        )

        session.updateDraftContent("Local edit")
        session.flush()
        session.handlePersistedContentChange("Remote edit")

        #expect(persistedContent == "Local edit")
        #expect(session.draftContent == "Remote edit")
    }

    @Test func flushPendingPersistenceKeepsAllCreatedNotesAcrossReload() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let store = StickyNotesStore(fileStore: fileStore, cloudService: MockCloudService(), autoLoad: false)

        await store.load()
        let noteIDs = [
            store.createNote(),
            store.createNote(),
            store.createNote(),
        ]

        await store.flushPendingPersistence()

        let reloadedSnapshot = try await StickyNotesFileStore(fileURL: fileURL).load()
        #expect(Set(reloadedSnapshot.notes.map(\.id)) == Set(noteIDs))
    }

    @Test func outOfOrderSnapshotWritesDoNotResurrectDeletedNotesOnReload() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let cloudService = MockCloudService(
            stateSerializationDelays: [.milliseconds(120), .zero]
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        let noteID = store.createNote()
        let deletedNote = try #require(store.note(withID: noteID))
        store.deleteNote(id: noteID)

        try await Task.sleep(for: .milliseconds(180))

        let reloadedCloudService = MockCloudService(remoteNotes: [deletedNote.markedClean()])
        let reloadedStore = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: fileURL),
            cloudService: reloadedCloudService,
            autoLoad: false
        )
        await reloadedStore.load()
        await reloadedStore.syncNow()
        let remoteNotes = await reloadedCloudService.snapshot()

        #expect(reloadedStore.notes.isEmpty)
        #expect(remoteNotes.isEmpty)
    }

    @Test func outOfOrderSnapshotWritesPreserveAllNotes() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let cloudService = MockCloudService(
            stateSerializationDelays: [.milliseconds(120), .zero]
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        let firstNoteID = store.createNote()
        let secondNoteID = store.createNote()

        try await Task.sleep(for: .milliseconds(180))

        let snapshot = try await fileStore.load()
        #expect(Set(snapshot.notes.map(\.id)) == Set([firstNoteID, secondNoteID]))
    }

    @Test func newerRemoteVersionCreatesConflictCopy() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let sharedID = "shared-note"
        let localNote = StickyNote(
            id: sharedID,
            content: "Local draft",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 100),
            lastModified: Date(timeIntervalSince1970: 120),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [localNote]))

        let remoteNote = StickyNote(
            id: sharedID,
            content: "Remote edit",
            color: .blue,
            createdAt: Date(timeIntervalSince1970: 100),
            lastModified: Date(timeIntervalSince1970: 180),
            isOpen: false,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let cloudService = MockCloudService(remoteNotes: [remoteNote])
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()

        #expect(store.notes.count == 2)
        let hasRemoteWinner = store.notes.contains(where: { note in
            note.id == sharedID && note.content == "Remote edit" && note.needsCloudUpload == false
        })
        #expect(hasRemoteWinner)

        let hasConflictCopy = store.notes.contains(where: { note in
            note.id != sharedID && note.title == "Conflict Copy" && note.content == "Local draft"
        })
        #expect(hasConflictCopy)
    }

    @Test func mergeEnginePreservesWindowStateWhenRemoteVersionWins() {
        let localFrame = StickyNoteFrame(x: 80, y: 120, width: 320, height: 280)
        let localNote = StickyNote(
            id: "shared-note",
            content: "Local",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: localFrame,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let remoteNote = StickyNote(
            id: "shared-note",
            content: "Remote",
            color: .blue,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 40),
            isOpen: false,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )

        let outcome = StickyNotesMergeEngine.merge(
            localNotes: [localNote],
            remoteNotes: [remoteNote],
            pendingDeletionIDs: []
        )
        let mergedNote = try! #require(outcome.notes.first)

        #expect(outcome.notes.count == 1)
        #expect(mergedNote.content == "Remote")
        #expect(mergedNote.color == .blue)
        #expect(mergedNote.isOpen)
        #expect(mergedNote.preferredFrame == localFrame)
        #expect(mergedNote.needsCloudUpload == false)
    }

    @Test func stickyTextSyncDefersProgrammaticUpdatesWhileEditorIsActive() {
        let shouldApply = StickyTextEditorSync.shouldApplyProgrammaticUpdate(
            currentText: "Local draft",
            incomingText: "Remote edit",
            isEditorActive: true,
            hasMarkedText: false
        )

        #expect(shouldApply == false)
    }

    @Test func stickyTextSyncAllowsProgrammaticUpdatesWhileEditorIsIdle() {
        let shouldApply = StickyTextEditorSync.shouldApplyProgrammaticUpdate(
            currentText: "Local draft",
            incomingText: "Remote edit",
            isEditorActive: false,
            hasMarkedText: false
        )

        #expect(shouldApply == true)
    }

    @Test func stickyTextSyncDefersProgrammaticUpdatesWhileMarkedTextExists() {
        let shouldApply = StickyTextEditorSync.shouldApplyProgrammaticUpdate(
            currentText: "Local draft",
            incomingText: "Remote edit",
            isEditorActive: false,
            hasMarkedText: true
        )

        #expect(shouldApply == false)
    }

    @Test func stickyTextSyncIgnoresMatchingProgrammaticUpdates() {
        let shouldApply = StickyTextEditorSync.shouldApplyProgrammaticUpdate(
            currentText: "Local draft",
            incomingText: "Local draft",
            isEditorActive: false,
            hasMarkedText: false
        )

        #expect(shouldApply == false)
    }

    @Test func stickyTextSyncClampsSelectionToUpdatedContentLength() {
        let clampedSelection = StickyTextEditorSync.clampedSelection(
            NSRange(location: 12, length: 4),
            utf16Count: 5
        )

        #expect(clampedSelection.location == 5)
        #expect(clampedSelection.length == 0)
    }

#if os(macOS)
    @Test func recentLocalFrameDoesNotGetReappliedToDraggingWindow() {
        let currentFrame = NSRect(x: 280, y: 360, width: 280, height: 280)
        let shouldApply = StickyNoteWindowFrameSync.shouldApplyModelFrame(
            currentFrame: currentFrame,
            targetFrame: NSRect(x: 120, y: 360, width: 280, height: 280),
            lastLocalFrameReportDate: Date(),
            forceFrame: false,
            now: Date()
        )

        #expect(shouldApply == false)
    }

    @Test func recentLocalFrameDefersAnyCompetingModelFrame() {
        let currentFrame = NSRect(x: 280, y: 360, width: 280, height: 280)
        let shouldApply = StickyNoteWindowFrameSync.shouldApplyModelFrame(
            currentFrame: currentFrame,
            targetFrame: NSRect(x: 520, y: 360, width: 280, height: 280),
            lastLocalFrameReportDate: Date(),
            forceFrame: false,
            now: Date()
        )

        #expect(shouldApply == false)
    }

    @Test func activeLocalMoveKeepsCompetingModelFrameDeferred() {
        let currentFrame = NSRect(x: 280, y: 360, width: 280, height: 280)
        let now = Date()
        let shouldApply = StickyNoteWindowFrameSync.shouldApplyModelFrame(
            currentFrame: currentFrame,
            targetFrame: NSRect(x: 520, y: 360, width: 280, height: 280),
            lastLocalFrameReportDate: now.addingTimeInterval(-2),
            isLocalMoveActive: true,
            forceFrame: false,
            now: now
        )

        #expect(shouldApply == false)
    }

    @Test func oldLocalFrameCanBeAppliedAgainLater() {
        let currentFrame = NSRect(x: 280, y: 360, width: 280, height: 280)
        let now = Date()
        let shouldApply = StickyNoteWindowFrameSync.shouldApplyModelFrame(
            currentFrame: currentFrame,
            targetFrame: NSRect(x: 120, y: 360, width: 280, height: 280),
            lastLocalFrameReportDate: now.addingTimeInterval(-1),
            forceFrame: false,
            now: now
        )

        #expect(shouldApply)
    }

    @Test func suppressionDelayExpiresAfterWindowSettles() {
        let now = Date()
        let suppressionDelay = StickyNoteWindowFrameSync.suppressionDelay(
            lastLocalFrameReportDate: now.addingTimeInterval(-0.2),
            now: now
        )

        let delay = try! #require(suppressionDelay)
        #expect(delay > 0)
        #expect(delay < StickyNoteWindowFrameSync.staleLocalFrameSuppressionInterval)
        #expect(
            StickyNoteWindowFrameSync.suppressionDelay(
                lastLocalFrameReportDate: now.addingTimeInterval(-1),
                now: now
            ) == nil
        )
    }
#endif
}

private actor MockCloudService: StickyNotesCloudSyncing {
    private var remoteNotesByID: [String: StickyNote]
    private var deletedIDs: [String] = []
    private let stateSerializationDelays: [Duration]
    private var stateSerializationCallCount = 0

    init(remoteNotes: [StickyNote] = [], stateSerializationDelays: [Duration] = []) {
        remoteNotesByID = Dictionary(uniqueKeysWithValues: remoteNotes.map { ($0.id, $0.markedClean()) })
        self.stateSerializationDelays = stateSerializationDelays
    }

    func fetchAllNotes() async throws -> [StickyNote] {
        Array(remoteNotesByID.values)
    }

    func restore(stateSerializationData: Data?) async {}

    func currentStateSerializationData() async -> Data? {
        let currentCall = stateSerializationCallCount
        stateSerializationCallCount += 1

        if currentCall < stateSerializationDelays.count {
            try? await Task.sleep(for: stateSerializationDelays[currentCall])
        }

        return nil
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        var result = CloudSyncBatchResult()

        for note in saves {
            let cleanNote = note.markedClean()
            remoteNotesByID[note.id] = cleanNote
            result.savedNotes.append(cleanNote)
        }

        for id in deletions {
            remoteNotesByID.removeValue(forKey: id)
            deletedIDs.append(id)
            result.deletedNoteIDs.append(id)
        }

        return result
    }

    func snapshot() -> [StickyNote] {
        Array(remoteNotesByID.values)
    }
}

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("sticky-notes.json", isDirectory: false)
}

private func waitForSnapshot(
    in fileStore: StickyNotesFileStore,
    predicate: @escaping (StickyNotesSnapshot) -> Bool
) async throws -> StickyNotesSnapshot {
    for _ in 0..<20 {
        let snapshot = try await fileStore.load()
        if predicate(snapshot) {
            return snapshot
        }

        try await Task.sleep(for: .milliseconds(25))
    }

    throw SnapshotTimeoutError()
}

private struct SnapshotTimeoutError: Error {}
