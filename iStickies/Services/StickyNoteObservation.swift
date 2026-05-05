import Combine
import Foundation

@MainActor
final class StickyNoteObservation: ObservableObject {
    let noteID: String

    @Published private(set) var note: StickyNote?

    init(noteID: String, note: StickyNote?) {
        self.noteID = noteID
        self.note = note
    }

    func update(note: StickyNote?) {
        guard self.note != note else { return }
        self.note = note
    }
}

@MainActor
final class StickyNotesListObservation: ObservableObject {
    @Published private(set) var noteIDs: [String]
    @Published private(set) var openNoteIDs: [String]

    init(noteIDs: [String] = [], openNoteIDs: [String] = []) {
        self.noteIDs = noteIDs
        self.openNoteIDs = openNoteIDs
    }

    func update(noteIDs: [String], openNoteIDs: [String]) {
        if self.noteIDs != noteIDs {
            self.noteIDs = noteIDs
        }

        if self.openNoteIDs != openNoteIDs {
            self.openNoteIDs = openNoteIDs
        }
    }
}

@MainActor
final class StickyNotesStatusObservation: ObservableObject {
    @Published private(set) var syncState: StickyNotesSyncState
    @Published private(set) var lastSuccessfulCloudSync: Date?
    @Published private(set) var hasFinishedInitialLoad: Bool
    @Published private(set) var lastErrorMessage: String?

    init(
        syncState: StickyNotesSyncState = .idle,
        lastSuccessfulCloudSync: Date? = nil,
        hasFinishedInitialLoad: Bool = false,
        lastErrorMessage: String? = nil
    ) {
        self.syncState = syncState
        self.lastSuccessfulCloudSync = lastSuccessfulCloudSync
        self.hasFinishedInitialLoad = hasFinishedInitialLoad
        self.lastErrorMessage = lastErrorMessage
    }

    func update(
        syncState: StickyNotesSyncState,
        lastSuccessfulCloudSync: Date?,
        hasFinishedInitialLoad: Bool,
        lastErrorMessage: String?
    ) {
        if self.syncState != syncState {
            self.syncState = syncState
        }

        if self.lastSuccessfulCloudSync != lastSuccessfulCloudSync {
            self.lastSuccessfulCloudSync = lastSuccessfulCloudSync
        }

        if self.hasFinishedInitialLoad != hasFinishedInitialLoad {
            self.hasFinishedInitialLoad = hasFinishedInitialLoad
        }

        if self.lastErrorMessage != lastErrorMessage {
            self.lastErrorMessage = lastErrorMessage
        }
    }
}
