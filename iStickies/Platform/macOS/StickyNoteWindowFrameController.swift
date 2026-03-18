#if os(macOS)
import AppKit
import Foundation

@MainActor
final class StickyNoteWindowFrameController {
    private static let localFramePersistenceDelay: TimeInterval = 0.15

    private let readCurrentFrame: @MainActor () -> NSRect
    private let applyFrame: @MainActor (NSRect) -> Void
    private let readPersistedFrame: @MainActor () -> StickyNoteFrame?
    private let persistFrame: @MainActor (StickyNoteFrame) -> Void

    private(set) var isApplyingModelFrame = false
    private var isLocallyMovingWindow = false
    private var lastLocalFrameReportDate: Date?
    private var pendingLocalFrame: StickyNoteFrame?
    private var localFramePersistenceTask: Task<Void, Never>?
    private var pendingModelFrame: NSRect?
    private var pendingModelFrameTask: Task<Void, Never>?

    init(
        readCurrentFrame: @escaping @MainActor () -> NSRect,
        applyFrame: @escaping @MainActor (NSRect) -> Void,
        readPersistedFrame: @escaping @MainActor () -> StickyNoteFrame?,
        persistFrame: @escaping @MainActor (StickyNoteFrame) -> Void
    ) {
        self.readCurrentFrame = readCurrentFrame
        self.applyFrame = applyFrame
        self.readPersistedFrame = readPersistedFrame
        self.persistFrame = persistFrame
    }

    deinit {
        localFramePersistenceTask?.cancel()
        pendingModelFrameTask?.cancel()
    }

    func applyModelFrame(_ targetFrame: NSRect, force: Bool = false) {
        let currentFrame = readCurrentFrame()

        guard StickyNoteWindowFrameSync.shouldApplyModelFrame(
            currentFrame: currentFrame,
            targetFrame: targetFrame,
            lastLocalFrameReportDate: lastLocalFrameReportDate,
            isLocalMoveActive: isLocallyMovingWindow,
            forceFrame: force
        ) else {
            if force || currentFrame.distanceSquared(to: targetFrame) <= 9 {
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

        if force || currentFrame.distanceSquared(to: targetFrame) > 9 {
            applyFrame(targetFrame)
        }
    }

    func flushPendingLocalFramePersistence() {
        localFramePersistenceTask?.cancel()
        localFramePersistenceTask = nil

        guard let pendingLocalFrame else { return }
        self.pendingLocalFrame = nil

        if readPersistedFrame() != pendingLocalFrame {
            persistFrame(pendingLocalFrame)
        }
    }

    func windowWillMove() {
        guard !isLocallyMovingWindow else { return }
        isLocallyMovingWindow = true
    }

    func windowDidMove() {
        guard !isApplyingModelFrame else { return }
        windowWillMove()

        lastLocalFrameReportDate = Date()
        pendingLocalFrame = readCurrentFrame().stickyFrame
        scheduleLocalFramePersistence(after: Self.localFramePersistenceDelay)
    }

    func windowDidEndLiveResize() {
        guard !isApplyingModelFrame else { return }
        lastLocalFrameReportDate = Date()
        pendingLocalFrame = readCurrentFrame().stickyFrame
        flushPendingLocalFramePersistence()
    }

    func reset() {
        localFramePersistenceTask?.cancel()
        pendingModelFrameTask?.cancel()
        localFramePersistenceTask = nil
        pendingModelFrameTask = nil
        pendingLocalFrame = nil
        pendingModelFrame = nil
        isApplyingModelFrame = false
        isLocallyMovingWindow = false
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

        let currentFrame = readCurrentFrame()
        if currentFrame.distanceSquared(to: pendingModelFrame) <= 9 {
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
        applyFrame(pendingModelFrame)
    }

    private func clearPendingModelFrame() {
        pendingModelFrame = nil
        pendingModelFrameTask?.cancel()
        pendingModelFrameTask = nil
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

    private func completeLocalMoveIfNeeded() {
        guard isLocallyMovingWindow else { return }

        isLocallyMovingWindow = false
        clearPendingModelFrame()
        flushPendingLocalFramePersistence()
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
