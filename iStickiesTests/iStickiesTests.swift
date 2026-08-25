//
//  iStickiesTests.swift
//  iStickiesTests
//
//  Created by Kevin Thau on 5/15/25.
//

import CloudKit
import Combine
import CoreGraphics
import Foundation
import Testing
@testable import iStickies
#if os(macOS)
import AppKit
#endif

@MainActor
struct iStickiesTests {
    @Test func keyboardEndFrameCoversSceneOnlyWhenIntersectingScene() {
        let sceneFrame = CGRect(x: 0, y: 0, width: 390, height: 844)

        #expect(StickyNotesKeyboardFrame.coversScene(
            endFrame: CGRect(x: 0, y: 510, width: 390, height: 334),
            sceneFrame: sceneFrame
        ))
        #expect(!StickyNotesKeyboardFrame.coversScene(
            endFrame: CGRect(x: 0, y: 844, width: 390, height: 334),
            sceneFrame: sceneFrame
        ))
        #expect(!StickyNotesKeyboardFrame.coversScene(
            endFrame: .zero,
            sceneFrame: sceneFrame
        ))
    }

    @Test func keyboardScreenFrameIsConvertedBeforeSceneIntersection() {
        let sceneFrame = CGRect(x: 0, y: 0, width: 700, height: 600)
        let screenEndFrame = CGRect(x: 120, y: 640, width: 700, height: 260)

        #expect(!StickyNotesKeyboardFrame.coversScene(
            endFrame: screenEndFrame,
            sceneFrame: sceneFrame
        ))
        #expect(StickyNotesKeyboardFrame.coversScene(
            screenEndFrame: screenEndFrame,
            sceneFrame: sceneFrame,
            convertScreenFrameToScene: { $0.offsetBy(dx: -120, dy: -160) }
        ))
    }

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

    @Test func successfulSyncPersistsRemoteCacheForColdLaunchRestore() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Remote note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "server-revision"
        )
        let cloudService = MockCloudService(remoteNotes: [remoteNote])
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()
        await store.flushPendingPersistence()

        let persistedSnapshot = try await StickyNotesFileStore(fileURL: fileURL).load()
        #expect(persistedSnapshot.cloudRemoteCache.map(\.id) == [remoteNote.id])
        #expect(persistedSnapshot.cloudRemoteCache.first?.cloudRevision == "server-revision")
    }

    @Test func syncCoordinatorReturnsMergedStateTransition() async throws {
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Remote note",
            color: .mint,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let coordinator = StickyNotesSyncCoordinator(
            cloudService: MockCloudService(remoteNotes: [remoteNote])
        )

        let remoteSnapshot = try await coordinator.fetchRemoteSnapshot()
        let transition = coordinator.merge(
            remoteSnapshot: remoteSnapshot,
            localState: StickyNotesSyncLocalState(notes: [], pendingDeletionIDs: [])
        )
        let mergedNote = try #require(transition.state.notes.first)

        #expect(transition.remoteSnapshotCompleteness == .complete)
        #expect(mergedNote.id == remoteNote.id)
        #expect(mergedNote.color == .yellow)
        #expect(mergedNote.needsCloudUpload)
    }

    @Test func syncCoordinatorAppliesBatchResultToLatestLocalState() async throws {
        let sentNote = StickyNote(
            id: "shared-note",
            content: "First draft",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: nil
        )
        var editedAfterSend = sentNote
        editedAfterSend.content = "Second draft"
        editedAfterSend.lastModified = Date(timeIntervalSince1970: 30)

        let coordinator = StickyNotesSyncCoordinator(cloudService: MockCloudService())
        let outgoingChanges = coordinator.outgoingChanges(
            from: StickyNotesSyncLocalState(notes: [sentNote], pendingDeletionIDs: [])
        )
        let syncResult = await coordinator.send(outgoingChanges)
        let transition = coordinator.apply(
            syncResult: syncResult,
            to: StickyNotesSyncLocalState(notes: [editedAfterSend], pendingDeletionIDs: []),
            sentNotesByID: outgoingChanges.savesByID
        )
        let preservedNote = try #require(transition.state.notes.first)

        #expect(preservedNote.content == "Second draft")
        #expect(preservedNote.lastModified == editedAfterSend.lastModified)
        #expect(preservedNote.needsCloudUpload)
    }

    @Test func syncCoordinatorDropsRemoteCacheAfterPartialSnapshot() async throws {
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Remote note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let coordinator = StickyNotesSyncCoordinator(
            cloudService: MockCloudService(remoteNotes: [remoteNote])
        )

        let persistedState = await coordinator.currentPersistedState(after: .partial("Partial fetch"))

        #expect(persistedState.remoteNotes.isEmpty)
    }

    @Test func localEditMadeWhileRemoteFetchIsPendingSurvivesSync() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let cloudService = MockCloudService(fetchDelay: .milliseconds(80))
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        let noteID = store.createNote()

        let syncTask = Task {
            await store.syncNow()
        }
        try await Task.sleep(for: .milliseconds(20))
        store.updateContent(id: noteID, content: "Edited while fetching")

        await syncTask.value

        let localNote = try #require(store.note(withID: noteID))
        #expect(localNote.content == "Edited while fetching")

        let remoteNotes = await cloudService.snapshot()
        #expect(remoteNotes.contains { note in
            note.id == noteID && note.content == "Edited while fetching"
        })
    }

    @Test func explicitBlockedUploadRetryQueuedDuringActiveSyncRunsNext() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let blockedNote = StickyNote(
            id: "blocked-note",
            content: "Retry me",
            needsCloudUpload: true,
            cloudUploadBlock: .permanentlyRejected
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [blockedNote]))

        let cloudService = MockCloudService(fetchDelay: .milliseconds(100))
        let store = StickyNotesStore(
            fileStore: fileStore,
            cloudService: cloudService,
            delayedTaskScheduler: TestDelayedTaskScheduler(),
            autoLoad: false
        )
        await store.load()

        let activeSync = Task { await store.syncNow() }
        var didEnterFirstFetch = false
        for _ in 0..<1_000 {
            if await cloudService.fetchCount() == 1 {
                didEnterFirstFetch = true
                break
            }
            await Task.yield()
        }
        #expect(didEnterFirstFetch)

        await store.syncNow(retryingBlockedUploads: true)
        await activeSync.value

        let uploadedNote = try #require(store.note(withID: blockedNote.id))
        #expect(await cloudService.fetchCount() == 2)
        #expect(uploadedNote.needsCloudUpload == false)
        #expect(uploadedNote.cloudUploadBlock == nil)
        #expect(await cloudService.snapshot().contains { $0.id == blockedNote.id })
    }

    @Test func ordinarySyncQueuedDuringFailedPassUploadsNewerEdit() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let originalNote = StickyNote(
            id: "edited-during-send",
            content: "First draft",
            needsCloudUpload: true
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [originalNote]))

        let cloudService = FailingFirstSendCloudService(firstSendDelay: .milliseconds(100))
        let store = StickyNotesStore(
            fileStore: fileStore,
            cloudService: cloudService,
            delayedTaskScheduler: TestDelayedTaskScheduler(),
            autoLoad: false
        )
        await store.load()

        let activeSync = Task { await store.syncNow() }
        var didEnterFirstSend = false
        for _ in 0..<1_000 {
            if await cloudService.sendCount() == 1 {
                didEnterFirstSend = true
                break
            }
            await Task.yield()
        }
        #expect(didEnterFirstSend)

        store.updateContent(id: originalNote.id, content: "Second draft")
        await store.syncNow()
        await activeSync.value

        let uploadedNote = try #require(store.note(withID: originalNote.id))
        #expect(await cloudService.sendCount() == 2)
        #expect(uploadedNote.content == "Second draft")
        #expect(uploadedNote.needsCloudUpload == false)
        #expect(await cloudService.snapshot().first?.content == "Second draft")
    }

    @Test func unavailableCloudSnapshotDoesNotDeleteCleanLocalNotes() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let previousSyncDate = Date(timeIntervalSince1970: 30)
        let localNote = StickyNote(
            id: "local-note",
            content: "Clean local note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [localNote],
                pendingDeletionIDs: [],
                lastSuccessfulCloudSync: previousSyncDate,
                cloudKitStateSerializationData: Data([1])
            )
        )
        let store = StickyNotesStore(
            fileStore: fileStore,
            cloudService: DisabledStickyNotesCloudService(),
            autoLoad: false
        )

        await store.load()
        await store.syncNow()

        let preservedNote = try #require(store.note(withID: localNote.id))
        #expect(preservedNote.content == localNote.content)
        #expect(preservedNote.needsCloudUpload == false)
        #expect(store.lastSuccessfulCloudSync == previousSyncDate)
    }

    @Test func unavailableCloudSnapshotDoesNotUploadPendingDeletion() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Remote note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [],
                pendingDeletionIDs: [remoteNote.id],
                lastSuccessfulCloudSync: Date(timeIntervalSince1970: 30),
                cloudKitStateSerializationData: Data([1])
            )
        )
        let cloudService = MockCloudService(
            remoteNotes: [remoteNote],
            remoteSnapshotCompleteness: .unavailable("CloudKit fetch failed.")
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()

        let remoteNotes = await cloudService.snapshot()
        #expect(remoteNotes.contains(where: { $0.id == remoteNote.id }))
        #expect(store.syncState == .failed("CloudKit fetch failed."))
    }

    @Test func unavailableCloudSnapshotMergesKnownRemoteNotesBeforeSuppressingUploads() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let previousSyncDate = Date(timeIntervalSince1970: 30)
        let pendingLocalNote = StickyNote(
            id: "pending-local-note",
            content: "Pending local note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: nil
        )
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Known remote note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 40),
            lastModified: Date(timeIntervalSince1970: 50),
            isOpen: false,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [pendingLocalNote],
                pendingDeletionIDs: [],
                lastSuccessfulCloudSync: previousSyncDate,
                cloudKitStateSerializationData: Data([1])
            )
        )
        let cloudService = MockCloudService(
            remoteNotes: [remoteNote],
            remoteSnapshotCompleteness: .unavailable("CloudKit fetch failed.")
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()

        let mergedRemoteNote = try #require(store.note(withID: remoteNote.id))
        #expect(mergedRemoteNote.content == remoteNote.content)
        #expect(mergedRemoteNote.needsCloudUpload == false)
        #expect(store.note(withID: pendingLocalNote.id)?.needsCloudUpload == true)
        let remoteNotes = await cloudService.snapshot()
        #expect(remoteNotes.contains(where: { $0.id == remoteNote.id }))
        #expect(!remoteNotes.contains(where: { $0.id == pendingLocalNote.id }))
        #expect(store.syncState == .failed("CloudKit fetch failed."))
        #expect(store.lastSuccessfulCloudSync == previousSyncDate)
    }

    @Test func corruptCloudKitStateSerializationIsDiscardedWithoutDroppingLocalState() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let previousSyncDate = Date(timeIntervalSince1970: 30)
        let pendingDeleteID = "pending-delete"
        let localNote = StickyNote(
            id: "local-note",
            content: "Clean local note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [localNote],
                pendingDeletionIDs: [pendingDeleteID],
                lastSuccessfulCloudSync: previousSyncDate,
                cloudKitStateSerializationData: Data("not valid CKSyncEngine state".utf8)
            )
        )
        let cloudService = MockCloudService(
            remoteSnapshotCompleteness: .unavailable("CloudKit fetch failed.")
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()
        await store.flushPendingPersistence()

        let preservedNote = try #require(store.note(withID: localNote.id))
        #expect(preservedNote.content == localNote.content)
        #expect(store.lastSuccessfulCloudSync == previousSyncDate)

        let persistedSnapshot = try await fileStore.load()
        #expect(persistedSnapshot.notes.contains(where: { $0.id == localNote.id }))
        #expect(persistedSnapshot.pendingDeletionIDs == [pendingDeleteID])
        #expect(persistedSnapshot.cloudKitStateSerializationData == nil)
    }

    @Test func partialRemoteSnapshotDoesNotDeleteCleanLocalNotes() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let previousSyncDate = Date(timeIntervalSince1970: 30)
        let localNote = StickyNote(
            id: "local-note",
            content: "Clean local note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [localNote],
                pendingDeletionIDs: [],
                lastSuccessfulCloudSync: previousSyncDate,
                cloudKitStateSerializationData: Data([1])
            )
        )
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Remote note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 40),
            lastModified: Date(timeIntervalSince1970: 50),
            isOpen: false,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let cloudService = MockCloudService(
            remoteNotes: [remoteNote],
            remoteSnapshotCompleteness: .partial("A CloudKit record could not be fetched.")
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()

        #expect(store.note(withID: localNote.id)?.content == localNote.content)
        #expect(store.note(withID: remoteNote.id)?.content == remoteNote.content)
        #expect(store.lastSuccessfulCloudSync == previousSyncDate)
    }

    @Test func partialRemoteSnapshotDoesNotPersistRemoteCacheForColdLaunchRestore() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let localNote = StickyNote(
            id: "local-note",
            content: "Clean local note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let remoteNote = StickyNote(
            id: "remote-note",
            content: "Partially fetched remote note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 40),
            lastModified: Date(timeIntervalSince1970: 50),
            isOpen: false,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [localNote],
                pendingDeletionIDs: [],
                lastSuccessfulCloudSync: Date(timeIntervalSince1970: 30),
                cloudKitStateSerializationData: Data([1])
            )
        )
        let cloudService = MockCloudService(
            remoteNotes: [remoteNote],
            remoteSnapshotCompleteness: .partial("A CloudKit record could not be fetched."),
            currentStateSerializationData: Data([2])
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()
        await store.flushPendingPersistence()

        let persistedSnapshot = try await StickyNotesFileStore(fileURL: fileURL).load()
        #expect(persistedSnapshot.cloudKitStateSerializationData == Data([2]))
        #expect(persistedSnapshot.cloudRemoteCache.isEmpty)
    }

    @Test func remoteSnapshotCompletenessUsesStableObservabilityNames() {
        #expect(CloudRemoteSnapshotCompleteness.complete.observabilityName == "complete")
        #expect(CloudRemoteSnapshotCompleteness.partial("partial").observabilityName == "partial")
        #expect(CloudRemoteSnapshotCompleteness.unavailable("unavailable").observabilityName == "unavailable")
        #expect(CloudRemoteSnapshotCompleteness.remoteReset("reset").observabilityName == "remoteReset")
    }

    @Test func cloudKitRemoteNoteCacheStoresOnlyCleanNotes() throws {
        let dirtyRemoteNote = StickyNote(
            id: "remote-note",
            content: "Remote content",
            needsCloudUpload: true,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "server-revision"
        )
        let cache = CloudKitRemoteNoteCache(notes: [dirtyRemoteNote])

        let cachedNote = try #require(cache.note(withID: dirtyRemoteNote.id))
        let snapshotNote = try #require(cache.snapshot(completeness: .partial("Partial fetch")).notes.first)

        #expect(cachedNote.needsCloudUpload == false)
        #expect(cachedNote.cloudKitSystemFieldsData == Data([1]))
        #expect(cachedNote.cloudRevision == "server-revision")
        #expect(snapshotNote.needsCloudUpload == false)
        #expect(cache.snapshot(completeness: .partial("Partial fetch")).completeness == .partial("Partial fetch"))
    }

    @Test func cloudKitRemoteNoteCacheReplacesUpsertsAndRemovesByID() throws {
        let firstNote = StickyNote(id: "first-note", content: "First", needsCloudUpload: false)
        let secondNote = StickyNote(id: "second-note", content: "Second", needsCloudUpload: false)
        let editedFirstNote = StickyNote(id: "first-note", content: "Edited first", needsCloudUpload: true)
        var cache = CloudKitRemoteNoteCache(notes: [firstNote, secondNote])

        cache.upsert(editedFirstNote)
        cache.remove(noteID: secondNote.id)

        let cachedFirstNote = try #require(cache.note(withID: firstNote.id))
        #expect(cachedFirstNote.content == "Edited first")
        #expect(cachedFirstNote.needsCloudUpload == false)
        #expect(cache.note(withID: secondNote.id) == nil)
        #expect(cache.count == 1)

        cache.replaceAll(with: [secondNote])
        #expect(cache.note(withID: firstNote.id) == nil)
        #expect(cache.note(withID: secondNote.id)?.content == "Second")
    }

    @Test func sameAccountRemoteResetReuploadsCleanLocalNotes() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let previousSyncDate = Date(timeIntervalSince1970: 30)
        let localNote = StickyNote(
            id: "local-note",
            content: "Clean local note",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([9]),
            cloudRevision: "old-zone-revision"
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [localNote],
                pendingDeletionIDs: ["already-gone"],
                lastSuccessfulCloudSync: previousSyncDate,
                cloudKitStateSerializationData: Data([1]),
                cloudAccountIdentifier: "same-account"
            )
        )
        let cloudService = MockCloudService(
            remoteSnapshotCompleteness: .remoteReset("CloudKit zone was reset.")
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        await store.syncNow()
        await store.flushPendingPersistence()

        let uploadedNote = try #require(await cloudService.snapshot().first)
        #expect(uploadedNote.id == localNote.id)
        #expect(uploadedNote.content == localNote.content)
        #expect(store.note(withID: localNote.id)?.needsCloudUpload == false)

        let persistedSnapshot = try await StickyNotesFileStore(fileURL: fileURL).load()
        #expect(persistedSnapshot.pendingDeletionIDs.isEmpty)
        #expect(persistedSnapshot.lastSuccessfulCloudSync != previousSyncDate)
    }

    @Test func corruptPrimarySnapshotLoadsBackupAndQuarantinesPrimary() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let note = StickyNote(id: "backup-note", content: "Recovered from backup", needsCloudUpload: false)
        try await fileStore.save(StickyNotesSnapshot(notes: [note]))
        try Data("not json".utf8).write(to: fileURL, options: .atomic)

        let loadedSnapshot = try await StickyNotesFileStore(fileURL: fileURL).load()

        #expect(loadedSnapshot.notes.map(\.id) == [note.id])
        let parentURL = fileURL.deletingLastPathComponent()
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
        #expect(siblingNames.contains { $0.hasPrefix("sticky-notes.json.corrupt-") })
    }

    @Test func primarySnapshotMissingNotesLoadsBackupAndQuarantinesPrimary() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let note = StickyNote(id: "backup-note", content: "Recovered from backup", needsCloudUpload: false)
        try await fileStore.save(StickyNotesSnapshot(notes: [note]))
        try Data("{}".utf8).write(to: fileURL, options: .atomic)

        let loadedSnapshot = try await StickyNotesFileStore(fileURL: fileURL).load()

        #expect(loadedSnapshot.notes.map(\.id) == [note.id])
        let parentURL = fileURL.deletingLastPathComponent()
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: parentURL.path)
        #expect(siblingNames.contains { $0.hasPrefix("sticky-notes.json.corrupt-") })
    }

    @Test func unrecoverableLocalSnapshotBlocksEmptySyncAndPersistence() async throws {
        let fileURL = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("not json".utf8).write(to: fileURL, options: .atomic)
        let cloudService = MockCloudService()
        let store = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: fileURL),
            cloudService: cloudService,
            autoLoad: false
        )

        await store.load()
        store.createNote()
        await store.syncNow()
        await store.flushPendingPersistence()

        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
        let remoteNotes = await cloudService.snapshot()
        #expect(remoteNotes.isEmpty)
        guard case .failed = store.syncState else {
            Issue.record("Expected failed sync state after unrecoverable local load")
            return
        }
    }

    @Test func unrecoverableLocalSnapshotPublishesRecoveryIssue() async throws {
        let fileURL = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("not json".utf8).write(to: fileURL, options: .atomic)
        let store = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: fileURL),
            cloudService: MockCloudService(),
            autoLoad: false
        )
        let statusObservation = store.syncStatusObservation()

        await store.load()

        #expect(store.localRecoveryIssue?.title == "Notes Need Recovery")
        #expect(statusObservation.localRecoveryIssue?.title == "Notes Need Recovery")
        #expect(statusObservation.lastErrorMessage?.hasPrefix("Failed to restore notes locally:") == true)
    }

    @Test func startFreshAfterLocalSnapshotFailurePersistsNewSnapshot() async throws {
        let fileURL = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try Data("not json".utf8).write(to: fileURL, options: .atomic)
        let cloudService = MockCloudService()
        let store = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: fileURL),
            cloudService: cloudService,
            autoLoad: false
        )

        await store.load()
        await store.startFreshAfterLocalSnapshotFailure()
        let noteID = store.createNote()
        await store.flushPendingPersistence()

        #expect(store.localRecoveryIssue == nil)
        #expect(store.syncState == .idle)
        let loadedSnapshot = try await StickyNotesFileStore(fileURL: fileURL).load()
        #expect(loadedSnapshot.notes.map(\.id) == [noteID])
        let remoteNotes = await cloudService.snapshot()
        #expect(remoteNotes.isEmpty)
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

    @Test func snapshotDecodesLegacyFilesWithoutNewCloudStateFields() throws {
        let legacyJSON = """
        {
          "notes" : [],
          "pendingDeletionIDs" : [],
          "lastSuccessfulCloudSync" : null,
          "cloudKitStateSerializationData" : null
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(
            StickyNotesSnapshot.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.cloudAccountIdentifier == nil)
        #expect(snapshot.cloudRemoteCache.isEmpty)
    }

    @Test func cloudKitRecordWithoutColorDefaultsToYellow() throws {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let record = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
        record["content"] = "Remote note" as CKRecordValue
        record["createdAt"] = Date(timeIntervalSince1970: 10) as CKRecordValue
        record["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue

        let note = try #require(StickyNoteRecordMapper.note(from: record))

        #expect(note.id == "remote-note")
        #expect(note.content == "Remote note")
        #expect(note.color == .yellow)
        #expect(note.isOpen)
    }

    @Test func cloudKitRecordWithoutCreatedAtFallsBackToLastModified() throws {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let record = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
        let lastModified = Date(timeIntervalSince1970: 20)
        record["content"] = "Remote note" as CKRecordValue
        record["lastModified"] = lastModified as CKRecordValue

        let note = try #require(StickyNoteRecordMapper.note(from: record))

        #expect(note.id == "remote-note")
        #expect(note.createdAt == lastModified)
        #expect(note.lastModified == lastModified)
    }

    @Test func malformedCloudKitRecordMakesMappedSnapshotPartial() throws {
        let validRecordID = CKRecord.ID(recordName: "valid-note", zoneID: .default)
        let validRecord = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: validRecordID)
        validRecord["content"] = "Remote note" as CKRecordValue
        validRecord["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue

        let malformedRecordID = CKRecord.ID(recordName: "malformed-note", zoneID: .default)
        let malformedRecord = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: malformedRecordID)
        malformedRecord["content"] = "Missing last modified" as CKRecordValue

        let mapping = StickyNoteRecordMapper.map(
            records: [validRecord, malformedRecord],
            expectedZoneID: .default
        )

        #expect(mapping.notesByID[validRecordID.recordName]?.content == "Remote note")
        #expect(mapping.notesByID[malformedRecordID.recordName] == nil)
        #expect(mapping.issueMessages == ["1 CloudKit record(s) could not be decoded."])
    }

    @Test func stickyNoteRecordMapperIgnoresUnexpectedTypesAndZones() throws {
        let expectedZoneID = CKRecordZone.ID(zoneName: "expected")
        let otherZoneID = CKRecordZone.ID(zoneName: "other")
        let validRecordID = CKRecord.ID(recordName: "valid-note", zoneID: expectedZoneID)
        let validRecord = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: validRecordID)
        validRecord["content"] = "Remote note" as CKRecordValue
        validRecord["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue

        let otherTypeRecord = CKRecord(
            recordType: "OtherRecord",
            recordID: CKRecord.ID(recordName: "other-type", zoneID: expectedZoneID)
        )
        otherTypeRecord["content"] = "Ignored" as CKRecordValue
        otherTypeRecord["lastModified"] = Date(timeIntervalSince1970: 30) as CKRecordValue

        let otherZoneRecord = CKRecord(
            recordType: StickyNoteRecordMapper.recordType,
            recordID: CKRecord.ID(recordName: "other-zone", zoneID: otherZoneID)
        )
        otherZoneRecord["content"] = "Ignored" as CKRecordValue
        otherZoneRecord["lastModified"] = Date(timeIntervalSince1970: 40) as CKRecordValue

        let mapping = StickyNoteRecordMapper.map(
            records: [validRecord, otherTypeRecord, otherZoneRecord],
            expectedZoneID: expectedZoneID
        )

        #expect(Array(mapping.notesByID.keys) == [validRecordID.recordName])
        #expect(mapping.issueMessages.isEmpty)
    }

    @Test func corruptCloudKitStateSerializationRecoversWithFreshEngineState() {
        let recovery = CloudKitSyncEngineStateRecovery.restore(
            from: Data("not valid CKSyncEngine state".utf8)
        )

        #expect(recovery.stateSerialization == nil)
        #expect(recovery.recoveredFromCorruptSerialization)
        #expect(recovery.hadPersistedSyncStateSerialization)
        #expect(recovery.restoredFromPersistedSyncState == false)
    }

    @Test func legacyDefaultZoneImportPolicySkipsWhenCorruptStateBytesExisted() {
        #expect(
            CloudKitLegacyDefaultZoneImportPolicy.shouldImport(
                hadPersistedSyncStateSerialization: true,
                didAttemptLegacyDefaultZoneImport: false
            ) == false
        )
        #expect(
            CloudKitLegacyDefaultZoneImportPolicy.shouldImport(
                hadPersistedSyncStateSerialization: false,
                didAttemptLegacyDefaultZoneImport: false
            )
        )
    }

    @Test func cloudKitPendingChangeFilterKeepsKnownCustomZoneSavesAndDeletes() {
        let targetZoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let otherZoneID = CKRecordZone.ID(zoneName: "Other")
        let saveRecordID = CKRecord.ID(recordName: "save-note", zoneID: targetZoneID)
        let deleteRecordID = CKRecord.ID(recordName: "delete-note", zoneID: targetZoneID)
        let otherZoneRecordID = CKRecord.ID(recordName: "other-zone-note", zoneID: otherZoneID)

        let result = CloudKitPendingRecordZoneChangeFilter.customZoneChanges(
            from: [
                .saveRecord(saveRecordID),
                .deleteRecord(deleteRecordID),
                .saveRecord(otherZoneRecordID),
            ],
            targetZoneID: targetZoneID,
            shouldInclude: { _ in true }
        )

        let includedRecordNames = result.changes.compactMap {
            CloudKitPendingRecordZoneChangeFilter.recordID(for: $0)?.recordName
        }
        #expect(includedRecordNames == ["save-note", "delete-note"])
        #expect(result.skippedUnsupportedCount == 0)
    }

    @Test func cloudKitPendingChangeFilterSkipsUnsupportedScopedChanges() {
        let targetZoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let supportedRecordID = CKRecord.ID(recordName: "supported-note", zoneID: targetZoneID)
        let unsupportedRecordID = CKRecord.ID(recordName: "unsupported-note", zoneID: targetZoneID)

        let result = CloudKitPendingRecordZoneChangeFilter.customZoneChanges(
            from: [
                .saveRecord(supportedRecordID),
                .deleteRecord(unsupportedRecordID),
            ],
            targetZoneID: targetZoneID,
            shouldInclude: { _ in true },
            recordID: { pendingChange in
                let recordID = CloudKitPendingRecordZoneChangeFilter.recordID(for: pendingChange)
                return recordID?.recordName == unsupportedRecordID.recordName ? nil : recordID
            }
        )

        let includedRecordNames = result.changes.compactMap {
            CloudKitPendingRecordZoneChangeFilter.recordID(for: $0)?.recordName
        }
        #expect(includedRecordNames == ["supported-note"])
        #expect(result.skippedUnsupportedCount == 1)
    }

    @Test func cloudKitErrorClassifierDetectsMissingZoneErrors() {
        let zoneNotFound = makeCloudKitError(.zoneNotFound)
        let userDeletedZone = makeCloudKitError(.userDeletedZone)
        let terminalError = makeCloudKitError(.permissionFailure)

        #expect(CloudKitErrorClassifier.isMissingZone(zoneNotFound))
        #expect(CloudKitErrorClassifier.isMissingZone(userDeletedZone))
        #expect(CloudKitErrorClassifier.isMissingZone(terminalError) == false)
        #expect(CloudKitErrorClassifier.classifyRecordSaveFailure(zoneNotFound).kind == .missingZone)
        #expect(CloudKitErrorClassifier.classifyRecordDeleteFailure(userDeletedZone).kind == .missingZone)
    }

    @Test func cloudKitErrorClassifierExtractsServerRecordConflicts() throws {
        let zoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let recordID = CKRecord.ID(recordName: "conflicting-note", zoneID: zoneID)
        let serverRecord = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
        let error = makeCloudKitError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]
        )

        let classification = CloudKitErrorClassifier.classifyRecordSaveFailure(error)
        let classifiedServerRecord = try #require(classification.serverRecord)

        #expect(classification.kind == .conflict)
        #expect(classifiedServerRecord.recordID.recordName == recordID.recordName)
        #expect(classifiedServerRecord.recordID.zoneID == recordID.zoneID)
    }

    @Test func cloudKitErrorClassifierClassifiesUnknownItemRetries() {
        let error = makeCloudKitError(.unknownItem)

        #expect(CloudKitErrorClassifier.classifyRecordSaveFailure(error).kind == .unknownItemRetry)
        #expect(CloudKitErrorClassifier.classifyRecordDeleteFailure(error).kind == .alreadyDeleted)
    }

    @Test func cloudKitErrorClassifierClassifiesRecoverablePartialSaveFailures() {
        let zoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let retryRecordID = CKRecord.ID(recordName: "retry-note", zoneID: zoneID)
        let partialErrors: [AnyHashable: Error] = [
            AnyHashable(retryRecordID): makeCloudKitError(.unknownItem)
        ]
        let partialFailure = makeCloudKitError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: partialErrors]
        )

        let classification = CloudKitErrorClassifier.classifyRetriableSavePartialFailure(
            partialFailure,
            targetZoneID: zoneID,
            pendingSaveNoteIDs: [retryRecordID.recordName]
        )

        #expect(classification == .recoverableUnknownItemSaves(noteIDs: [retryRecordID.recordName]))
    }

    @Test func cloudKitErrorClassifierPreservesMixedPartialSaveRecovery() {
        let zoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let retryRecordID = CKRecord.ID(recordName: "retry-note", zoneID: zoneID)
        let failedRecordID = CKRecord.ID(recordName: "failed-note", zoneID: zoneID)
        let partialErrors: [AnyHashable: Error] = [
            AnyHashable(retryRecordID): makeCloudKitError(.unknownItem),
            AnyHashable(failedRecordID): makeCloudKitError(.permissionFailure),
        ]
        let partialFailure = makeCloudKitError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: partialErrors]
        )

        let classification = CloudKitErrorClassifier.classifyRetriableSavePartialFailure(
            partialFailure,
            targetZoneID: zoneID,
            pendingSaveNoteIDs: [retryRecordID.recordName, failedRecordID.recordName]
        )

        #expect(classification == .partiallyRecoverableUnknownItemSaves(noteIDs: [retryRecordID.recordName]))
    }

    @Test func cloudKitErrorClassifierSeparatesRecoverableAndRejectedPartialSaveFailures() throws {
        let zoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let retryRecordID = CKRecord.ID(recordName: "retry-note", zoneID: zoneID)
        let rejectedRecordID = CKRecord.ID(recordName: "rejected-note", zoneID: zoneID)
        let partialFailure = makeCloudKitError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    AnyHashable(retryRecordID): makeCloudKitError(.unknownItem),
                    AnyHashable(rejectedRecordID): makeCloudKitError(.permissionFailure),
                ] as [AnyHashable: Error]
            ]
        )

        let classification = try #require(
            CloudKitErrorClassifier.classifyPartialRecordSaveFailures(
                partialFailure,
                targetZoneID: zoneID,
                pendingSaveNoteIDs: [retryRecordID.recordName, rejectedRecordID.recordName]
            )
        )

        #expect(classification.unknownItemRetryNoteIDs == [retryRecordID.recordName])
        #expect(classification.permanentlyRejectedSaveFailures.map(\.noteID) == [rejectedRecordID.recordName])
        #expect(classification.hasUnhandledFailures == false)
    }

    @Test func cloudKitErrorClassifierSeparatesAmbiguousPartialSaveFailures() throws {
        let zoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let ambiguousRecordID = CKRecord.ID(recordName: "ambiguous-note", zoneID: zoneID)
        let partialFailure = makeCloudKitError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    AnyHashable(ambiguousRecordID): makeCloudKitError(.serverResponseLost)
                ] as [AnyHashable: Error]
            ]
        )

        let classification = try #require(
            CloudKitErrorClassifier.classifyPartialRecordSaveFailures(
                partialFailure,
                targetZoneID: zoneID,
                pendingSaveNoteIDs: [ambiguousRecordID.recordName]
            )
        )

        #expect(classification.serverResponseLostNoteIDs == [ambiguousRecordID.recordName])
        #expect(classification.unknownItemRetryNoteIDs.isEmpty)
        #expect(classification.permanentlyRejectedSaveFailures.isEmpty)
        #expect(classification.hasUnhandledFailures)
    }

    @Test func cloudKitErrorClassifierLeavesUnhandledPartialSaveFailuresTerminal() {
        let zoneID = CKRecordZone.ID(zoneName: "StickyNotes")
        let failedRecordID = CKRecord.ID(recordName: "failed-note", zoneID: zoneID)
        let partialErrors: [AnyHashable: Error] = [
            AnyHashable(failedRecordID): makeCloudKitError(.permissionFailure)
        ]
        let partialFailure = makeCloudKitError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: partialErrors]
        )

        let classification = CloudKitErrorClassifier.classifyRetriableSavePartialFailure(
            partialFailure,
            targetZoneID: zoneID,
            pendingSaveNoteIDs: [failedRecordID.recordName]
        )

        #expect(classification == .unhandled)
    }

    @Test func cloudKitErrorClassifierBlocksNonrecoverableSaveFailures() {
        let error = makeCloudKitError(.permissionFailure)

        let saveClassification = CloudKitErrorClassifier.classifyRecordSaveFailure(error)
        let deleteClassification = CloudKitErrorClassifier.classifyRecordDeleteFailure(error)

        #expect(saveClassification.kind == .permanentlyRejected)
        #expect(saveClassification.serverRecord == nil)
        #expect(deleteClassification.kind == .terminal)
    }

    @Test func cloudKitErrorClassifierClassifiesNonrecoverableSavesAsPermanent() {
        let rejectionCodes: [CKError.Code] = [
            .internalError,
            .badContainer,
            .missingEntitlement,
            .permissionFailure,
            .invalidArguments,
            .serverRejectedRequest,
            .assetFileNotFound,
            .assetFileModified,
            .incompatibleVersion,
            .constraintViolation,
            .badDatabase,
            .quotaExceeded,
            .limitExceeded,
            .referenceViolation,
            .managedAccountRestricted,
            .assetNotAvailable,
        ]

        for code in rejectionCodes {
            let classification = CloudKitErrorClassifier.classifyRecordSaveFailure(
                makeCloudKitError(code)
            )

            #expect(classification.kind == .permanentlyRejected)
            #expect(classification.serverRecord == nil)
        }
    }

    @Test func cloudKitErrorClassifierKeepsKnownTransientSavesRetryable() {
        let retryableCodes: [CKError.Code] = [
            .partialFailure,
            .networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .notAuthenticated,
            .operationCancelled,
            .batchRequestFailed,
            .serverResponseLost,
            .zoneBusy,
            .accountTemporarilyUnavailable,
        ]

        for code in retryableCodes {
            let classification = CloudKitErrorClassifier.classifyRecordSaveFailure(
                makeCloudKitError(code)
            )

            #expect(classification.kind == .retryable)
            #expect(classification.serverRecord == nil)
        }

        let localCancellation = CloudKitErrorClassifier.classifyRecordSaveFailure(
            CancellationError()
        )
        #expect(localCancellation.kind == .retryable)
        #expect(localCancellation.serverRecord == nil)
    }

    @Test func cloudKitRecordWriteOmitsTitleOverrideFieldMissingFromProductionSchema() {
        let note = StickyNote(
            id: "conflict-copy",
            content: "Local draft",
            titleOverride: "Conflict Copy",
            needsCloudUpload: true
        )

        let record = StickyNoteRecordMapper.record(for: note, zoneID: .default)

        #expect(record.allKeys().contains("titleOverride") == false)
        #expect(record["content"] as? String == "Local draft")
    }

    @Test func cloudKitRecordIgnoresRemoteTitleOverride() throws {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let record = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
        record["content"] = "Remote note" as CKRecordValue
        record["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue
        record["titleOverride"] = "Remote Title" as CKRecordValue

        let note = try #require(StickyNoteRecordMapper.note(from: record))

        #expect(note.titleOverride == nil)
    }

    @Test func cloudKitSendBatchTrackerResolvesPermanentlyRejectedSaves() throws {
        var tracker = CloudKitSendBatchTracker()

        tracker.begin(expectedSaveNoteIDs: ["rejected-note"], expectedDeleteNoteIDs: [])
        tracker.markPermanentlyRejectedSave(
            noteID: "rejected-note",
            message: "Cannot create or modify field 'titleOverride'"
        )

        let result = tracker.finalize()

        #expect(result.permanentlyRejectedSaveNoteIDs == ["rejected-note"])
        #expect(result.savedNotes.isEmpty)
        #expect(result.pendingNotesRequiringRetry.isEmpty)
        #expect(result.failureMessage == "Cannot create or modify field 'titleOverride'")
    }

    @Test func syncApplyBlocksPermanentlyRejectedNotesWithoutMarkingThemClean() throws {
        let sentNote = StickyNote(
            id: "rejected-note",
            content: "Local draft",
            titleOverride: "Conflict Copy",
            lastModified: Date(timeIntervalSince1970: 30),
            needsCloudUpload: true
        )

        let outcome = StickyNotesMergeEngine.apply(
            syncResult: CloudSyncBatchResult(permanentlyRejectedSaveNoteIDs: [sentNote.id]),
            to: [sentNote],
            pendingDeletionIDs: [],
            sentNotesByID: [sentNote.id: sentNote]
        )
        let rejectedNote = try #require(outcome.notes.first)
        let coordinator = StickyNotesSyncCoordinator(cloudService: MockCloudService())
        let blockedState = StickyNotesSyncLocalState(notes: outcome.notes, pendingDeletionIDs: [])
        let automaticChanges = coordinator.outgoingChanges(from: blockedState)
        let explicitRetryChanges = coordinator.outgoingChanges(
            from: blockedState,
            retryingBlockedUploads: true
        )

        #expect(rejectedNote.needsCloudUpload)
        #expect(rejectedNote.cloudUploadBlock == .permanentlyRejected)
        #expect(!rejectedNote.shouldAttemptCloudUpload)
        #expect(rejectedNote.content == "Local draft")
        #expect(rejectedNote.titleOverride == "Conflict Copy")
        #expect(automaticChanges.saves.isEmpty)
        #expect(automaticChanges.savesByID.isEmpty)
        #expect(explicitRetryChanges.saves.map(\.id) == [sentNote.id])
        #expect(explicitRetryChanges.savesByID[sentNote.id]?.content == sentNote.content)
    }

    @Test func permanentlyRejectedNewNoteSurvivesNextCompleteRemoteSnapshot() throws {
        let sentNote = StickyNote(
            id: "rejected-new-note",
            content: "Only local copy",
            lastModified: Date(timeIntervalSince1970: 30),
            needsCloudUpload: true
        )
        let rejectionOutcome = StickyNotesMergeEngine.apply(
            syncResult: CloudSyncBatchResult(permanentlyRejectedSaveNoteIDs: [sentNote.id]),
            to: [sentNote],
            pendingDeletionIDs: [],
            sentNotesByID: [sentNote.id: sentNote]
        )

        let nextMerge = StickyNotesMergeEngine.merge(
            localNotes: rejectionOutcome.notes,
            remoteNotes: [],
            pendingDeletionIDs: [],
            remoteSnapshotCompleteness: .complete
        )
        let preservedNote = try #require(nextMerge.notes.first)

        #expect(nextMerge.notes.count == 1)
        #expect(preservedNote.id == sentNote.id)
        #expect(preservedNote.content == "Only local copy")
        #expect(preservedNote.needsCloudUpload)
        #expect(preservedNote.cloudUploadBlock == .permanentlyRejected)
    }

    @Test func permanentlyRejectedEditSurvivesStaleRemoteSnapshot() throws {
        let sentNote = StickyNote(
            id: "rejected-edit",
            content: "Unsynced local edit",
            lastModified: Date(timeIntervalSince1970: 30),
            needsCloudUpload: true,
            cloudRevision: "remote-base"
        )
        let remoteBase = StickyNote(
            id: sentNote.id,
            content: "Older remote content",
            lastModified: Date(timeIntervalSince1970: 20),
            needsCloudUpload: false,
            cloudRevision: "remote-base"
        )
        let rejectionOutcome = StickyNotesMergeEngine.apply(
            syncResult: CloudSyncBatchResult(permanentlyRejectedSaveNoteIDs: [sentNote.id]),
            to: [sentNote],
            pendingDeletionIDs: [],
            sentNotesByID: [sentNote.id: sentNote]
        )

        let nextMerge = StickyNotesMergeEngine.merge(
            localNotes: rejectionOutcome.notes,
            remoteNotes: [remoteBase],
            pendingDeletionIDs: [],
            remoteSnapshotCompleteness: .complete
        )
        let preservedNote = try #require(nextMerge.notes.first)

        #expect(nextMerge.notes.count == 1)
        #expect(preservedNote.content == "Unsynced local edit")
        #expect(preservedNote.cloudUploadBlock == .permanentlyRejected)
    }

    @Test func completeMatchingRemoteSnapshotAcknowledgesBlockedUpload() throws {
        let uploadedAt = Date(timeIntervalSince1970: 30)
        let localFrame = StickyNoteFrame(x: 20, y: 40, width: 280, height: 300)
        let blockedNote = StickyNote(
            id: "blocked-upload",
            content: "Already reached CloudKit",
            titleOverride: "Local title",
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: uploadedAt,
            isOpen: false,
            preferredFrame: localFrame,
            needsCloudUpload: true,
            cloudUploadBlock: .permanentlyRejected,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "old-revision"
        )
        let remoteNote = StickyNote(
            id: blockedNote.id,
            content: blockedNote.content,
            createdAt: Date(timeIntervalSince1970: 20),
            lastModified: uploadedAt,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([2]),
            cloudRevision: "accepted-revision"
        )

        let outcome = StickyNotesMergeEngine.merge(
            localNotes: [blockedNote],
            remoteNotes: [remoteNote],
            pendingDeletionIDs: [],
            remoteSnapshotCompleteness: .complete
        )
        let acknowledgedNote = try #require(outcome.notes.first)

        #expect(outcome.notes.count == 1)
        #expect(acknowledgedNote.content == blockedNote.content)
        #expect(acknowledgedNote.titleOverride == blockedNote.titleOverride)
        #expect(acknowledgedNote.createdAt == blockedNote.createdAt)
        #expect(acknowledgedNote.isOpen == blockedNote.isOpen)
        #expect(acknowledgedNote.preferredFrame == localFrame)
        #expect(acknowledgedNote.needsCloudUpload == false)
        #expect(acknowledgedNote.cloudUploadBlock == nil)
        #expect(acknowledgedNote.cloudKitSystemFieldsData == Data([2]))
        #expect(acknowledgedNote.cloudRevision == "accepted-revision")
    }

    @Test func completeMatchingRemoteSnapshotAcknowledgesUnblockedDirtyUpload() throws {
        let uploadedAt = Date(timeIntervalSince1970: 30)
        let dirtyNote = StickyNote(
            id: "ambiguous-upload",
            content: "Possibly accepted",
            lastModified: uploadedAt,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "old-revision"
        )
        let remoteNote = StickyNote(
            id: dirtyNote.id,
            content: dirtyNote.content,
            lastModified: uploadedAt,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([2]),
            cloudRevision: "accepted-revision"
        )

        let outcome = StickyNotesMergeEngine.merge(
            localNotes: [dirtyNote],
            remoteNotes: [remoteNote],
            pendingDeletionIDs: [],
            remoteSnapshotCompleteness: .complete
        )
        let acknowledgedNote = try #require(outcome.notes.first)

        #expect(outcome.notes.count == 1)
        #expect(acknowledgedNote.needsCloudUpload == false)
        #expect(acknowledgedNote.cloudUploadBlock == nil)
        #expect(acknowledgedNote.cloudKitSystemFieldsData == Data([2]))
        #expect(acknowledgedNote.cloudRevision == "accepted-revision")
    }

    @Test func incompleteMatchingRemoteSnapshotDoesNotAcknowledgeBlockedUpload() throws {
        let uploadedAt = Date(timeIntervalSince1970: 30)
        let blockedNote = StickyNote(
            id: "blocked-upload",
            content: "Possibly uploaded",
            lastModified: uploadedAt,
            needsCloudUpload: true,
            cloudUploadBlock: .permanentlyRejected,
            cloudRevision: "old-revision"
        )
        let remoteNote = StickyNote(
            id: blockedNote.id,
            content: blockedNote.content,
            lastModified: uploadedAt,
            needsCloudUpload: false,
            cloudRevision: "remote-revision"
        )
        let incompleteSnapshots: [CloudRemoteSnapshotCompleteness] = [
            .partial("Partial fetch"),
            .unavailable("CloudKit unavailable"),
            .remoteReset("Zone reset"),
        ]

        for completeness in incompleteSnapshots {
            let outcome = StickyNotesMergeEngine.merge(
                localNotes: [blockedNote],
                remoteNotes: [remoteNote],
                pendingDeletionIDs: [],
                remoteSnapshotCompleteness: completeness
            )
            let preservedNote = try #require(outcome.notes.first)

            #expect(outcome.notes.count == 1)
            #expect(preservedNote == blockedNote)
        }
    }

    @Test func syncApplyKeepsPermanentlyRejectedNotesDirtyAfterNewerLocalEdits() throws {
        let sentNote = StickyNote(
            id: "rejected-note",
            content: "Local draft",
            lastModified: Date(timeIntervalSince1970: 30),
            needsCloudUpload: true
        )
        var editedNote = sentNote
        editedNote.content = "Second draft"
        editedNote.lastModified = Date(timeIntervalSince1970: 60)

        let outcome = StickyNotesMergeEngine.apply(
            syncResult: CloudSyncBatchResult(permanentlyRejectedSaveNoteIDs: [sentNote.id]),
            to: [editedNote],
            pendingDeletionIDs: [],
            sentNotesByID: [sentNote.id: sentNote]
        )
        let retriedNote = try #require(outcome.notes.first)

        #expect(retriedNote.needsCloudUpload)
        #expect(retriedNote.cloudUploadBlock == nil)
        #expect(retriedNote.shouldAttemptCloudUpload)
        #expect(retriedNote.content == "Second draft")
    }

    @Test func rejectedUploadPersistsWithoutRetryAndRetriesAfterContentEdit() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let rejectionService = PermanentlyRejectingCloudService()
        let rejectionScheduler = TestDelayedTaskScheduler()
        let store = StickyNotesStore(
            fileStore: fileStore,
            cloudService: rejectionService,
            delayedTaskScheduler: rejectionScheduler,
            autoLoad: false
        )

        await store.load()
        let noteID = store.createNote()
        await rejectionScheduler.runNext()
        await store.flushPendingPersistence()

        let rejectedNote = try #require(store.note(withID: noteID))
        let persistedSnapshot = try await fileStore.load()
        let persistedNote = try #require(persistedSnapshot.notes.first(where: { $0.id == noteID }))
        #expect(rejectedNote.needsCloudUpload)
        #expect(rejectedNote.cloudUploadBlock == .permanentlyRejected)
        #expect(persistedNote.cloudUploadBlock == .permanentlyRejected)
        #expect(rejectionScheduler.pendingOperationCount == 0)
        #expect(await rejectionService.saveAttemptCount() == 1)

        let acceptingService = MockCloudService()
        let retryScheduler = TestDelayedTaskScheduler()
        let reloadedStore = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: fileURL),
            cloudService: acceptingService,
            delayedTaskScheduler: retryScheduler,
            autoLoad: false
        )

        await reloadedStore.load()
        await reloadedStore.syncNow()

        let protectedNote = try #require(reloadedStore.note(withID: noteID))
        #expect(protectedNote.cloudUploadBlock == .permanentlyRejected)
        #expect(await acceptingService.snapshot().isEmpty)

        reloadedStore.updateContent(id: noteID, content: protectedNote.content)
        reloadedStore.updatePreferredFrame(
            id: noteID,
            frame: StickyNoteFrame(x: 20, y: 30, width: 280, height: 280)
        )
        #expect(reloadedStore.note(withID: noteID)?.cloudUploadBlock == .permanentlyRejected)

        reloadedStore.updateContent(id: noteID, content: "Retry this content")
        let unblockedNote = try #require(reloadedStore.note(withID: noteID))
        #expect(unblockedNote.cloudUploadBlock == nil)
        #expect(unblockedNote.shouldAttemptCloudUpload)

        await retryScheduler.runAll()

        let uploadedNote = try #require(reloadedStore.note(withID: noteID))
        #expect(uploadedNote.content == "Retry this content")
        #expect(uploadedNote.needsCloudUpload == false)
        #expect(uploadedNote.cloudUploadBlock == nil)
        #expect(await acceptingService.snapshot().contains { $0.id == noteID })
    }

    @Test func explicitRetryResubmitsPersistedRejectedUploadWithoutContentChange() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let blockedNote = StickyNote(
            id: "blocked-note",
            content: "Unchanged local content",
            needsCloudUpload: true,
            cloudUploadBlock: .permanentlyRejected
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [blockedNote]))

        let acceptingService = MockCloudService()
        let store = StickyNotesStore(
            fileStore: fileStore,
            cloudService: acceptingService,
            delayedTaskScheduler: TestDelayedTaskScheduler(),
            autoLoad: false
        )

        await store.load()
        await store.syncNow()

        #expect(await acceptingService.snapshot().isEmpty)
        #expect(store.note(withID: blockedNote.id)?.cloudUploadBlock == .permanentlyRejected)

        await store.syncNow(retryingBlockedUploads: true)

        let uploadedNote = try #require(store.note(withID: blockedNote.id))
        #expect(uploadedNote.content == blockedNote.content)
        #expect(uploadedNote.needsCloudUpload == false)
        #expect(uploadedNote.cloudUploadBlock == nil)
        #expect(await acceptingService.snapshot().contains { $0.id == blockedNote.id })
    }

    @Test func mergeKeepsLocalTitleOverrideWhenRemoteNoteWins() throws {
        let localNote = StickyNote(
            id: "shared-note",
            content: "Older",
            titleOverride: "Conflict Copy",
            lastModified: Date(timeIntervalSince1970: 10),
            needsCloudUpload: false
        )
        let remoteNote = StickyNote(
            id: "shared-note",
            content: "Newer",
            lastModified: Date(timeIntervalSince1970: 20),
            needsCloudUpload: false
        )

        let outcome = StickyNotesMergeEngine.merge(
            localNotes: [localNote],
            remoteNotes: [remoteNote],
            pendingDeletionIDs: []
        )
        let mergedNote = try #require(outcome.notes.first)

        #expect(mergedNote.content == "Newer")
        #expect(mergedNote.titleOverride == "Conflict Copy")
    }

    @Test func mergeDoesNotForkConflictCopiesForLocalOnlyTitleOverrides() {
        let localNote = StickyNote(
            id: "shared-note",
            content: "Same content",
            titleOverride: "Conflict Copy",
            lastModified: Date(timeIntervalSince1970: 20),
            needsCloudUpload: true,
            cloudRevision: "local-revision"
        )
        let remoteNote = StickyNote(
            id: "shared-note",
            content: "Same content",
            lastModified: Date(timeIntervalSince1970: 30),
            needsCloudUpload: false,
            cloudRevision: "remote-revision"
        )

        let outcome = StickyNotesMergeEngine.merge(
            localNotes: [localNote],
            remoteNotes: [remoteNote],
            pendingDeletionIDs: []
        )

        #expect(outcome.notes.count == 1)
        #expect(outcome.notes.contains { $0.title == "Conflict Copy" })
    }

    @Test func cloudKitSendBatchTrackerFinalizesResolvedBatch() throws {
        var tracker = CloudKitSendBatchTracker()
        let savedNote = StickyNote(
            id: "saved-note",
            content: "Saved",
            needsCloudUpload: true
        )
        let remoteConflictNote = StickyNote(
            id: "conflicting-note",
            content: "Remote",
            needsCloudUpload: true
        )

        tracker.begin(
            expectedSaveNoteIDs: [savedNote.id, remoteConflictNote.id],
            expectedDeleteNoteIDs: ["deleted-note"]
        )
        tracker.markSaved(savedNote)
        tracker.markConflict(noteID: remoteConflictNote.id, remoteNote: remoteConflictNote)
        tracker.markDeleted(noteID: "deleted-note")

        let result = tracker.finalize()
        let savedResult = try #require(result.savedNotes.first)
        let conflict = try #require(result.conflicts.first)

        #expect(tracker.hasActiveBatch == false)
        #expect(result.savedNotes.count == 1)
        #expect(savedResult.id == savedNote.id)
        #expect(savedResult.needsCloudUpload == false)
        #expect(result.deletedNoteIDs == ["deleted-note"])
        #expect(result.conflicts.count == 1)
        #expect(conflict.localNoteID == remoteConflictNote.id)
        #expect(conflict.remoteNote.content == "Remote")
        #expect(conflict.remoteNote.needsCloudUpload == false)
        #expect(result.failureMessage == nil)
    }

    @Test func cloudKitSendBatchTrackerDefersOrdinaryUnknownItemRetry() throws {
        var tracker = CloudKitSendBatchTracker()
        let pendingNote = StickyNote(
            id: "pending-note",
            content: "Needs retry",
            needsCloudUpload: true,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "stale-revision"
        )

        tracker.begin(expectedSaveNoteIDs: [pendingNote.id], expectedDeleteNoteIDs: [])
        tracker.beginSendAttempt()
        let didClaimFailure = tracker.claimSaveFailure(noteID: pendingNote.id)
        #expect(didClaimFailure)
        let disposition = tracker.handleUnknownItemSave(pendingNote, message: "Unknown item")

        let result = tracker.finalize()
        let retryNote = try #require(result.pendingNotesRequiringRetry.first)

        #expect(disposition == .deferredRetry(pendingNote.resettingCloudKitSystemFields()))
        #expect(result.pendingNotesRequiringRetry.count == 1)
        #expect(retryNote.id == pendingNote.id)
        #expect(retryNote.needsCloudUpload)
        #expect(retryNote.cloudKitSystemFieldsData == nil)
        #expect(retryNote.cloudRevision == nil)
        #expect(result.failureMessage == nil)
    }

    @Test func cloudKitSendBatchTrackerRejectsRepeatedUnknownItemForFreshRecord() {
        var tracker = CloudKitSendBatchTracker()
        let freshNote = StickyNote(
            id: "fresh-note",
            content: "No stale metadata",
            needsCloudUpload: true
        )
        tracker.begin(expectedSaveNoteIDs: [freshNote.id], expectedDeleteNoteIDs: [])
        tracker.beginSendAttempt()
        let didClaimFailure = tracker.claimSaveFailure(noteID: freshNote.id)
        #expect(didClaimFailure)

        let disposition = tracker.handleUnknownItemSave(
            freshNote,
            message: "Fresh record was still unknown"
        )
        let result = tracker.finalize()

        #expect(disposition == .permanentlyRejected)
        #expect(result.permanentlyRejectedSaveNoteIDs == [freshNote.id])
        #expect(result.pendingNotesRequiringRetry.isEmpty)
        #expect(result.failureMessage == "Fresh record was still unknown")
    }

    @Test func cloudKitSendBatchTrackerBoundsForcedUnknownItemRetry() throws {
        var tracker = CloudKitSendBatchTracker()
        let blockedNote = StickyNote(
            id: "blocked-note",
            content: "Retry once",
            needsCloudUpload: true,
            cloudUploadBlock: .permanentlyRejected,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "stale-revision"
        )
        tracker.begin(
            expectedSaveNoteIDs: [blockedNote.id],
            expectedDeleteNoteIDs: [],
            forcedBlockedSaveNoteIDs: [blockedNote.id]
        )
        tracker.beginSendAttempt()
        let didClaimInitialFailure = tracker.claimSaveFailure(noteID: blockedNote.id)
        #expect(didClaimInitialFailure)

        let firstDisposition = tracker.handleUnknownItemSave(
            blockedNote,
            message: "Unknown item"
        )
        let didClaimDuplicateFailure = tracker.claimSaveFailure(noteID: blockedNote.id)
        #expect(!didClaimDuplicateFailure)
        let freshRetry = try #require(tracker.takeFreshRetryCandidates().first)

        #expect(firstDisposition == .retryImmediately(blockedNote.resettingCloudKitSystemFields()))
        #expect(freshRetry.cloudKitSystemFieldsData == nil)
        #expect(freshRetry.cloudRevision == nil)
        #expect(tracker.takeFreshRetryCandidates().isEmpty)
        #expect(tracker.shouldIncludeBlockedSave(noteID: blockedNote.id))
        #expect(!tracker.shouldIncludeBlockedSave(noteID: "unrelated-note"))

        tracker.beginSendAttempt()
        let didClaimRetryFailure = tracker.claimSaveFailure(noteID: blockedNote.id)
        #expect(didClaimRetryFailure)
        let secondDisposition = tracker.handleUnknownItemSave(
            freshRetry,
            message: "Still unknown"
        )
        let result = tracker.finalize()

        #expect(secondDisposition == .permanentlyRejected)
        #expect(result.permanentlyRejectedSaveNoteIDs == [blockedNote.id])
        #expect(result.pendingNotesRequiringRetry.isEmpty)
        #expect(result.failureMessage == "Still unknown")
    }

    @Test func cloudKitSendBatchTrackerAcceptsForcedFreshRecordRetry() throws {
        var tracker = CloudKitSendBatchTracker()
        let blockedNote = StickyNote(
            id: "blocked-note",
            content: "Retry once",
            needsCloudUpload: true,
            cloudUploadBlock: .permanentlyRejected,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "stale-revision"
        )
        tracker.begin(
            expectedSaveNoteIDs: [blockedNote.id],
            expectedDeleteNoteIDs: [],
            forcedBlockedSaveNoteIDs: [blockedNote.id]
        )
        tracker.beginSendAttempt()
        let didClaimFailure = tracker.claimSaveFailure(noteID: blockedNote.id)
        #expect(didClaimFailure)
        _ = tracker.handleUnknownItemSave(blockedNote, message: "Unknown item")
        let freshRetry = try #require(tracker.takeFreshRetryCandidates().first)

        tracker.markSaved(freshRetry)
        let result = tracker.finalize()
        let savedNote = try #require(result.savedNotes.first)

        #expect(result.savedNotes.count == 1)
        #expect(savedNote.id == blockedNote.id)
        #expect(savedNote.needsCloudUpload == false)
        #expect(savedNote.cloudUploadBlock == nil)
        #expect(result.permanentlyRejectedSaveNoteIDs.isEmpty)
        #expect(result.failureMessage == nil)
    }

    @Test func cloudKitSendBatchTrackerReportsUnresolvedExpectedChanges() {
        var tracker = CloudKitSendBatchTracker()

        tracker.begin(
            expectedSaveNoteIDs: ["unsaved-note"],
            expectedDeleteNoteIDs: ["undeleted-note"]
        )

        let result = tracker.finalize()

        #expect(result.savedNotes.isEmpty)
        #expect(result.deletedNoteIDs.isEmpty)
        #expect(result.pendingNotesRequiringRetry.isEmpty)
        #expect(result.conflicts.isEmpty)
        #expect(result.failureMessage == "Some CloudKit changes are still pending.")
    }

    @Test func cloudKitRecordIgnoresRemoteWindowState() throws {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let record = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
        record["content"] = "Remote note" as CKRecordValue
        record["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue
        record["isOpen"] = NSNumber(value: false)
        record["frameX"] = NSNumber(value: 40)
        record["frameY"] = NSNumber(value: 60)
        record["frameWidth"] = NSNumber(value: 280)
        record["frameHeight"] = NSNumber(value: 300)

        let note = try #require(StickyNoteRecordMapper.note(from: record))

        #expect(note.isOpen == true)
        #expect(note.preferredFrame == nil)
    }

    @Test func cloudKitRecordWriteOmitsColorFieldFromRestoredRecords() {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let archivedRecord = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
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

        let record = StickyNoteRecordMapper.record(for: note, zoneID: .default)
        let color = record["color"] as? String

        #expect(color == nil)
        #expect(record.allKeys().contains("color") == false)
        #expect(record["content"] as? String == "Updated")
    }

    @Test func cloudKitRecordWriteOmitsCreatedAtFieldFromRestoredRecords() {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let archivedRecord = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
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

        let record = StickyNoteRecordMapper.record(for: note, zoneID: .default)
        let createdAt = record["createdAt"] as? Date

        #expect(createdAt == nil)
        #expect(record.allKeys().contains("createdAt") == false)
        #expect(record["content"] as? String == "Updated")
    }

    @Test func cloudKitRecordWriteOmitsLocalWindowStateFieldsFromRestoredRecords() {
        let recordID = CKRecord.ID(recordName: "remote-note", zoneID: .default)
        let archivedRecord = CKRecord(recordType: StickyNoteRecordMapper.recordType, recordID: recordID)
        archivedRecord["content"] = "Original" as CKRecordValue
        archivedRecord["lastModified"] = Date(timeIntervalSince1970: 20) as CKRecordValue
        archivedRecord["isOpen"] = NSNumber(value: true)
        archivedRecord["frameX"] = NSNumber(value: 12)
        archivedRecord["frameY"] = NSNumber(value: 24)
        archivedRecord["frameWidth"] = NSNumber(value: 280)
        archivedRecord["frameHeight"] = NSNumber(value: 300)

        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archivedRecord.encodeSystemFields(with: archiver)
        archiver.finishEncoding()

        let note = StickyNote(
            id: "remote-note",
            content: "Updated",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 30),
            isOpen: false,
            preferredFrame: StickyNoteFrame(x: 40, y: 60, width: 320, height: 280),
            needsCloudUpload: true,
            cloudKitSystemFieldsData: archiver.encodedData
        )

        let record = StickyNoteRecordMapper.record(for: note, zoneID: .default)

        #expect(record["isOpen"] == nil)
        #expect(record["frameX"] == nil)
        #expect(record["frameY"] == nil)
        #expect(record["frameWidth"] == nil)
        #expect(record["frameHeight"] == nil)
        #expect(record.allKeys().contains("isOpen") == false)
        #expect(record.allKeys().contains("frameX") == false)
        #expect(record.allKeys().contains("frameY") == false)
        #expect(record.allKeys().contains("frameWidth") == false)
        #expect(record.allKeys().contains("frameHeight") == false)
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

    @Test func localWindowStatePersistsWithoutMarkingNoteDirtyForCloudSync() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let cloudService = MockCloudService()
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        let noteID = store.createNote()
        await store.syncNow()

        let frame = StickyNoteFrame(x: 80, y: 120, width: 320, height: 280)
        store.closeNote(id: noteID, frame: frame)

        let closedNote = try #require(store.note(withID: noteID))
        #expect(closedNote.isOpen == false)
        #expect(closedNote.preferredFrame == frame)
        #expect(closedNote.needsCloudUpload == false)

        store.openNote(id: noteID)

        let reopenedNote = try #require(store.note(withID: noteID))
        #expect(reopenedNote.isOpen == true)
        #expect(reopenedNote.preferredFrame == frame)
        #expect(reopenedNote.needsCloudUpload == false)
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
        let delayedTaskScheduler = TestDelayedTaskScheduler()
        let session = NoteDraftSession(delayedTaskScheduler: delayedTaskScheduler)

        session.configure(
            noteID: "note",
            initialContent: persistedContent,
            readPersistedContent: { persistedContent },
            persistDraftContent: { content, _ in
                persistedContent = content
                return .persisted(primaryContent: persistedContent)
            }
        )

        session.updateDraftContent("First draft")
        session.updateDraftContent("Final draft")

        await delayedTaskScheduler.runAll()

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
            persistDraftContent: { content, _ in
                persistedContentByID["first"] = content
                return .persisted(primaryContent: content)
            }
        )
        session.updateDraftContent("Edited first note")

        session.configure(
            noteID: "second",
            initialContent: persistedContentByID["second"] ?? "",
            force: true,
            readPersistedContent: { persistedContentByID["second"] },
            persistDraftContent: { content, _ in
                persistedContentByID["second"] = content
                return .persisted(primaryContent: content)
            }
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
            persistDraftContent: { content, _ in
                persistedContent = content
                return .persisted(primaryContent: persistedContent)
            }
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
            persistDraftContent: { content, _ in
                persistedContent = content
                return .persisted(primaryContent: persistedContent)
            }
        )

        session.updateDraftContent("Local edit")
        session.flush()
        session.handlePersistedContentChange("Remote edit")

        #expect(persistedContent == "Local edit")
        #expect(session.draftContent == "Remote edit")
    }

    @Test func conflictedDraftKeepsOriginalBaseUntilEditorTextIsReplaced() {
        var persistedContent = "Original"
        var expectedBaseContents: [String] = []
        var conflictCopies: [String] = []
        let session = NoteDraftSession(debounceInterval: .seconds(10))

        session.configure(
            noteID: "note",
            initialContent: persistedContent,
            readPersistedContent: { persistedContent },
            persistDraftContent: { content, expectedBaseContent in
                expectedBaseContents.append(expectedBaseContent)
                guard persistedContent == expectedBaseContent else {
                    conflictCopies.append(content)
                    return .conflicted(
                        primaryContent: persistedContent,
                        conflictCopyID: "copy-\(conflictCopies.count)"
                    )
                }

                persistedContent = content
                return .persisted(primaryContent: persistedContent)
            }
        )

        session.updateDraftContent("Local draft")
        persistedContent = "Remote edit"
        session.handlePersistedContentChange(persistedContent)

        session.flush()

        #expect(session.draftContent == "Remote edit")
        #expect(persistedContent == "Remote edit")
        #expect(conflictCopies == ["Local draft"])

        session.updateDraftContent("Local draft plus")
        persistedContent = "Remote edit v2"
        session.handlePersistedContentChange(persistedContent)
        session.flush()

        #expect(expectedBaseContents == ["Original", "Original"])
        #expect(persistedContent == "Remote edit v2")
        #expect(conflictCopies == ["Local draft", "Local draft plus"])
    }

    @Test func conflictedDraftClearsWhenEditorAppliesPrimaryContent() {
        var persistedContent = "Original"
        var expectedBaseContents: [String] = []
        var conflictCopies: [String] = []
        let session = NoteDraftSession(debounceInterval: .seconds(10))

        session.configure(
            noteID: "note",
            initialContent: persistedContent,
            readPersistedContent: { persistedContent },
            persistDraftContent: { content, expectedBaseContent in
                expectedBaseContents.append(expectedBaseContent)
                guard persistedContent == expectedBaseContent else {
                    conflictCopies.append(content)
                    return .conflicted(
                        primaryContent: persistedContent,
                        conflictCopyID: "copy-\(conflictCopies.count)"
                    )
                }

                persistedContent = content
                return .persisted(primaryContent: persistedContent)
            }
        )

        session.updateDraftContent("Local draft")
        persistedContent = "Remote edit"
        session.handlePersistedContentChange(persistedContent)
        session.flush()

        session.updateDraftContent("Remote edit")
        session.updateDraftContent("Fresh local edit")
        session.flush()

        #expect(expectedBaseContents == ["Original", "Remote edit"])
        #expect(persistedContent == "Fresh local edit")
        #expect(conflictCopies == ["Local draft"])
    }

    @Test func conflictedDraftPersistsPostConflictEditBeforeClearingOnEditorReplacement() {
        var persistedContent = "Original"
        var expectedBaseContents: [String] = []
        var conflictCopies: [String] = []
        let session = NoteDraftSession(debounceInterval: .seconds(10))

        session.configure(
            noteID: "note",
            initialContent: persistedContent,
            readPersistedContent: { persistedContent },
            persistDraftContent: { content, expectedBaseContent in
                expectedBaseContents.append(expectedBaseContent)
                guard persistedContent == expectedBaseContent else {
                    conflictCopies.append(content)
                    return .conflicted(
                        primaryContent: persistedContent,
                        conflictCopyID: "copy-\(conflictCopies.count)"
                    )
                }

                persistedContent = content
                return .persisted(primaryContent: persistedContent)
            }
        )

        session.updateDraftContent("Local draft")
        persistedContent = "Remote edit"
        session.handlePersistedContentChange(persistedContent)
        session.flush()

        session.updateDraftContent("Local draft plus")
        session.updateDraftContent("Remote edit")
        session.flush()

        #expect(expectedBaseContents == ["Original", "Original"])
        #expect(persistedContent == "Remote edit")
        #expect(session.draftContent == "Remote edit")
        #expect(conflictCopies == ["Local draft", "Local draft plus"])
    }

    @Test func pendingDraftFlushCreatesConflictCopyWhenPersistedContentChanged() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let sharedID = "shared-note"
        let originalNote = StickyNote(
            id: sharedID,
            content: "Original",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([1])
        )
        try await fileStore.save(
            StickyNotesSnapshot(
                notes: [originalNote],
                pendingDeletionIDs: [],
                lastSuccessfulCloudSync: Date(timeIntervalSince1970: 25),
                cloudKitStateSerializationData: Data([1])
            )
        )

        let remoteNote = StickyNote(
            id: sharedID,
            content: "Remote edit",
            color: .yellow,
            createdAt: originalNote.createdAt,
            lastModified: Date(timeIntervalSince1970: 30),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([2])
        )
        let cloudService = MockCloudService(remoteNotes: [remoteNote])
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)
        let session = NoteDraftSession(debounceInterval: .seconds(10))

        await store.load()
        session.configure(
            noteID: sharedID,
            initialContent: originalNote.content,
            readPersistedContent: { store.note(withID: sharedID)?.content },
            persistDraftContent: { content, expectedBaseContent in
                store.updateContent(
                    id: sharedID,
                    content: content,
                    expectedBaseContent: expectedBaseContent
                )
            }
        )
        session.updateDraftContent("Local draft")

        await store.syncNow()
        let remotePrimary = try #require(store.note(withID: sharedID))
        session.handlePersistedContentChange(remotePrimary.content)

        session.flush()

        let primaryNote = try #require(store.note(withID: sharedID))
        #expect(primaryNote.content == "Remote edit")
        #expect(primaryNote.needsCloudUpload == false)
        #expect(session.draftContent == "Remote edit")

        let conflictCopies = store.notes.filter { note in
            note.id != sharedID && note.title == "Conflict Copy"
        }
        #expect(conflictCopies.count == 1)
        let conflictCopy = try #require(conflictCopies.first)
        #expect(conflictCopy.content == "Local draft")
        #expect(conflictCopy.needsCloudUpload)
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

    @Test func automaticSyncFlushesPendingPersistenceBeforeFetchingRemoteSnapshot() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let cloudService = SnapshotReadingCloudService(fileURL: fileURL)
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)

        await store.load()
        let noteID = store.createNote()
        store.updateContent(id: noteID, content: "Edited before automatic sync")

        await store.syncAutomatically(reason: .appActivation)

        let observedContents = await cloudService.persistedContentsAtFetch()
        #expect(observedContents.last?.contains("Edited before automatic sync") == true)
    }

    @Test func automaticSyncDoesNotFetchBeforeLocalLoadFinishes() async throws {
        let cloudService = MockCloudService()
        let store = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: temporaryStoreURL()),
            cloudService: cloudService,
            autoLoad: false
        )

        await store.syncAutomatically(reason: .appActivation)

        #expect(await cloudService.fetchCount() == 0)
    }

    @Test func automaticSyncDoesNotFetchAfterUnrecoverableLocalSnapshotFailure() async throws {
        let fileURL = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL, options: .atomic)

        let cloudService = MockCloudService()
        let store = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: fileURL),
            cloudService: cloudService,
            autoLoad: false
        )

        await store.load()
        await store.syncAutomatically(reason: .periodicPoll)

        #expect(await cloudService.fetchCount() == 0)
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

        await store.flushPendingPersistence()

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

        await store.flushPendingPersistence()

        let snapshot = try await fileStore.load()
        #expect(Set(snapshot.notes.map(\.id)) == Set([firstNoteID, secondNoteID]))
    }

    @Test func storeMaintainsOrderedIDsAndLookupThroughTargetedMutations() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let olderNote = StickyNote(
            id: "older-note",
            content: "Older",
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            needsCloudUpload: false
        )
        let newerNote = StickyNote(
            id: "newer-note",
            content: "Newer",
            createdAt: Date(timeIntervalSince1970: 30),
            lastModified: Date(timeIntervalSince1970: 40),
            needsCloudUpload: false
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [olderNote, newerNote]))
        let store = StickyNotesStore(fileStore: fileStore, cloudService: MockCloudService(), autoLoad: false)

        await store.load()

        #expect(store.noteIDs == ["newer-note", "older-note"])
        #expect(store.notes.map(\.id) == store.noteIDs)

        let frame = StickyNoteFrame(x: 40, y: 60, width: 320, height: 280)
        store.updatePreferredFrame(id: olderNote.id, frame: frame)

        #expect(store.noteIDs == ["newer-note", "older-note"])
        #expect(store.note(withID: olderNote.id)?.preferredFrame == frame)

        store.updateContent(id: olderNote.id, content: "Older edited")

        #expect(store.noteIDs.first == olderNote.id)
        #expect(store.notes.map(\.id) == store.noteIDs)
        #expect(store.notes(orderedBy: [newerNote.id, olderNote.id, "missing"]).map(\.id) == [
            newerNote.id,
            olderNote.id,
        ])

        store.deleteNote(id: newerNote.id)

        #expect(store.note(withID: newerNote.id) == nil)
        #expect(store.noteIDs == [olderNote.id])
        #expect(store.notes.map(\.id) == [olderNote.id])
    }

    @Test func noteObservationOnlyPublishesTargetedNoteChanges() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let firstNote = StickyNote(
            id: "first-note",
            content: "First",
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            needsCloudUpload: false
        )
        let secondNote = StickyNote(
            id: "second-note",
            content: "Second",
            createdAt: Date(timeIntervalSince1970: 30),
            lastModified: Date(timeIntervalSince1970: 40),
            needsCloudUpload: false
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [firstNote, secondNote]))
        let store = StickyNotesStore(fileStore: fileStore, cloudService: MockCloudService(), autoLoad: false)

        await store.load()

        let firstObservation = store.noteObservation(withID: firstNote.id)
        var observedFirstContents: [String?] = []
        let cancellable = firstObservation.$note
            .dropFirst()
            .sink { note in
                observedFirstContents.append(note?.content)
            }

        store.updateContent(id: secondNote.id, content: "Second edited")
        #expect(observedFirstContents.isEmpty)

        store.updateContent(id: firstNote.id, content: "First edited")
        #expect(observedFirstContents == ["First edited"])

        _ = cancellable
    }

    @Test func listObservationPublishesOnlyOrderedIDChanges() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let olderNote = StickyNote(
            id: "older-note",
            content: "Older",
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            needsCloudUpload: false
        )
        let newerNote = StickyNote(
            id: "newer-note",
            content: "Newer",
            createdAt: Date(timeIntervalSince1970: 30),
            lastModified: Date(timeIntervalSince1970: 40),
            needsCloudUpload: false
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [olderNote, newerNote]))
        let store = StickyNotesStore(fileStore: fileStore, cloudService: MockCloudService(), autoLoad: false)

        await store.load()

        let listObservation = store.noteListObservation()
        var observedNoteIDs: [[String]] = []
        let cancellable = listObservation.$noteIDs
            .dropFirst()
            .sink { ids in
                observedNoteIDs.append(ids)
            }

        store.updatePreferredFrame(
            id: olderNote.id,
            frame: StickyNoteFrame(x: 40, y: 60, width: 320, height: 280)
        )
        #expect(observedNoteIDs.isEmpty)

        store.updateContent(id: olderNote.id, content: "Older edited")
        #expect(observedNoteIDs == [[olderNote.id, newerNote.id]])

        _ = cancellable
    }

    @Test func statusObservationTracksSyncErrorsAndClearing() async throws {
        let fileStore = StickyNotesFileStore(fileURL: temporaryStoreURL())
        let cloudService = MockCloudService(
            remoteSnapshotCompleteness: .unavailable("CloudKit fetch failed.")
        )
        let store = StickyNotesStore(fileStore: fileStore, cloudService: cloudService, autoLoad: false)
        let statusObservation = store.syncStatusObservation()

        await store.load()
        #expect(statusObservation.hasFinishedInitialLoad)

        await store.syncNow()
        #expect(statusObservation.syncState == .failed("CloudKit fetch failed."))
        #expect(statusObservation.lastErrorMessage == "Cloud sync failed: CloudKit fetch failed.")

        store.clearLastErrorMessage()
        #expect(statusObservation.lastErrorMessage == nil)
    }

    @Test func contentEditsCoalesceSnapshotPersistenceUntilFlush() async throws {
        let fileURL = temporaryStoreURL()
        let fileStore = StickyNotesFileStore(fileURL: fileURL)
        let note = StickyNote(
            id: "editable-note",
            content: "Original",
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            needsCloudUpload: false
        )
        try await fileStore.save(StickyNotesSnapshot(notes: [note]))
        let store = StickyNotesStore(fileStore: fileStore, cloudService: MockCloudService(), autoLoad: false)

        await store.load()
        store.updateContent(id: note.id, content: "Edited")

        let snapshotBeforeFlush = try await StickyNotesFileStore(fileURL: fileURL).load()
        #expect(snapshotBeforeFlush.notes.first?.content == "Original")

        await store.flushPendingPersistence()

        let snapshotAfterFlush = try await StickyNotesFileStore(fileURL: fileURL).load()
        #expect(snapshotAfterFlush.notes.first?.content == "Edited")
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

    @Test func changedCloudRevisionCreatesConflictEvenWhenRemoteClockIsOlder() {
        let sharedID = "shared-note"
        let localNote = StickyNote(
            id: sharedID,
            content: "Local draft",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 1_000),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "base-revision"
        )
        let remoteNote = StickyNote(
            id: sharedID,
            content: "Remote edit",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([2]),
            cloudRevision: "newer-server-revision"
        )

        let outcome = StickyNotesMergeEngine.merge(
            localNotes: [localNote],
            remoteNotes: [remoteNote],
            pendingDeletionIDs: []
        )

        #expect(outcome.notes.count == 2)
        #expect(outcome.notes.contains { $0.id == sharedID && $0.content == "Remote edit" })
        #expect(outcome.notes.contains { $0.id != sharedID && $0.content == "Local draft" })
    }

    @Test func unchangedCloudRevisionKeepsDirtyLocalNoteDespiteRemoteClock() {
        let sharedID = "shared-note"
        let localNote = StickyNote(
            id: sharedID,
            content: "Local draft",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "base-revision"
        )
        let remoteNote = StickyNote(
            id: sharedID,
            content: "Original",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 1_000),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([1]),
            cloudRevision: "base-revision"
        )

        let outcome = StickyNotesMergeEngine.merge(
            localNotes: [localNote],
            remoteNotes: [remoteNote],
            pendingDeletionIDs: []
        )
        let mergedNote = try! #require(outcome.notes.first)

        #expect(outcome.notes.count == 1)
        #expect(mergedNote.content == "Local draft")
        #expect(mergedNote.needsCloudUpload)
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

    @Test func mergeEnginePreservesEarlierLocalCreatedAtWhenRemoteFallbackIsNewer() {
        let localNote = StickyNote(
            id: "shared-note",
            content: "Local",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: nil
        )
        let remoteNote = StickyNote(
            id: "shared-note",
            content: "Remote",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 40),
            lastModified: Date(timeIntervalSince1970: 30),
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

        #expect(mergedNote.createdAt == localNote.createdAt)
        #expect(mergedNote.lastModified == remoteNote.lastModified)
        #expect(mergedNote.content == remoteNote.content)
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

    @Test func syncApplyPreservesEarlierLocalCreatedAtWhenSavedRecordUsesUploadTime() {
        let localCreatedAt = Date(timeIntervalSince1970: 10)
        let sentNote = StickyNote(
            id: "shared-note",
            content: "Draft",
            color: .yellow,
            createdAt: localCreatedAt,
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: Data([1])
        )
        let savedNote = StickyNote(
            id: sentNote.id,
            content: sentNote.content,
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 40),
            lastModified: sentNote.lastModified,
            isOpen: sentNote.isOpen,
            preferredFrame: sentNote.preferredFrame,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([2])
        )

        let outcome = StickyNotesMergeEngine.apply(
            syncResult: CloudSyncBatchResult(savedNotes: [savedNote]),
            to: [sentNote],
            pendingDeletionIDs: [],
            sentNotesByID: [sentNote.id: sentNote]
        )
        let mergedNote = try! #require(outcome.notes.first)

        #expect(mergedNote.createdAt == localCreatedAt)
        #expect(mergedNote.needsCloudUpload == false)
        #expect(mergedNote.cloudKitSystemFieldsData == Data([2]))
    }

    @Test func syncApplyDoesNotRequeuePurelyLocalWindowChangesMadeAfterSaveWasSent() {
        let sentNote = StickyNote(
            id: "shared-note",
            content: "Draft",
            color: .yellow,
            createdAt: Date(timeIntervalSince1970: 10),
            lastModified: Date(timeIntervalSince1970: 20),
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: true,
            cloudKitSystemFieldsData: Data([1])
        )
        let locallyMovedNote = StickyNote(
            id: sentNote.id,
            content: sentNote.content,
            color: .yellow,
            createdAt: sentNote.createdAt,
            lastModified: sentNote.lastModified,
            isOpen: false,
            preferredFrame: StickyNoteFrame(x: 40, y: 60, width: 320, height: 280),
            needsCloudUpload: true,
            cloudKitSystemFieldsData: sentNote.cloudKitSystemFieldsData
        )
        let savedNote = StickyNote(
            id: sentNote.id,
            content: sentNote.content,
            color: .yellow,
            createdAt: sentNote.createdAt,
            lastModified: sentNote.lastModified,
            isOpen: true,
            preferredFrame: nil,
            needsCloudUpload: false,
            cloudKitSystemFieldsData: Data([2])
        )

        let outcome = StickyNotesMergeEngine.apply(
            syncResult: CloudSyncBatchResult(savedNotes: [savedNote]),
            to: [locallyMovedNote],
            pendingDeletionIDs: [],
            sentNotesByID: [sentNote.id: sentNote]
        )
        let mergedNote = try! #require(outcome.notes.first)

        #expect(mergedNote.isOpen == false)
        #expect(mergedNote.preferredFrame == locallyMovedNote.preferredFrame)
        #expect(mergedNote.needsCloudUpload == false)
        #expect(mergedNote.cloudKitSystemFieldsData == Data([2]))
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
            minimumVerticalInset: 12
        )

        #expect(verticalInset == 186)
    }

    @Test func stickyTextLayoutAccountsForTopWindowControlBar() {
        let verticalInset = StickyTextEditorLayout.centeredVerticalInset(
            availableHeight: 400,
            contentHeight: 28,
            minimumVerticalInset: 12,
            topControlBarHeight: 28
        )

        #expect(verticalInset == 172)
    }

    @Test func stickyTextLayoutFallsBackToMinimumInsetForTallContent() {
        let verticalInset = StickyTextEditorLayout.centeredVerticalInset(
            availableHeight: 140,
            contentHeight: 120,
            minimumVerticalInset: 12
        )

        #expect(verticalInset == 12)
    }

    @Test func stickyNoteCardLayoutMatchesDashboardGridWidth() {
        let cardWidth = StickyNoteCardLayout.cardWidth(for: 390)

        #expect(cardWidth == 177)
    }

    @Test func stickyNotePaperHitRegionUsesRoundedPaperShape() {
        let rect = CGRect(x: 0, y: 0, width: 280, height: 280)

        #expect(StickyNotePaperHitRegion.contains(CGPoint(x: 140, y: 140), in: rect))
        #expect(StickyNotePaperHitRegion.contains(CGPoint(x: 272, y: 272), in: rect))
        #expect(!StickyNotePaperHitRegion.contains(CGPoint(x: 279, y: 279), in: rect))
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
    @Test func automaticSyncSchedulerRunsImmediateSyncAndCoalescesThrottledRequests() async {
        var now = Date(timeIntervalSince1970: 0)
        var syncedReasons: [StickyNotesAutomaticSyncReason] = []
        let delayedTaskScheduler = TestDelayedTaskScheduler()

        let scheduler = StickyNotesAutomaticSyncScheduler(
            minimumSyncInterval: 10,
            now: { now },
            delayedTaskScheduler: delayedTaskScheduler,
            syncOperation: { reason in
                syncedReasons.append(reason)
            }
        )

        await scheduler.requestSync(reason: .appActivation)
        now = Date(timeIntervalSince1970: 1)
        await scheduler.requestSync(reason: .systemWake)
        now = Date(timeIntervalSince1970: 2)
        await scheduler.requestSync(reason: .networkRestored)

        #expect(syncedReasons == [.appActivation])
        #expect(delayedTaskScheduler.timeIntervalDelays == [9])
        #expect(delayedTaskScheduler.pendingOperationCount == 1)

        now = Date(timeIntervalSince1970: 10)
        await delayedTaskScheduler.runNext()

        #expect(syncedReasons == [.appActivation, .networkRestored])
    }

    @Test func automaticSyncSchedulerStopCancelsDeferredSync() async {
        var now = Date(timeIntervalSince1970: 0)
        var syncedReasons: [StickyNotesAutomaticSyncReason] = []
        let delayedTaskScheduler = TestDelayedTaskScheduler()

        let scheduler = StickyNotesAutomaticSyncScheduler(
            minimumSyncInterval: 10,
            now: { now },
            delayedTaskScheduler: delayedTaskScheduler,
            syncOperation: { reason in
                syncedReasons.append(reason)
            }
        )

        await scheduler.requestSync(reason: .appActivation)
        now = Date(timeIntervalSince1970: 1)
        await scheduler.requestSync(reason: .periodicPoll)
        scheduler.stop()

        #expect(syncedReasons == [.appActivation])
        #expect(delayedTaskScheduler.cancelledOperationCount == 1)
    }

    @Test func automaticSyncSchedulerDrainsRequestReceivedDuringInFlightSync() async {
        var now = Date(timeIntervalSince1970: 0)
        var syncedReasons: [StickyNotesAutomaticSyncReason] = []
        var syncCountObservedDuringFirstSync = 0
        var scheduler: StickyNotesAutomaticSyncScheduler?

        scheduler = StickyNotesAutomaticSyncScheduler(
            minimumSyncInterval: 10,
            now: { now },
            syncOperation: { reason in
                syncedReasons.append(reason)

                if reason == .appActivation {
                    now = Date(timeIntervalSince1970: 11)
                    await scheduler?.requestSync(reason: .networkRestored)
                    syncCountObservedDuringFirstSync = syncedReasons.count
                }
            }
        )

        await scheduler?.requestSync(reason: .appActivation)

        #expect(syncCountObservedDuringFirstSync == 1)
        #expect(syncedReasons == [.appActivation, .networkRestored])
    }

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

    @Test func windowFrameControllerPersistsLocalMoveThroughDelayedScheduler() async {
        var currentFrame = NSRect(x: 280, y: 360, width: 280, height: 280)
        var persistedFrames: [StickyNoteFrame] = []
        let delayedTaskScheduler = TestDelayedTaskScheduler()
        let controller = StickyNoteWindowFrameController(
            readCurrentFrame: { currentFrame },
            applyFrame: { currentFrame = $0 },
            readPersistedFrame: { persistedFrames.last },
            persistFrame: { persistedFrames.append($0) },
            delayedTaskScheduler: delayedTaskScheduler
        )

        controller.windowDidMove()

        #expect(persistedFrames.isEmpty)
        #expect(delayedTaskScheduler.timeIntervalDelays == [0.15])

        await delayedTaskScheduler.runAll()

        #expect(persistedFrames == [
            StickyNoteFrame(x: 280, y: 360, width: 280, height: 280),
        ])
    }

    @Test func stickyWindowButtonLayoutPlacesOriginsInsideDefaultContentBounds() {
        let contentBounds = CGRect(x: 0, y: 0, width: 280, height: 280)
        let buttonSizes = Array(repeating: CGSize(width: 14, height: 14), count: 3)
        let origins = StickyNoteWindowButtonLayout.origins(
            forButtonSizes: buttonSizes,
            inContentBounds: contentBounds,
            isContentViewFlipped: true
        )

        for (origin, size) in zip(origins, buttonSizes) {
            let buttonFrame = CGRect(origin: origin, size: size)
            #expect(contentBounds.contains(buttonFrame))
        }
    }

    @Test func stickyWindowButtonLayoutKeepsButtonCentersInsidePaperHitRegion() {
        let contentBounds = CGRect(x: 0, y: 0, width: 280, height: 280)
        let buttonSizes = Array(repeating: CGSize(width: 14, height: 14), count: 3)
        let origins = StickyNoteWindowButtonLayout.origins(
            forButtonSizes: buttonSizes,
            inContentBounds: contentBounds,
            isContentViewFlipped: true
        )

        for (origin, size) in zip(origins, buttonSizes) {
            let center = CGPoint(
                x: origin.x + (size.width / 2),
                y: origin.y + (size.height / 2)
            )
            #expect(StickyNotePaperHitRegion.contains(center, in: contentBounds))
        }
    }

    @Test func stickyWindowButtonLayoutUsesVisualTopLeftForFlippedAndUnflippedContent() throws {
        let contentBounds = CGRect(x: 0, y: 0, width: 280, height: 280)
        let buttonSizes = Array(repeating: CGSize(width: 14, height: 14), count: 3)
        let flippedOrigins = StickyNoteWindowButtonLayout.origins(
            forButtonSizes: buttonSizes,
            inContentBounds: contentBounds,
            isContentViewFlipped: true
        )
        let unflippedOrigins = StickyNoteWindowButtonLayout.origins(
            forButtonSizes: buttonSizes,
            inContentBounds: contentBounds,
            isContentViewFlipped: false
        )
        let flippedFirstOrigin = try #require(flippedOrigins.first)
        let unflippedFirstOrigin = try #require(unflippedOrigins.first)

        #expect(flippedFirstOrigin.x == StickyNoteWindowButtonLayout.leadingInset)
        #expect(flippedFirstOrigin.y == StickyNoteWindowButtonLayout.topInset)
        #expect(unflippedFirstOrigin.x == StickyNoteWindowButtonLayout.leadingInset)
        #expect(unflippedFirstOrigin.y == contentBounds.maxY - StickyNoteWindowButtonLayout.topInset - buttonSizes[0].height)
        #expect(flippedOrigins.map(\.x) == unflippedOrigins.map(\.x))
    }

    @Test func stickyWindowPairLayoutPlacesNewWindowToRightAndBottomAligned() {
        let anchorFrame = NSRect(x: 100, y: 140, width: 240, height: 180)
        let newFrame = NSRect(x: 0, y: 0, width: 180, height: 120)
        let tiledFrame = StickyNoteWindowPairLayout.tiledFrame(
            for: newFrame,
            anchoredTo: anchorFrame,
            avoiding: [anchorFrame],
            in: NSRect(x: 0, y: 0, width: 1_000, height: 700)
        )

        #expect(tiledFrame == NSRect(x: 356, y: 140, width: 180, height: 120))
        #expect(tiledFrame.minX - anchorFrame.maxX == StickyNoteWindowPairLayout.defaultGap)
        #expect(tiledFrame.minY == anchorFrame.minY)
        #expect(tiledFrame.size == newFrame.size)
    }

    @Test func stickyWindowPairLayoutKeepsBottomAlignmentWithinVisibleBounds() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 800, height: 500)
        let anchorFrame = NSRect(x: 100, y: -40, width: 200, height: 180)
        let tiledFrame = StickyNoteWindowPairLayout.tiledFrame(
            for: NSRect(x: 0, y: 0, width: 180, height: 120),
            anchoredTo: anchorFrame,
            avoiding: [anchorFrame],
            in: visibleFrame
        )

        #expect(tiledFrame == NSRect(x: 316, y: 0, width: 180, height: 120))
        #expect(tiledFrame.minX >= visibleFrame.minX)
        #expect(tiledFrame.maxX <= visibleFrame.maxX)
        #expect(tiledFrame.minY >= visibleFrame.minY)
        #expect(tiledFrame.maxY <= visibleFrame.maxY)
    }

    @Test func stickyWindowPairLayoutAvoidsOccupiedPreferredPosition() {
        let anchorFrame = NSRect(x: 100, y: 100, width: 200, height: 150)
        let blockingFrame = NSRect(x: 316, y: 100, width: 180, height: 120)
        let tiledFrame = StickyNoteWindowPairLayout.tiledFrame(
            for: NSRect(x: 0, y: 0, width: 180, height: 120),
            anchoredTo: anchorFrame,
            avoiding: [anchorFrame, blockingFrame],
            in: NSRect(x: 0, y: 0, width: 1_000, height: 700)
        )

        #expect(tiledFrame == NSRect(x: 316, y: 236, width: 180, height: 120))
        #expect(framesRespectGap([anchorFrame, blockingFrame, tiledFrame], gap: 16))
    }

    @Test func stickyWindowPairLayoutAvoidsOverlapWithZeroGap() {
        let anchorFrame = NSRect(x: 100, y: 100, width: 200, height: 150)
        let blockingFrame = NSRect(x: 300, y: 100, width: 180, height: 120)
        let tiledFrame = StickyNoteWindowPairLayout.tiledFrame(
            for: NSRect(x: 0, y: 0, width: 180, height: 120),
            anchoredTo: anchorFrame,
            avoiding: [anchorFrame, blockingFrame],
            in: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            gap: 0
        )

        #expect(!tiledFrame.intersects(anchorFrame))
        #expect(!tiledFrame.intersects(blockingFrame))
    }

    @Test func stickyWindowPairLayoutWrapsToNearestOpenSlotAtScreenEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let anchorFrame = NSRect(x: 450, y: 200, width: 200, height: 150)
        let tiledFrame = StickyNoteWindowPairLayout.tiledFrame(
            for: NSRect(x: 0, y: 0, width: 180, height: 120),
            anchoredTo: anchorFrame,
            avoiding: [anchorFrame],
            in: visibleFrame
        )

        #expect(tiledFrame == NSRect(x: 520, y: 64, width: 180, height: 120))
        #expect(tiledFrame.minX >= visibleFrame.minX)
        #expect(tiledFrame.maxX <= visibleFrame.maxX)
        #expect(tiledFrame.minY >= visibleFrame.minY)
        #expect(tiledFrame.maxY <= visibleFrame.maxY)
        #expect(framesRespectGap([anchorFrame, tiledFrame], gap: 16))
    }

    @Test func stickyWindowPairLayoutClampsWhenNoOpenSlotExists() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 300, height: 200)
        let anchorFrame = visibleFrame
        let tiledFrame = StickyNoteWindowPairLayout.tiledFrame(
            for: NSRect(x: 0, y: 0, width: 100, height: 100),
            anchoredTo: anchorFrame,
            avoiding: [anchorFrame],
            in: visibleFrame
        )

        #expect(tiledFrame == NSRect(x: 200, y: 0, width: 100, height: 100))
        #expect(tiledFrame.intersects(anchorFrame))
    }

    @Test func stickyWindowGridLayoutReturnsNoFramesForNoWindows() {
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: [],
            in: NSRect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(tiledFrames.isEmpty)
    }

    @Test func stickyWindowGridLayoutKeepsSingleWindowWithinVisibleBounds() throws {
        let visibleFrame = NSRect(x: 40, y: 60, width: 400, height: 300)
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: [NSRect(x: 900, y: 900, width: 180, height: 120)],
            in: visibleFrame
        )
        let frame = try #require(tiledFrames.first)

        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
        #expect(frame.size == CGSize(width: 180, height: 120))
    }

    @Test func stickyWindowGridLayoutTilesLeftToRightThenTopToBottom() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 900, height: 700)
        let currentFrames = Array(
            repeating: NSRect(x: 0, y: 0, width: 200, height: 100),
            count: 4
        )
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: currentFrames,
            in: visibleFrame,
            gap: 16
        )

        #expect(tiledFrames.map(\.origin) == [
            CGPoint(x: 100, y: 650),
            CGPoint(x: 316, y: 650),
            CGPoint(x: 100, y: 534),
            CGPoint(x: 316, y: 534),
        ])
    }

    @Test func stickyWindowGridLayoutPreservesEachWindowSize() {
        let currentFrames = [
            NSRect(x: 0, y: 0, width: 180, height: 140),
            NSRect(x: 0, y: 0, width: 260, height: 220),
            NSRect(x: 0, y: 0, width: 210, height: 160),
        ]
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: currentFrames,
            in: NSRect(x: 0, y: 0, width: 900, height: 700)
        )

        #expect(tiledFrames.map(\.size) == currentFrames.map(\.size))
    }

    @Test func stickyWindowGridLayoutClampsOriginsIntoVisibleBounds() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 500, height: 500)
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: Array(repeating: NSRect(x: 0, y: 0, width: 280, height: 280), count: 4),
            in: visibleFrame,
            gap: 16
        )

        #expect(tiledFrames.allSatisfy { frame in
            frame.minX >= visibleFrame.minX
                && frame.maxX <= visibleFrame.maxX
                && frame.minY >= visibleFrame.minY
                && frame.maxY <= visibleFrame.maxY
        })
    }

    @Test func stickyWindowGridLayoutUsesAvailableScreenToAvoidOverlaps() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 700)
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: Array(repeating: NSRect(x: 0, y: 0, width: 280, height: 280), count: 8),
            in: visibleFrame,
            gap: 16
        )

        #expect(tiledFrames.allSatisfy { frame in
            frame.minX >= visibleFrame.minX
                && frame.maxX <= visibleFrame.maxX
                && frame.minY >= visibleFrame.minY
                && frame.maxY <= visibleFrame.maxY
        })
        #expect(framesDoNotOverlap(tiledFrames))
    }

    @Test func stickyWindowGridLayoutUsesActualWidthsWhenSelectingColumns() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 600)
        let currentFrames = [
            NSRect(x: 0, y: 0, width: 1_000, height: 280),
            NSRect(x: 0, y: 0, width: 220, height: 280),
            NSRect(x: 0, y: 0, width: 220, height: 280),
        ]
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: currentFrames,
            in: visibleFrame,
            gap: 16
        )

        #expect(tiledFrames.allSatisfy { frame in
            frame.minX >= visibleFrame.minX
                && frame.maxX <= visibleFrame.maxX
                && frame.minY >= visibleFrame.minY
                && frame.maxY <= visibleFrame.maxY
        })
        #expect(framesDoNotOverlap(tiledFrames))
    }

    @Test func stickyWindowGridLayoutRejectsCandidatesThatViolateGap() {
        let gap: CGFloat = 16
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let currentFrames = [
            NSRect(x: 0, y: 0, width: 1_000, height: 280),
            NSRect(x: 0, y: 0, width: 220, height: 280),
            NSRect(x: 0, y: 0, width: 200, height: 280),
            NSRect(x: 0, y: 0, width: 200, height: 280),
            NSRect(x: 0, y: 0, width: 200, height: 280),
        ]
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: currentFrames,
            in: visibleFrame,
            gap: gap
        )

        #expect(tiledFrames.allSatisfy { frame in
            frame.minX >= visibleFrame.minX
                && frame.maxX <= visibleFrame.maxX
                && frame.minY >= visibleFrame.minY
                && frame.maxY <= visibleFrame.maxY
        })
        #expect(framesRespectGap(tiledFrames, gap: gap))
    }

    @Test func stickyWindowGridLayoutFallsBackToNonOverlappingLayoutWhenGapCannotFit() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 100, height: 200)
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: Array(repeating: NSRect(x: 0, y: 0, width: 100, height: 100), count: 2),
            in: visibleFrame,
            gap: 16
        )

        #expect(tiledFrames.allSatisfy { frame in
            frame.minX >= visibleFrame.minX
                && frame.maxX <= visibleFrame.maxX
                && frame.minY >= visibleFrame.minY
                && frame.maxY <= visibleFrame.maxY
        })
        #expect(framesDoNotOverlap(tiledFrames))
    }

    @Test func stickyWindowGridLayoutUsesGaplessCellSizeForFallbackRows() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 100, height: 300)
        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: Array(repeating: NSRect(x: 0, y: 0, width: 100, height: 100), count: 3),
            in: visibleFrame,
            gap: 16
        )

        #expect(tiledFrames.map(\.origin) == [
            CGPoint(x: 0, y: 200),
            CGPoint(x: 0, y: 100),
            CGPoint(x: 0, y: 0),
        ])
        #expect(framesDoNotOverlap(tiledFrames))
    }

    private func framesDoNotOverlap(_ frames: [NSRect]) -> Bool {
        for firstIndex in frames.indices {
            for secondIndex in frames.index(after: firstIndex)..<frames.endIndex {
                if frames[firstIndex].intersects(frames[secondIndex]) {
                    return false
                }
            }
        }

        return true
    }

    private func framesRespectGap(_ frames: [NSRect], gap: CGFloat) -> Bool {
        for firstIndex in frames.indices {
            for secondIndex in frames.index(after: firstIndex)..<frames.endIndex {
                let horizontalGap = max(
                    frames[secondIndex].minX - frames[firstIndex].maxX,
                    frames[firstIndex].minX - frames[secondIndex].maxX,
                    0
                )
                let verticalGap = max(
                    frames[secondIndex].minY - frames[firstIndex].maxY,
                    frames[firstIndex].minY - frames[secondIndex].maxY,
                    0
                )

                if horizontalGap < gap && verticalGap < gap {
                    return false
                }
            }
        }

        return true
    }
#endif
}

@MainActor
private final class TestDelayedTaskScheduler: StickyNotesDelayedTaskScheduling {
    private final class CancellationState {
        var isCancelled = false
    }

    private struct ScheduledOperation {
        var delay: StickyNotesDelay
        var operation: @MainActor () async -> Void
        var cancellationState: CancellationState
    }

    private var scheduledOperations: [ScheduledOperation] = []

    var cancelledOperationCount: Int {
        scheduledOperations.filter(\.cancellationState.isCancelled).count
    }

    var pendingOperationCount: Int {
        scheduledOperations.filter { !$0.cancellationState.isCancelled }.count
    }

    var timeIntervalDelays: [TimeInterval] {
        scheduledOperations.compactMap { scheduledOperation in
            guard case let .timeInterval(delay) = scheduledOperation.delay else {
                return nil
            }

            return delay
        }
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask {
        schedule(after: .timeInterval(delay), operation: operation)
    }

    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask {
        schedule(after: .duration(delay), operation: operation)
    }

    func runNext() async {
        while !scheduledOperations.isEmpty {
            let scheduledOperation = scheduledOperations.removeFirst()
            guard !scheduledOperation.cancellationState.isCancelled else { continue }
            await scheduledOperation.operation()
            return
        }
    }

    func runAll() async {
        while pendingOperationCount > 0 {
            await runNext()
        }
    }

    private func schedule(
        after delay: StickyNotesDelay,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask {
        let cancellationState = CancellationState()
        scheduledOperations.append(
            ScheduledOperation(
                delay: delay,
                operation: operation,
                cancellationState: cancellationState
            )
        )

        return StickyNotesDelayedTask { [weak cancellationState] in
            guard let cancellationState, !cancellationState.isCancelled else { return }
            cancellationState.isCancelled = true
        }
    }
}

private actor MockCloudService: StickyNotesCloudSyncing {
    private var remoteNotesByID: [String: StickyNote]
    private var deletedIDs: [String] = []
    private let remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness
    private let fetchDelay: Duration
    private let stateSerializationDelays: [Duration]
    private let currentStateSerializationData: Data?
    private var fetchCallCount = 0
    private var stateSerializationCallCount = 0
    private var restoredPersistedState = StickyNotesCloudPersistedState()

    init(
        remoteNotes: [StickyNote] = [],
        remoteSnapshotCompleteness: CloudRemoteSnapshotCompleteness = .complete,
        fetchDelay: Duration = .zero,
        stateSerializationDelays: [Duration] = [],
        currentStateSerializationData: Data? = nil
    ) {
        remoteNotesByID = Dictionary(uniqueKeysWithValues: remoteNotes.map { ($0.id, $0.markedClean()) })
        self.remoteSnapshotCompleteness = remoteSnapshotCompleteness
        self.fetchDelay = fetchDelay
        self.stateSerializationDelays = stateSerializationDelays
        self.currentStateSerializationData = currentStateSerializationData
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        fetchCallCount += 1
        try? await Task.sleep(for: fetchDelay)
        return CloudRemoteSnapshot(notes: Array(remoteNotesByID.values), completeness: remoteSnapshotCompleteness)
    }

    func restore(persistedState: StickyNotesCloudPersistedState) async {
        restoredPersistedState = persistedState
    }

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        let currentCall = stateSerializationCallCount
        stateSerializationCallCount += 1

        if currentCall < stateSerializationDelays.count {
            try? await Task.sleep(for: stateSerializationDelays[currentCall])
        }

        return StickyNotesCloudPersistedState(
            stateSerializationData: currentStateSerializationData,
            accountIdentifier: restoredPersistedState.accountIdentifier,
            remoteNotes: Array(remoteNotesByID.values)
        )
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

    func fetchCount() -> Int {
        fetchCallCount
    }
}

private actor FailingFirstSendCloudService: StickyNotesCloudSyncing {
    private var remoteNotesByID: [String: StickyNote] = [:]
    private var sendCallCount = 0
    private let firstSendDelay: Duration

    init(firstSendDelay: Duration) {
        self.firstSendDelay = firstSendDelay
    }

    func restore(persistedState: StickyNotesCloudPersistedState) async {
        remoteNotesByID = Dictionary(uniqueKeysWithValues: persistedState.remoteNotes.map {
            ($0.id, $0.markedClean())
        })
    }

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        StickyNotesCloudPersistedState(remoteNotes: Array(remoteNotesByID.values))
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        .complete(notes: Array(remoteNotesByID.values))
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        sendCallCount += 1
        if sendCallCount == 1 {
            try? await Task.sleep(for: firstSendDelay)
            return CloudSyncBatchResult(failureMessage: "First send failed")
        }

        var result = CloudSyncBatchResult()
        for note in saves {
            let cleanNote = note.markedClean()
            remoteNotesByID[note.id] = cleanNote
            result.savedNotes.append(cleanNote)
        }
        for noteID in deletions {
            remoteNotesByID.removeValue(forKey: noteID)
            result.deletedNoteIDs.append(noteID)
        }
        return result
    }

    func sendCount() -> Int {
        sendCallCount
    }

    func snapshot() -> [StickyNote] {
        Array(remoteNotesByID.values)
    }
}

private actor PermanentlyRejectingCloudService: StickyNotesCloudSyncing {
    private var attemptedSaveCount = 0

    func restore(persistedState: StickyNotesCloudPersistedState) async {}

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        StickyNotesCloudPersistedState()
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        .complete(notes: [])
    }

    func syncChanges(saves: [StickyNote], deletions: [String]) async -> CloudSyncBatchResult {
        attemptedSaveCount += saves.count
        guard !saves.isEmpty else { return CloudSyncBatchResult() }

        return CloudSyncBatchResult(
            permanentlyRejectedSaveNoteIDs: saves.map(\.id),
            failureMessage: "CloudKit permanently rejected the record."
        )
    }

    func saveAttemptCount() -> Int {
        attemptedSaveCount
    }
}

private actor SnapshotReadingCloudService: StickyNotesCloudSyncing {
    private let fileStore: StickyNotesFileStore
    private var observedContentsAtFetch: [[String]] = []
    private var remoteNotesByID: [String: StickyNote] = [:]

    init(fileURL: URL) {
        fileStore = StickyNotesFileStore(fileURL: fileURL)
    }

    func restore(persistedState: StickyNotesCloudPersistedState) async {
        remoteNotesByID = Dictionary(uniqueKeysWithValues: persistedState.remoteNotes.map {
            ($0.id, $0.markedClean())
        })
    }

    func currentPersistedState() async -> StickyNotesCloudPersistedState {
        StickyNotesCloudPersistedState(remoteNotes: Array(remoteNotesByID.values))
    }

    func fetchAllNotes() async throws -> CloudRemoteSnapshot {
        let snapshot = try await fileStore.load()
        observedContentsAtFetch.append(snapshot.notes.map(\.content))
        return CloudRemoteSnapshot.complete(notes: Array(remoteNotesByID.values))
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
            result.deletedNoteIDs.append(id)
        }

        return result
    }

    func persistedContentsAtFetch() -> [[String]] {
        observedContentsAtFetch
    }
}

private func temporaryStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("sticky-notes.json", isDirectory: false)
}

private func makeCloudKitError(
    _ code: CKError.Code,
    userInfo: [String: Any] = [:]
) -> CKError {
    CKError(
        _nsError: NSError(
            domain: CKError.errorDomain,
            code: code.rawValue,
            userInfo: userInfo
        )
    )
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
