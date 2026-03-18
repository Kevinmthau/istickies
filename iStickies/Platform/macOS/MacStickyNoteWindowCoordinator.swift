#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class MacStickyNoteWindowCoordinator: ObservableObject {
    private let store: StickyNotesStore
    private var windows: [String: StickyNoteWindow] = [:]
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
        bringAllWindowsToFront(prioritizing: store.notes.first?.id)
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
                    }
                ) { [weak self] noteID in
                    self?.windows.removeValue(forKey: noteID)
                }

                windows[note.id] = window
                window.makeKeyAndOrderFront(nil)
            }
        }

        for (id, window) in windows where notesByID[id]?.isOpen != true {
            window.closeFromCoordinator()
        }
    }

    private func bringAllWindowsToFront(prioritizing prioritizedNoteID: String?) {
        guard !isBringingWindowsToFront else { return }

        let orderedWindows = store.notes.compactMap { windows[$0.id] }
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
}

private final class StickyNoteWindow: NSWindow, NSWindowDelegate {
    private static let defaultContentSize = CGSize(width: 280, height: 280)
    private static let minimumContentSize = CGSize(width: 220, height: 220)
    private static let localFramePersistenceDelay: TimeInterval = 0.15

    let noteID: String

    private let store: StickyNotesStore
    private let onActivate: (String) -> Void
    private let onClose: (String) -> Void
    private var isPresentingDeleteConfirmation = false
    private var isClosingFromCoordinator = false
    private var isClosingForApplicationTermination = false
    private var isApplyingModelFrame = false
    private var isLocallyMovingWindow = false
    private var lastLocalFrameReportDate: Date?
    private var pendingLocalFrame: StickyNoteFrame?
    private var localFramePersistenceTask: Task<Void, Never>?
    private var pendingModelFrame: NSRect?
    private var pendingModelFrameTask: Task<Void, Never>?
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
            self?.flushPendingLocalFramePersistence()
            self?.isClosingForApplicationTermination = true
        }

        apply(note: note, forceFrame: true)
    }

    deinit {
        localFramePersistenceTask?.cancel()
        pendingModelFrameTask?.cancel()

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

        guard StickyNoteWindowFrameSync.shouldApplyModelFrame(
            currentFrame: frame,
            targetFrame: targetFrame,
            lastLocalFrameReportDate: lastLocalFrameReportDate,
            isLocalMoveActive: isLocallyMovingWindow,
            forceFrame: forceFrame
        ) else {
            if forceFrame || frame.distanceSquared(to: targetFrame) <= 9 {
                clearPendingModelFrame()
            } else if isLocallyMovingWindow {
                holdPendingModelFrame(targetFrame)
            } else if let delay = StickyNoteWindowFrameSync.suppressionDelay(
                lastLocalFrameReportDate: lastLocalFrameReportDate
            ) {
                schedulePendingModelFrame(targetFrame, after: delay)
            }
            return
        }

        clearPendingModelFrame()
        isApplyingModelFrame = true
        defer { isApplyingModelFrame = false }

        if forceFrame || frame.distanceSquared(to: targetFrame) > 9 {
            setFrame(targetFrame, display: true, animate: false)
        }
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

    private func schedulePendingModelFrame(_ targetFrame: NSRect, after delay: TimeInterval) {
        pendingModelFrame = targetFrame
        pendingModelFrameTask?.cancel()
        pendingModelFrameTask = Task { @MainActor [weak self] in
            let delay = max(delay, 0)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            self?.applyPendingModelFrameIfNeeded()
        }
    }

    private func holdPendingModelFrame(_ targetFrame: NSRect) {
        pendingModelFrame = targetFrame
        pendingModelFrameTask?.cancel()
        pendingModelFrameTask = nil
    }

    private func applyPendingModelFrameIfNeeded() {
        guard let pendingModelFrame else { return }

        if frame.distanceSquared(to: pendingModelFrame) <= 9 {
            clearPendingModelFrame()
            return
        }

        guard !isLocallyMovingWindow else { return }

        if let delay = StickyNoteWindowFrameSync.suppressionDelay(
            lastLocalFrameReportDate: lastLocalFrameReportDate
        ) {
            schedulePendingModelFrame(pendingModelFrame, after: delay)
            return
        }

        clearPendingModelFrame()
        isApplyingModelFrame = true
        defer { isApplyingModelFrame = false }
        setFrame(pendingModelFrame, display: true, animate: false)
    }

    private func clearPendingModelFrame() {
        pendingModelFrame = nil
        pendingModelFrameTask?.cancel()
        pendingModelFrameTask = nil
    }

    private func beginLocalMoveIfNeeded() {
        guard !isLocallyMovingWindow else { return }

        isLocallyMovingWindow = true
    }

    private func completeLocalMoveIfNeeded() {
        guard isLocallyMovingWindow else { return }

        isLocallyMovingWindow = false

        clearPendingModelFrame()
        flushPendingLocalFramePersistence()
    }

    private func scheduleLocalFramePersistence(after delay: TimeInterval) {
        localFramePersistenceTask?.cancel()
        localFramePersistenceTask = Task { @MainActor [weak self] in
            let delay = max(delay, 0)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            self?.completeLocalMoveIfNeeded()
        }
    }

    private func flushPendingLocalFramePersistence() {
        localFramePersistenceTask?.cancel()
        localFramePersistenceTask = nil

        guard let pendingLocalFrame else { return }
        self.pendingLocalFrame = nil

        if store.note(withID: noteID)?.preferredFrame != pendingLocalFrame {
            store.updatePreferredFrame(id: noteID, frame: pendingLocalFrame)
        }
    }

    func windowWillMove(_ notification: Notification) {
        beginLocalMoveIfNeeded()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isApplyingModelFrame else { return }
        beginLocalMoveIfNeeded()

        lastLocalFrameReportDate = Date()
        pendingLocalFrame = frame.stickyFrame
        scheduleLocalFramePersistence(after: Self.localFramePersistenceDelay)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isApplyingModelFrame else { return }
        lastLocalFrameReportDate = Date()
        pendingLocalFrame = frame.stickyFrame
        flushPendingLocalFramePersistence()
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
        localFramePersistenceTask?.cancel()
        pendingLocalFrame = nil
        onClose(noteID)
        isClosingFromCoordinator = false
        isPresentingDeleteConfirmation = false
        isClosingForApplicationTermination = false
        isLocallyMovingWindow = false
    }
}

