//
//  iStickiesTests.swift
//  iStickiesTests
//
//  Created by Kevin Thau on 5/15/25.
//

import CloudKit
import Combine
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

    @Test func cloudKitErrorClassifierClassifiesTerminalFailures() {
        let error = makeCloudKitError(.permissionFailure)

        let saveClassification = CloudKitErrorClassifier.classifyRecordSaveFailure(error)
        let deleteClassification = CloudKitErrorClassifier.classifyRecordDeleteFailure(error)

        #expect(saveClassification.kind == .terminal)
        #expect(saveClassification.serverRecord == nil)
        #expect(deleteClassification.kind == .terminal)
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

    @Test func cloudKitSendBatchTrackerTreatsRetriableSavesAsResolvedForThisBatch() throws {
        var tracker = CloudKitSendBatchTracker()
        let pendingNote = StickyNote(
            id: "pending-note",
            content: "Needs retry",
            needsCloudUpload: true,
            cloudKitSystemFieldsData: nil
        )

        tracker.begin(expectedSaveNoteIDs: [pendingNote.id], expectedDeleteNoteIDs: [])
        tracker.markPendingSaveForRetry(pendingNote)

        let result = tracker.finalize()
        let retryNote = try #require(result.pendingNotesRequiringRetry.first)

        #expect(result.pendingNotesRequiringRetry.count == 1)
        #expect(retryNote.id == pendingNote.id)
        #expect(retryNote.needsCloudUpload)
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
        let session = NoteDraftSession()

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
    @Test func automaticSyncSchedulerRunsImmediateSyncAndCoalescesThrottledRequests() async {
        var now = Date(timeIntervalSince1970: 0)
        var syncedReasons: [StickyNotesAutomaticSyncReason] = []
        var scheduledDelays: [TimeInterval] = []
        var scheduledOperations: [@MainActor () async -> Void] = []

        let scheduler = StickyNotesAutomaticSyncScheduler(
            minimumSyncInterval: 10,
            now: { now },
            scheduleDelayedOperation: { delay, operation in
                scheduledDelays.append(delay)
                scheduledOperations.append(operation)
                return StickyNotesAutomaticSyncScheduledTask(cancel: {})
            },
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
        #expect(scheduledDelays == [9])
        #expect(scheduledOperations.count == 1)

        now = Date(timeIntervalSince1970: 10)
        await scheduledOperations[0]()

        #expect(syncedReasons == [.appActivation, .networkRestored])
    }

    @Test func automaticSyncSchedulerStopCancelsDeferredSync() async {
        var now = Date(timeIntervalSince1970: 0)
        var didCancel = false
        var syncedReasons: [StickyNotesAutomaticSyncReason] = []

        let scheduler = StickyNotesAutomaticSyncScheduler(
            minimumSyncInterval: 10,
            now: { now },
            scheduleDelayedOperation: { _, _ in
                StickyNotesAutomaticSyncScheduledTask(cancel: {
                    didCancel = true
                })
            },
            syncOperation: { reason in
                syncedReasons.append(reason)
            }
        )

        await scheduler.requestSync(reason: .appActivation)
        now = Date(timeIntervalSince1970: 1)
        await scheduler.requestSync(reason: .periodicPoll)
        scheduler.stop()

        #expect(syncedReasons == [.appActivation])
        #expect(didCancel)
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
#endif
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
