#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class MacStickyNoteWindowCoordinator: ObservableObject {
    private let store: StickyNotesStore
    private var windows: [String: StickyNoteWindow] = [:]
    private var windowOrder: [String] = []
    private var cancellables: Set<AnyCancellable> = []
    private var hasPresentedInitialNotes = false
    private var isBringingWindowsToFront = false

    init(store: StickyNotesStore) {
        self.store = store

        store.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] notes in
                self?.syncWindows(with: notes)
            }
            .store(in: &cancellables)

        store.$hasFinishedInitialLoad
            .combineLatest(store.$notes)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasFinishedInitialLoad, notes in
                self?.bootstrapIfNeeded(hasFinishedInitialLoad: hasFinishedInitialLoad, notes: notes)
            }
            .store(in: &cancellables)
    }

    func createAndFocusNote() {
        let id = store.createNote()
        focus(noteID: id)
    }

    func focus(noteID: String) {
        store.openAllNotes()
        syncWindows(with: store.notes)
        bringAllWindowsToFront(prioritizing: noteID)
    }

    func showAllNotes() {
        store.openAllNotes()
        syncWindows(with: store.notes)
        bringAllWindowsToFront(prioritizing: windowOrder.last ?? store.notes.first?.id)
    }

    func deleteFocusedNote() {
        guard let stickyWindow = NSApp.keyWindow as? StickyNoteWindow else { return }
        stickyWindow.requestDeletionConfirmation()
    }

    private func bootstrapIfNeeded(hasFinishedInitialLoad: Bool, notes: [StickyNote]) {
        guard hasFinishedInitialLoad, !hasPresentedInitialNotes else { return }
        hasPresentedInitialNotes = true

        if notes.isEmpty {
            createAndFocusNote()
        } else {
            showAllNotes()
        }
    }

    private func syncWindows(with notes: [StickyNote]) {
        let notesByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0) })

        for note in notes where note.isOpen {
            if let window = windows[note.id] {
                window.apply(note: note)
            } else {
                let offset = CGFloat(windows.count % 8) * 24
                let window = StickyNoteWindow(
                    note: note,
                    store: store,
                    cascadeOffset: offset,
                    onActivate: { [weak self] noteID in
                        self?.bringAllWindowsToFront(prioritizing: noteID)
                    },
                    onClose: { [weak self] noteID in
                        self?.windows.removeValue(forKey: noteID)
                        self?.windowOrder.removeAll { $0 == noteID }
                    }
                )

                windows[note.id] = window
                promoteWindow(note.id)
                window.makeKeyAndOrderFront(nil)
            }
        }

        for (id, window) in windows where notesByID[id]?.isOpen != true {
            window.closeFromCoordinator()
        }
    }

    private func bringAllWindowsToFront(prioritizing prioritizedNoteID: String?) {
        guard !isBringingWindowsToFront else { return }

        if let prioritizedNoteID {
            promoteWindow(prioritizedNoteID)
        }

        let orderedWindows = orderedWindowsForPresentation()
        guard !orderedWindows.isEmpty else { return }

        isBringingWindowsToFront = true
        NSApp.activate(ignoringOtherApps: true)

        for window in orderedWindows where window.noteID != prioritizedNoteID {
            window.orderFront(nil)
        }

        if let prioritizedNoteID, let prioritizedWindow = windows[prioritizedNoteID] {
            if prioritizedWindow.isKeyWindow {
                prioritizedWindow.orderFront(nil)
            } else {
                prioritizedWindow.makeKeyAndOrderFront(nil)
            }
        } else {
            orderedWindows.last?.makeKeyAndOrderFront(nil)
        }

        DispatchQueue.main.async { [weak self] in
            self?.isBringingWindowsToFront = false
        }
    }

    private func promoteWindow(_ noteID: String) {
        windowOrder.removeAll { $0 == noteID }
        windowOrder.append(noteID)
    }

    private func orderedWindowsForPresentation() -> [StickyNoteWindow] {
        let activeIDs = Set(windows.keys)
        windowOrder = windowOrder.filter { activeIDs.contains($0) }

        let missingIDs = store.notes.map(\.id).filter { windows[$0] != nil && !windowOrder.contains($0) }
        windowOrder.append(contentsOf: missingIDs)

        return windowOrder.compactMap { windows[$0] }
    }
}

