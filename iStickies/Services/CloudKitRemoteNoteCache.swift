import Foundation

struct CloudKitRemoteNoteCache: Sendable {
    private var notesByID: [String: StickyNote] = [:]

    init(notes: [StickyNote] = []) {
        replaceAll(with: notes)
    }

    var count: Int {
        notesByID.count
    }

    var isEmpty: Bool {
        notesByID.isEmpty
    }

    var notes: [StickyNote] {
        notesByID.values.map { $0.markedClean() }
    }

    func note(withID noteID: String) -> StickyNote? {
        notesByID[noteID]?.markedClean()
    }

    func snapshot(completeness: CloudRemoteSnapshotCompleteness) -> CloudRemoteSnapshot {
        CloudRemoteSnapshot(notes: notes, completeness: completeness)
    }

    mutating func replaceAll(with notes: [StickyNote]) {
        notesByID.removeAll(keepingCapacity: true)
        for note in notes {
            notesByID[note.id] = note.markedClean()
        }
    }

    mutating func upsert(_ note: StickyNote) {
        notesByID[note.id] = note.markedClean()
    }

    mutating func remove(noteID: String) {
        notesByID.removeValue(forKey: noteID)
    }

    mutating func removeAll() {
        notesByID.removeAll()
    }
}
