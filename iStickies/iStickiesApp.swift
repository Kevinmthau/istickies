//
//  iStickiesApp.swift
//  iStickies
//
//  Created by Kevin Thau on 5/15/25.
//

import SwiftUI
import AppKit
import CloudKit

// MARK: - StickyNote Model
struct StickyNote: Identifiable, Equatable {
    let id: String
    var content: String
    var lastModified: Date

    static let recordType = "StickyNote"

    init(id: String = UUID().uuidString, content: String, lastModified: Date = Date()) {
        self.id = id
        self.content = content
        self.lastModified = lastModified
    }

    init?(record: CKRecord) {
        guard let content = record["content"] as? String,
              let lastModified = record["lastModified"] as? Date else { return nil }
        self.id = record.recordID.recordName
        self.content = content
        self.lastModified = lastModified
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: StickyNote.recordType, recordID: CKRecord.ID(recordName: id))
        record["content"] = content as CKRecordValue
        record["lastModified"] = lastModified as CKRecordValue
        return record
    }
}

// MARK: - StickyNotesManager
class StickyNotesManager: ObservableObject {
    @Published var notes: [StickyNote] = []
    private let database = CKContainer.default().privateCloudDatabase
    private var windows: [String: StickyNoteWindow] = [:]

    init() {
        fetchNotes()
    }

    func fetchNotes() {
        let query = CKQuery(recordType: StickyNote.recordType, predicate: NSPredicate(value: true))
        database.fetch(withQuery: query, inZoneWith: nil, desiredKeys: nil, resultsLimit: CKQueryOperation.maximumResults) { result in
            switch result {
            case .success(let (matchedResults, _)):
                let records = matchedResults.compactMap { try? $0.1.get() }
                DispatchQueue.main.async {
                    self.notes = records.compactMap { StickyNote(record: $0) }
                    self.showAllNotes()
                }
            case .failure(let error):
                print("Error fetching notes: \(error)")
            }
        }
    }

    func save(note: StickyNote) {
        let record = note.toRecord()
        database.save(record) { _, error in
            if let error = error {
                print("Error saving note: \(error)")
            }
        }
    }

    func update(note: StickyNote) {
        save(note: note)
    }

    func addNote() {
        let newNote = StickyNote(content: "")
        notes.append(newNote)
        save(note: newNote)
        showNoteWindow(for: newNote)
    }

    func showAllNotes() {
        for note in notes {
            showNoteWindow(for: note)
        }
    }

    func showNoteWindow(for note: StickyNote) {
        if windows[note.id] != nil { return }
        let window = StickyNoteWindow(note: note) { updatedNote in
            if let idx = self.notes.firstIndex(where: { $0.id == updatedNote.id }) {
                self.notes[idx] = updatedNote
                self.update(note: updatedNote)
            }
        }
        windows[note.id] = window
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var notesManager = StickyNotesManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Notes are loaded and windows shown by StickyNotesManager
    }

    func createNote() {
        notesManager.addNote()
    }
}

// MARK: - StickyNoteWindow
class StickyNoteWindow: NSWindow {
    private var note: StickyNote
    private var onUpdate: (StickyNote) -> Void
    private var hostingController: NSHostingController<StickyNoteView>

    init(note: StickyNote, onUpdate: @escaping (StickyNote) -> Void) {
        self.note = note
        self.onUpdate = onUpdate
        let size = NSSize(width: 250, height: 250)
        self.hostingController = NSHostingController(rootView: StickyNoteView(note: note, onUpdate: { _ in }))
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Now safe to use self in closure
        self.hostingController.rootView = StickyNoteView(note: note) { updatedNote in
            self.note = updatedNote
            self.onUpdate(updatedNote)
        }
        self.contentView = hostingController.view
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isOpaque = false
        self.backgroundColor = NSColor(calibratedRed: 1, green: 1, blue: 0.7, alpha: 1)
        self.isReleasedWhenClosed = false
        self.level = .normal
        self.center()
    }
}

// MARK: - StickyNoteView
struct StickyNoteView: View {
    @State var note: StickyNote
    var onUpdate: (StickyNote) -> Void

    var body: some View {
        TextEditor(text: $note.content)
            .font(.system(size: 16))
            .scrollContentBackground(.hidden)
            .background(Color(red: 1, green: 1, blue: 0.7))
            .frame(minWidth: 100, minHeight: 100)
            .onChange(of: note.content) {
                var updatedNote = note
                updatedNote.lastModified = Date()
                onUpdate(updatedNote)
            }
    }
}

@main
struct iStickiesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
        .commands {
            CommandMenu("Stickies") {
                Button("New Note") {
                    appDelegate.createNote()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
