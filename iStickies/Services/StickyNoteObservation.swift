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
