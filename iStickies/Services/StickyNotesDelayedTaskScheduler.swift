import Foundation

struct StickyNotesDelayedTask {
    private let cancellation: () -> Void

    init(cancel: @escaping () -> Void) {
        cancellation = cancel
    }

    func cancel() {
        cancellation()
    }
}

enum StickyNotesDelay: Equatable {
    case timeInterval(TimeInterval)
    case duration(Duration)
}

protocol StickyNotesDelayedTaskScheduling {
    @MainActor
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask

    @MainActor
    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask
}

struct StickyNotesLiveDelayedTaskScheduler: StickyNotesDelayedTaskScheduling {
    func schedule(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask {
        schedule(after: .timeInterval(delay), operation: operation)
    }

    func schedule(
        after delay: Duration,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask {
        schedule(after: .duration(delay), operation: operation)
    }

    private func schedule(
        after delay: StickyNotesDelay,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesDelayedTask {
        let task = Task { @MainActor in
            do {
                try await sleep(for: delay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await operation()
        }

        return StickyNotesDelayedTask {
            task.cancel()
        }
    }

    private func sleep(for delay: StickyNotesDelay) async throws {
        switch delay {
        case let .timeInterval(delay):
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            if nanoseconds > 0 {
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        case let .duration(delay):
            try await Task.sleep(for: delay)
        }
    }
}
