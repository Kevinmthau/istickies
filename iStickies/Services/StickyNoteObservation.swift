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
        assignIfChanged(noteIDs, to: \.noteIDs)
        assignIfChanged(openNoteIDs, to: \.openNoteIDs)
    }

    private func assignIfChanged<Value: Equatable>(
        _ newValue: Value,
        to keyPath: ReferenceWritableKeyPath<StickyNotesListObservation, Value>
    ) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }
}

@MainActor
final class StickyNotesStatusObservation: ObservableObject {
    @Published private(set) var syncState: StickyNotesSyncState
    @Published private(set) var lastSuccessfulCloudSync: Date?
    @Published private(set) var hasFinishedInitialLoad: Bool
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var localRecoveryIssue: StickyNotesLocalRecoveryIssue?

    init(
        syncState: StickyNotesSyncState = .idle,
        lastSuccessfulCloudSync: Date? = nil,
        hasFinishedInitialLoad: Bool = false,
        lastErrorMessage: String? = nil,
        localRecoveryIssue: StickyNotesLocalRecoveryIssue? = nil
    ) {
        self.syncState = syncState
        self.lastSuccessfulCloudSync = lastSuccessfulCloudSync
        self.hasFinishedInitialLoad = hasFinishedInitialLoad
        self.lastErrorMessage = lastErrorMessage
        self.localRecoveryIssue = localRecoveryIssue
    }

    func update(
        syncState: StickyNotesSyncState,
        lastSuccessfulCloudSync: Date?,
        hasFinishedInitialLoad: Bool,
        lastErrorMessage: String?,
        localRecoveryIssue: StickyNotesLocalRecoveryIssue?
    ) {
        assignIfChanged(syncState, to: \.syncState)
        assignIfChanged(lastSuccessfulCloudSync, to: \.lastSuccessfulCloudSync)
        assignIfChanged(hasFinishedInitialLoad, to: \.hasFinishedInitialLoad)
        assignIfChanged(lastErrorMessage, to: \.lastErrorMessage)
        assignIfChanged(localRecoveryIssue, to: \.localRecoveryIssue)
    }

    private func assignIfChanged<Value: Equatable>(
        _ newValue: Value,
        to keyPath: ReferenceWritableKeyPath<StickyNotesStatusObservation, Value>
    ) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }
}
