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
                DispatchQueue.main.async {
                    self.showError("Failed to Load Notes", message: "Could not fetch notes from iCloud: \(error.localizedDescription)")
                }
            }
        }
    }

    func save(note: StickyNote) {
        let record = note.toRecord()
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .allKeys
        operation.modifyRecordsResultBlock = { result in
            if case .failure(let error) = result {
                DispatchQueue.main.async {
                    self.showError("Failed to Save Note", message: "Could not save note to iCloud: \(error.localizedDescription)")
                }
            }
        }
        database.add(operation)
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

    func deleteNote(id: String) {
        let recordID = CKRecord.ID(recordName: id)
        database.delete(withRecordID: recordID) { _, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.showError("Failed to Delete Note", message: "Could not delete note from iCloud: \(error.localizedDescription)")
                } else {
                    self.notes.removeAll { $0.id == id }
                    if let window = self.windows[id] {
                        window.close()
                    }
                    self.windows.removeValue(forKey: id)
                }
            }
        }
    }

    func deleteCurrentNote() {
        guard let window = NSApp.keyWindow as? StickyNoteWindow else { return }
        deleteNote(id: window.noteID)
    }

    func removeWindow(for noteID: String) {
        windows.removeValue(forKey: noteID)
    }

    func saveAllPendingNotes() {
        for window in windows.values {
            window.saveImmediately()
        }
    }

    func showAllNotes() {
        for note in notes {
            showNoteWindow(for: note)
        }
    }

    func showNoteWindow(for note: StickyNote) {
        if windows[note.id] != nil { return }
        let window = StickyNoteWindow(note: note, onUpdate: { updatedNote in
            if let idx = self.notes.firstIndex(where: { $0.id == updatedNote.id }) {
                self.notes[idx] = updatedNote
                self.update(note: updatedNote)
            }
        }, onClose: { noteID in
            self.removeWindow(for: noteID)
        })
        windows[note.id] = window
        window.makeKeyAndOrderFront(nil)
    }

    private func showError(_ title: String, message: String) {
        // Schedule on next run loop iteration to avoid priority inversion
        // when called from DispatchQueue.main.async after CloudKit callbacks
        RunLoop.main.perform {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}

// MARK: - NoteViewModel
class NoteViewModel: ObservableObject {
    @Published var note: StickyNote
    var onUpdate: (StickyNote) -> Void
    private var debounceTimer: Timer?

    init(note: StickyNote, onUpdate: @escaping (StickyNote) -> Void) {
        self.note = note
        self.onUpdate = onUpdate
    }

    func contentChanged() {
        // Debounce saves - wait 0.5s after last keystroke
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.onUpdate(self.note)
        }
    }

    func saveImmediately() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        onUpdate(note)
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var notesManager = StickyNotesManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Notes are loaded and windows shown by StickyNotesManager
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Save all notes immediately before quit
        notesManager.saveAllPendingNotes()
    }

    func createNote() {
        notesManager.addNote()
    }
}

// MARK: - StickyNoteWindow
class StickyNoteWindow: NSWindow, NSWindowDelegate {
    let noteID: String
    private var viewModel: NoteViewModel
    private var onClose: (String) -> Void
    private var hostingController: NSHostingController<StickyNoteView>

    init(note: StickyNote, onUpdate: @escaping (StickyNote) -> Void, onClose: @escaping (String) -> Void) {
        self.noteID = note.id
        self.viewModel = NoteViewModel(note: note, onUpdate: onUpdate)
        self.onClose = onClose
        let size = NSSize(width: 250, height: 250)
        self.hostingController = NSHostingController(rootView: StickyNoteView(viewModel: viewModel))
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        self.delegate = self
        self.contentView = hostingController.view
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isOpaque = false
        self.backgroundColor = NSColor(calibratedRed: 1, green: 1, blue: 0.7, alpha: 1)
        self.isReleasedWhenClosed = false
        self.level = .normal
        self.center()
    }

    func saveImmediately() {
        viewModel.saveImmediately()
    }

    func windowWillClose(_ notification: Notification) {
        saveImmediately()
        onClose(noteID)
    }
}

// MARK: - StickyNoteView
struct StickyNoteView: View {
    @ObservedObject var viewModel: NoteViewModel

    var body: some View {
        TextEditor(text: $viewModel.note.content)
            .font(.system(size: 16))
            .scrollContentBackground(.hidden)
            .background(Color(red: 1, green: 1, blue: 0.7))
            .frame(minWidth: 100, minHeight: 100)
            .onChange(of: viewModel.note.content) {
                viewModel.note.lastModified = Date()
                viewModel.contentChanged()
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

                Button("Delete Note") {
                    appDelegate.notesManager.deleteCurrentNote()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
            }
        }
    }
}
