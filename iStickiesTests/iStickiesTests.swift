//
//  iStickiesTests.swift
//  iStickiesTests
//
//  Created by Kevin Thau on 5/15/25.
//

import CloudKit
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
        #expect(store.notes.first?.color == .yellow)
        #expect(store.notes.first?.needsCloudUpload == false)

        let normalizedRemoteNotes = await cloudService.snapshot()
        #expect(normalizedRemoteNotes.first?.color == .yellow)
    }

    @Test func loadNormalizesSavedNotesToYellow() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let storedNote = StickyNote(
            id: "stored-note",
            content: "Saved note",
            color: .blue,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [storedNote],
                pendingDeletionIDs: [],
                lastSuccessfulCloudSync: nil,
                cloudKitStateSerializationData: Data([1])
            )
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: MockCloudService(), autoLoad: false)

        await store.load()

        #expect(store.notes.count == 1)
        #expect(store.notes.first?.color == .yellow)
        #expect(store.notes.first?.needsCloudUpload == true)
    }

    @Test func cloudKitRecordWithoutColorDefaultsToYellow() throws {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let record = CKRecord(recordType: StickyNote.recordType, recordID: recordID)
        record["content"] = "Remote note" as CKRecordValue
        record["createdAt"] = Date(timeIntervalSince1970: 10) as CKRecordValue
        record["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue

        let note = try #require(StickyNote(record: record))

        #expect(note.id == "remote-note")
        #expect(note.content == "Remote note")
        #expect(note.color == .yellow)
        #expect(note.isOpen)
    }

    @Test func cloudKitRecordWithoutCreatedAtFallsBackToLastModified() throws {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let record = CKRecord(recordType: StickyNote.recordType, recordID: recordID)
        let lastModified = Date(timeIntervalSince1970: 20)
        record["content"] = "Remote note" as CKRecordValue
        record["lastModified"] = lastModified as CKRecordValue

        let note = try #require(StickyNote(record: record))

        #expect(note.id == "remote-note")
        #expect(note.createdAt == lastModified)
        #expect(note.lastModified == lastModified)
    }

    @Test func cloudKitRecordWriteOmitsColorFieldFromRestoredRecords() {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let archivedRecord = CKRecord(recordType: StickyNote.recordType, recordID: recordID)
        archivedRecord["content"] = "Original" as CKRecordValue
        archivedRecord["color"] = StickyNoteColor.blue.rawValue as CKRecordValue
        archivedRecord["createdAt"] = Date(timeIntervalSince1970: 10) as CKRecordValue
        archivedRecord["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archivedRecord.encodeSystemFields(with: archiver)
        archiver.finishEncoding()

        let note = StickyNote(
            id: "remote-note",
            content: "Updated",
            color: .orange,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 30),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: archiver.encodedData
        )

        let record = note.makeRecord(zoneID: .default)
        let color = record["color"] as? String

        #expect(color == nil)
        #expect(record.allKeys().contains("color") == false)
        #expect(record["content"] as? String == "Updated")
    }

    @Test func cloudKitRecordWriteOmitsCreatedAtFieldFromRestoredRecords() {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let archivedRecord = CKRecord(recordType: StickyNote.recordType, recordID: recordID)
        archivedRecord["content"] = "Original" as CKRecordValue
        archivedRecord["createdAt"] = Date(timeIntervalSince1970: 10) as CKRecordValue
        archivedRecord["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archivedRecord.encodeSystemFields(with: archiver)
        archiver.finishEncoding()

        let note = StickyNote(
            id: "remote-note",
            content: "Updated",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 30),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: archiver.encodedData
        )

        let record = note.makeRecord(zoneID: .default)
        let createdAt = record["createdAt"] as? Date

        #expect(createdAt == nil)
        #expect(record.allKeys().contains("createdAt") == false)
        #expect(record["content"] as? String == "Updated")
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

    @Test func mergeLoadedNotesPreservesDirtyLocalState() {
        let restoredNote = StickyNote(
            id: "restored-note",
            content: "Stored note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: false,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([1])
        )
        let localUnsyncedNote = StickyNote(
            id: "local-note",
            content: "Local draft",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 40),
            lastModified: Date(timeIntervalSince1970: 50),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: nil
        )
        let mergedNotes = StickyNotesMergeEngine.mergeLoadedNotes(
            currentNotes: [localUnsyncedNote],
            loadedNotes: [restoredNote]
        )

        #expect(mergedNotes.contains(where: { $0.id == restoredNote.id }))
        #expect(mergedNotes.contains(where: { $0.id == localUnsyncedNote.id }))
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

    @Test func syncApplyPreservesLocalEditsMadeAfterSaveWasSent() {
        let originalSystemFields = Data([1])
        let refreshedSystemFields = Data([2])
        let sentNote = StickyNote(
            id: "shared-note",
            content: "First draft",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: StickyNoteFrame(x: 40, y: 60, width: 280, height: 280),
            needsCloudUpload: true,
            cloudKitSystemFieldsData: originalSystemFields
        )
        let newerLocalNote = StickyNote(
            id: "shared-note",
            content: "Second draft",
            color: .yellow,
            createdAt: sentNote.createdAt,
            lastModified: Date(timeIntervalSince1970: 30),
            isOpen: false,
            preferredFrame: StickyNoteFrame(x: 90, y: 120, width: 320, height: 300),
            needsCloudUpload: true,
            cloudKitSystemFieldsData: originalSystemFields
        )
        let savedNote = StickyNote(
            id: "shared-note",
            content: "First draft",
            color: .yellow,
            createdAt: sentNote.createdAt,
            lastModified: sentNote.lastModified,
            isOpen: true,
            preferredFrame: sentNote.preferredFrame,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: refreshedSystemFields
        )

        let outcome = StickyNotesMergeEngine.apply(
            syncResult: CloudSyncBatchResult(savedNotes: [savedNote]),
            to: [newerLocalNote],
            pendingDeletionIDs: [],
            sentNotesByID: [sentNote.id: sentNote]
        )
        let preservedNote = try! #require(outcome.notes.first)

        #expect(preservedNote.content == "Second draft")
        #expect(preservedNote.lastModified == newerLocalNote.lastModified)
        #expect(preservedNote.isOpen == false)
        #expect(preservedNote.preferredFrame == newerLocalNote.preferredFrame)
        #expect(preservedNote.needsCloudUpload)
        #expect(preservedNote.cloudKitSystemFieldsData == refreshedSystemFields)
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

    @Test func stickyTextLayoutCentersShortContentWithinAvailableHeight() {
        let verticalInset = StickyTextEditorLayout.centeredVerticalInset(
            availableHeight: 400,
            contentHeight: 28,
            minimumVerticalInset: 18
        )

        #expect(verticalInset == 186)
    }

    @Test func stickyTextLayoutFallsBackToMinimumInsetForTallContent() {
        let verticalInset = StickyTextEditorLayout.centeredVerticalInset(
            availableHeight: 140,
            contentHeight: 120,
            minimumVerticalInset: 18
        )

        #expect(verticalInset == 18)
    }

    @Test func stickyNoteCardLayoutMatchesDashboardGridWidth() {
        let cardWidth = StickyNoteCardLayout.cardWidth(for: 390)

        #expect(cardWidth == 171)
    }

    @Test func stickyNoteDisplayOrderTracksLatestIDsWhenNotEditing() {
        let orderedIDs = StickyNoteDisplayOrder.reconciledIDs(
            currentIDs: ["note-c", "note-a"],
            latestIDs: ["note-a", "note-b", "note-c"],
            preserveCurrentOrder: false
        )

        #expect(orderedIDs == ["note-a", "note-b", "note-c"])
    }

    @Test func stickyNoteDisplayOrderPreservesVisibleOrderWhileEditing() {
        let orderedIDs = StickyNoteDisplayOrder.reconciledIDs(
            currentIDs: ["note-c", "note-a"],
            latestIDs: ["note-a", "note-b", "note-c"],
            preserveCurrentOrder: true
        )

        #expect(orderedIDs == ["note-c", "note-a", "note-b"])
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
