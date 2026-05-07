#if os(macOS)
import AppKit
import Combine
import SwiftUI

@MainActor
final class MacStickyNoteWindowCoordinator: ObservableObject {
    private let store: StickyNotesStore
    private var windows: [String: StickyNoteWindow] = [:]
    private var windowOrder: [String] = []
    private var recoveryWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var hasPresentedInitialNotes = false
    private var isBringingWindowsToFront = false

    init(store: StickyNotesStore) {
        self.store = store

        store.$openNoteIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] openNoteIDs in
                self?.syncWindows(withOpenNoteIDs: openNoteIDs)
            }
            .store(in: &cancellables)

        store.$hasFinishedInitialLoad
            .combineLatest(store.$noteIDs)
            .receive(on: RunLoop.main)
            .sink { [weak self] hasFinishedInitialLoad, noteIDs in
                self?.bootstrapIfNeeded(
                    hasFinishedInitialLoad: hasFinishedInitialLoad,
                    noteIDs: noteIDs,
                    localRecoveryIssue: self?.store.localRecoveryIssue
                )
            }
            .store(in: &cancellables)

        store.$localRecoveryIssue
            .combineLatest(store.$hasFinishedInitialLoad)
            .receive(on: RunLoop.main)
            .sink { [weak self] issue, hasFinishedInitialLoad in
                guard hasFinishedInitialLoad else { return }
                self?.syncRecoveryWindow(with: issue)
            }
            .store(in: &cancellables)
    }

    func createAndFocusNote() {
        guard store.localRecoveryIssue == nil else { return }
        let id = store.createNote()
        focus(noteID: id)
    }

    func focus(noteID: String) {
        guard store.localRecoveryIssue == nil else { return }
        store.openNote(id: noteID)
        syncWindows(withOpenNoteIDs: store.openNoteIDs)
        bringAllWindowsToFront(prioritizing: noteID)
    }

    func showAllNotes() {
        guard store.localRecoveryIssue == nil else { return }
        store.openAllNotes()
        syncWindows(withOpenNoteIDs: store.openNoteIDs)
        bringAllWindowsToFront(prioritizing: windowOrder.last ?? store.noteIDs.first)
    }

    func tileOpenNotesInGrid() {
        guard store.localRecoveryIssue == nil else { return }

        let orderedWindows = orderedWindowsForPresentation()
        guard !orderedWindows.isEmpty else { return }

        let referenceScreen = (NSApp.keyWindow as? StickyNoteWindow)?.screen
            ?? orderedWindows.first?.screen
            ?? NSScreen.main
        guard let visibleFrame = referenceScreen?.visibleFrame else { return }

        let tiledFrames = StickyNoteWindowGridLayout.tiledFrames(
            for: orderedWindows.map(\.frame),
            in: visibleFrame
        )

        for (window, frame) in zip(orderedWindows, tiledFrames) {
            window.applyTiledFrame(frame)
        }
    }

    func deleteFocusedNote() {
        guard store.localRecoveryIssue == nil else { return }
        guard let stickyWindow = NSApp.keyWindow as? StickyNoteWindow else { return }
        stickyWindow.requestDeletionConfirmation()
    }

    private func bootstrapIfNeeded(
        hasFinishedInitialLoad: Bool,
        noteIDs: [String],
        localRecoveryIssue: StickyNotesLocalRecoveryIssue?
    ) {
        guard hasFinishedInitialLoad, !hasPresentedInitialNotes else { return }
        guard localRecoveryIssue == nil else { return }
        hasPresentedInitialNotes = true

        if noteIDs.isEmpty {
            createAndFocusNote()
        } else {
            showAllNotes()
        }
    }

    private func syncRecoveryWindow(with issue: StickyNotesLocalRecoveryIssue?) {
        guard let issue else {
            if let recoveryWindow {
                recoveryWindow.close()
                self.recoveryWindow = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bootstrapIfNeeded(
                    hasFinishedInitialLoad: self.store.hasFinishedInitialLoad,
                    noteIDs: self.store.noteIDs,
                    localRecoveryIssue: self.store.localRecoveryIssue
                )
            }
            return
        }

        let recoveryView = StickyNotesLocalRecoveryView(issue: issue) { [store] in
            Task { await store.startFreshAfterLocalSnapshotFailure() }
        }

        if let recoveryWindow {
            recoveryWindow.contentViewController = NSHostingController(rootView: recoveryView)
            recoveryWindow.makeKeyAndOrderFront(nil)
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                styleMask: [.titled, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = "iStickies Recovery"
            window.contentViewController = NSHostingController(rootView: recoveryView)
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("StickyNotes.localRecoveryWindow")
            recoveryWindow = window
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func syncWindows(withOpenNoteIDs openNoteIDs: [String]) {
        guard store.localRecoveryIssue == nil else { return }
        let openNoteIDSet = Set(openNoteIDs)

        for noteID in openNoteIDs where windows[noteID] == nil {
            guard let note = store.note(withID: noteID) else { continue }

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

            windows[noteID] = window
            promoteWindow(noteID)
            window.makeKeyAndOrderFront(nil)
        }

        let windowsToClose = windows.filter { id, _ in
            !openNoteIDSet.contains(id)
        }

        for (_, window) in windowsToClose {
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

        let missingIDs = store.noteIDs.filter { windows[$0] != nil && !windowOrder.contains($0) }
        windowOrder.append(contentsOf: missingIDs)

        return windowOrder.compactMap { windows[$0] }
    }
}

private final class StickyNoteWindow: NSWindow, NSWindowDelegate {
    private static let defaultContentSize = CGSize(width: 280, height: 280)
    private static let minimumContentSize = CGSize(width: 220, height: 220)

    let noteID: String

    private let store: StickyNotesStore
    private let noteObservation: StickyNoteObservation
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
    private var noteObservationCancellable: AnyCancellable?

    init(
        note: StickyNote,
        store: StickyNotesStore,
        cascadeOffset: CGFloat,
        onActivate: @escaping (String) -> Void,
        onClose: @escaping (String) -> Void
    ) {
        self.noteID = note.id
        self.store = store
        self.noteObservation = store.noteObservation(withID: note.id)
        self.onActivate = onActivate
        self.onClose = onClose

        let origin = CGPoint(x: 120 + cascadeOffset, y: 520 - cascadeOffset)
        let frame = note.preferredFrame.map {
            Self.clampedFrame(
                NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            )
        } ?? NSRect(origin: origin, size: Self.defaultContentSize)

        let hostingController = NSHostingController(
            rootView: NoteEditorView(noteID: note.id).stickyNotesStore(store)
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

        noteObservationCancellable = noteObservation.$note
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self else { return }

                guard let note, note.isOpen else {
                    if !self.isClosingFromCoordinator {
                        self.closeFromCoordinator()
                    }
                    return
                }

                self.apply(note: note)
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
        backgroundColor = note.color.nsColor
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

    func applyTiledFrame(_ frame: NSRect) {
        let targetFrame = Self.clampedFrame(frame)
        frameController.reset()
        frameController.applyModelFrame(targetFrame, force: true)
        store.updatePreferredFrame(id: noteID, frame: targetFrame.stickyFrame)
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

enum StickyNoteWindowGridLayout {
    static let defaultGap: CGFloat = 16

    static func tiledFrames(
        for currentFrames: [NSRect],
        in visibleFrame: NSRect,
        gap: CGFloat = defaultGap
    ) -> [NSRect] {
        guard !currentFrames.isEmpty else { return [] }
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return currentFrames }

        let maximumWidth = currentFrames.map(\.width).max() ?? 0
        let maximumHeight = currentFrames.map(\.height).max() ?? 0
        let cellWidth = maximumWidth + gap
        let cellHeight = maximumHeight + gap
        let columnCount = columnCount(
            for: currentFrames,
            visibleFrame: visibleFrame,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            gap: gap
        )

        return tiledFrames(
            for: currentFrames,
            in: visibleFrame,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columnCount: columnCount
        )
    }

    private static func tiledFrames(
        for currentFrames: [NSRect],
        in visibleFrame: NSRect,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        columnCount: Int
    ) -> [NSRect] {
        currentFrames.enumerated().map { index, frame in
            let column = index % columnCount
            let row = index / columnCount
            let proposedX = visibleFrame.minX + CGFloat(column) * cellWidth
            let rowTopY = visibleFrame.maxY - CGFloat(row) * cellHeight
            let proposedY = rowTopY - frame.height
            let x = clampedOrigin(
                proposedX,
                minimum: visibleFrame.minX,
                maximum: visibleFrame.maxX - frame.width
            )
            let y = clampedOrigin(
                proposedY,
                minimum: visibleFrame.minY,
                maximum: visibleFrame.maxY - frame.height
            )

            return NSRect(x: x, y: y, width: frame.width, height: frame.height)
        }
    }

    private static func clampedOrigin(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return min(max(value, minimum), maximum)
    }

    private static func columnCount(
        for currentFrames: [NSRect],
        visibleFrame: NSRect,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        gap: CGFloat
    ) -> Int {
        let itemCount = currentFrames.count
        let preferredColumnCount = max(1, Int(ceil(sqrt(Double(itemCount)))))
        var candidateColumnCounts = Array(preferredColumnCount...itemCount)
        if preferredColumnCount > 1 {
            candidateColumnCounts += stride(from: preferredColumnCount - 1, through: 1, by: -1)
        }

        var fallbackColumnCount: Int?
        for candidateColumnCount in candidateColumnCounts {
            let candidateFrames = tiledFrames(
                for: currentFrames,
                in: visibleFrame,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                columnCount: candidateColumnCount
            )

            if framesFit(candidateFrames, in: visibleFrame, gap: gap) {
                return candidateColumnCount
            }

            if fallbackColumnCount == nil,
               framesFit(candidateFrames, in: visibleFrame, gap: 0) {
                fallbackColumnCount = candidateColumnCount
            }
        }

        return fallbackColumnCount ?? preferredColumnCount
    }

    private static func framesFit(_ frames: [NSRect], in visibleFrame: NSRect, gap: CGFloat) -> Bool {
        frames.allSatisfy { frame in
            frame.minX >= visibleFrame.minX
                && frame.maxX <= visibleFrame.maxX
                && frame.minY >= visibleFrame.minY
                && frame.maxY <= visibleFrame.maxY
        } && framesRespectGap(frames, gap: gap)
    }

    private static func framesRespectGap(_ frames: [NSRect], gap: CGFloat) -> Bool {
        let minimumGap = max(0, gap)
        for firstIndex in frames.indices {
            for secondIndex in frames.index(after: firstIndex)..<frames.endIndex {
                if minimumGap == 0, frames[firstIndex].intersects(frames[secondIndex]) {
                    return false
                }

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

                if horizontalGap < minimumGap && verticalGap < minimumGap {
                    return false
                }
            }
        }

        return true
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
}
#endif