private final class StickyNoteWindow: NSWindow, NSWindowDelegate {
    private static let defaultContentSize = CGSize(width: 280, height: 280)
    private static let minimumContentSize = CGSize(width: 220, height: 220)

    let noteID: String

    private let store: StickyNotesStore
    private let onActivate: (String) -> Void
    private let onClose: (String) -> Void
    private var isPresentingDeleteConfirmation = false
    private var isClosingFromCoordinator = false
    private var isClosingForApplicationTermination = false
    private lazy var frameController = StickyNoteWindowFrameController(
        readCurrentFrame: { [weak self] in
            self?.frame ?? .zero
        },
        applyFrame: { [weak self] frame in
            self?.setFrame(frame, display: true, animate: false)
        },
        readPersistedFrame: { [weak self] in
            guard let self else { return nil }
            return self.store.note(withID: self.noteID)?.preferredFrame
        },
        persistFrame: { [weak self] frame in
            guard let self else { return }
            self.store.updatePreferredFrame(id: self.noteID, frame: frame)
        }
    )
    private var terminationObserver: NSObjectProtocol?

    init(
        note: StickyNote,
        store: StickyNotesStore,
        cascadeOffset: CGFloat,
        onActivate: @escaping (String) -> Void,
        onClose: @escaping (String) -> Void
    ) {
        self.noteID = note.id
        self.store = store
        self.onActivate = onActivate
        self.onClose = onClose

        let origin = CGPoint(x: 120 + cascadeOffset, y: 520 - cascadeOffset)
        let frame = note.preferredFrame.map {
            Self.clampedFrame(
                NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            )
        } ?? NSRect(origin: origin, size: Self.defaultContentSize)

        let hostingController = NSHostingController(
            rootView: NoteEditorView(noteID: note.id).environmentObject(store)
        )

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        delegate = self
        contentViewController = hostingController
        contentMinSize = Self.minimumContentSize
        minSize = NSSize(width: Self.minimumContentSize.width, height: Self.minimumContentSize.height)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        hasShadow = true
        level = .normal

        if note.preferredFrame == nil {
            setContentSize(Self.defaultContentSize)
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.frameController.flushPendingLocalFramePersistence()
                self?.isClosingForApplicationTermination = true
            }
        }

        apply(note: note, forceFrame: true)
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func apply(note: StickyNote, forceFrame: Bool = false) {
        title = ""
        backgroundColor = StickyNoteColor.yellow.nsColor
        isOpaque = false

        guard let preferredFrame = note.preferredFrame else { return }

        let targetFrame = Self.clampedFrame(NSRect(
            x: preferredFrame.x,
            y: preferredFrame.y,
            width: preferredFrame.width,
            height: preferredFrame.height
        ))

        frameController.applyModelFrame(targetFrame, force: forceFrame)
    }

    func closeFromCoordinator() {
        isClosingFromCoordinator = true
        close()
    }

    func requestDeletionConfirmation() {
        guard !isPresentingDeleteConfirmation, !isClosingFromCoordinator else { return }
        isPresentingDeleteConfirmation = true

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this sticky?"
        alert.informativeText = "Closing a sticky deletes it immediately."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self else { return }
            self.isPresentingDeleteConfirmation = false

            guard response == .alertFirstButtonReturn else { return }
            self.store.deleteNote(id: self.noteID)
        }
    }

    private static func clampedFrame(_ frame: NSRect) -> NSRect {
        NSRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: max(frame.size.width, minimumContentSize.width),
            height: max(frame.size.height, minimumContentSize.height)
        )
    }

    func windowWillMove(_ notification: Notification) {
        frameController.windowWillMove()
    }

    func windowDidMove(_ notification: Notification) {
        frameController.windowDidMove()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        frameController.windowDidEndLiveResize()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !isClosingFromCoordinator, !isClosingForApplicationTermination else { return }
        onActivate(noteID)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingFromCoordinator || isClosingForApplicationTermination {
            return true
        }

        requestDeletionConfirmation()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        frameController.reset()
        onClose(noteID)
        isClosingFromCoordinator = false
        isPresentingDeleteConfirmation = false
        isClosingForApplicationTermination = false
    }
}
#endif