enum StickyNoteWindowFrameSync {
    static let staleLocalFrameSuppressionInterval: TimeInterval = 0.5

    static func shouldApplyModelFrame(
        currentFrame: NSRect,
        targetFrame: NSRect,
        lastLocalFrameReportDate: Date?,
        isLocalMoveActive: Bool = false,
        forceFrame: Bool,
        now: Date = Date()
    ) -> Bool {
        if forceFrame {
            return true
        }

        guard currentFrame.distanceSquared(to: targetFrame) > 9 else {
            return false
        }

        guard !isLocalMoveActive else {
            return false
        }

        return suppressionDelay(lastLocalFrameReportDate: lastLocalFrameReportDate, now: now) == nil
    }

    static func suppressionDelay(
        lastLocalFrameReportDate: Date?,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let lastLocalFrameReportDate else {
            return nil
        }

        let elapsed = now.timeIntervalSince(lastLocalFrameReportDate)
        guard elapsed >= 0, elapsed < staleLocalFrameSuppressionInterval else {
            return nil
        }

        return staleLocalFrameSuppressionInterval - elapsed
    }
}

private extension NSRect {
    var stickyFrame: StickyNoteFrame {
        StickyNoteFrame(
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height
        )
    }

    func distanceSquared(to other: NSRect) -> CGFloat {
        let deltaX = origin.x - other.origin.x
        let deltaY = origin.y - other.origin.y
        let deltaWidth = size.width - other.size.width
        let deltaHeight = size.height - other.size.height

        return deltaX * deltaX + deltaY * deltaY + deltaWidth * deltaWidth + deltaHeight * deltaHeight
    }
}
#endif
