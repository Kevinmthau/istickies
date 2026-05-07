#if os(macOS)
import AppKit
import Foundation
import Network

@MainActor
struct StickyNotesAutomaticSyncScheduledTask {
    private let cancellation: @MainActor () -> Void

    init(cancel: @escaping @MainActor () -> Void) {
        cancellation = cancel
    }

    func cancel() {
        cancellation()
    }
}

@MainActor
final class StickyNotesAutomaticSyncScheduler {
    typealias SyncOperation = @MainActor (StickyNotesAutomaticSyncReason) async -> Void
    typealias DelayedOperationScheduler = @MainActor (
        _ delay: TimeInterval,
        _ operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesAutomaticSyncScheduledTask

    private let minimumSyncInterval: TimeInterval
    private let now: () -> Date
    private let scheduleDelayedOperation: DelayedOperationScheduler
    private let syncOperation: SyncOperation

    private var lastSyncDate: Date?
    private var isSyncInFlight = false
    private var pendingReason: StickyNotesAutomaticSyncReason?
    private var pendingSyncTask: StickyNotesAutomaticSyncScheduledTask?

    init(
        minimumSyncInterval: TimeInterval = 10,
        now: @escaping () -> Date = Date.init,
        scheduleDelayedOperation: @escaping DelayedOperationScheduler = StickyNotesAutomaticSyncScheduler
            .scheduleDelayedOperation,
        syncOperation: @escaping SyncOperation
    ) {
        self.minimumSyncInterval = minimumSyncInterval
        self.now = now
        self.scheduleDelayedOperation = scheduleDelayedOperation
        self.syncOperation = syncOperation
    }

    func requestSync(reason: StickyNotesAutomaticSyncReason) async {
        let currentDate = now()

        if let lastSyncDate {
            let elapsed = currentDate.timeIntervalSince(lastSyncDate)
            if elapsed < minimumSyncInterval {
                pendingReason = reason
                guard pendingSyncTask == nil else { return }

                let delay = max(0, minimumSyncInterval - elapsed)
                pendingSyncTask = scheduleDelayedOperation(delay) { [weak self] in
                    await self?.runDeferredSync()
                }
                return
            }
        }

        if isSyncInFlight {
            pendingReason = reason
            return
        }

        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        pendingReason = nil
        await runSync(reason: reason, at: currentDate)
    }

    func stop() {
        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        pendingReason = nil
    }

    private func runDeferredSync() async {
        pendingSyncTask = nil
        guard !isSyncInFlight else { return }

        let reason = pendingReason ?? .periodicPoll
        pendingReason = nil
        await runSync(reason: reason, at: now())
    }

    private func runSync(reason: StickyNotesAutomaticSyncReason, at date: Date) async {
        lastSyncDate = date
        isSyncInFlight = true
        await syncOperation(reason)
        isSyncInFlight = false
        await drainPendingSyncIfNeeded()
    }

    private func drainPendingSyncIfNeeded() async {
        guard let reason = pendingReason else { return }

        let currentDate = now()
        if let lastSyncDate {
            let elapsed = currentDate.timeIntervalSince(lastSyncDate)
            if elapsed < minimumSyncInterval {
                guard pendingSyncTask == nil else { return }

                let delay = max(0, minimumSyncInterval - elapsed)
                pendingSyncTask = scheduleDelayedOperation(delay) { [weak self] in
                    await self?.runDeferredSync()
                }
                return
            }
        }

        pendingSyncTask?.cancel()
        pendingSyncTask = nil
        pendingReason = nil
        await runSync(reason: reason, at: currentDate)
    }

    private static func scheduleDelayedOperation(
        after delay: TimeInterval,
        operation: @escaping @MainActor () async -> Void
    ) -> StickyNotesAutomaticSyncScheduledTask {
        let task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds(for: delay))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await operation()
        }

        return StickyNotesAutomaticSyncScheduledTask {
            task.cancel()
        }
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        UInt64(max(0, delay) * 1_000_000_000)
    }
}

@MainActor
final class MacStickyNotesSyncScheduler {
    private struct NotificationObservation {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private let automaticSyncScheduler: StickyNotesAutomaticSyncScheduler
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let pathMonitor: NWPathMonitor
    private let pathMonitorQueue = DispatchQueue(label: "com.mushpot.iStickies.background-sync.path-monitor")
    private let periodicSyncInterval: TimeInterval

    private var notificationObservations: [NotificationObservation] = []
    private var periodicSyncTask: Task<Void, Never>?
    private var latestPathStatus: NWPath.Status?
    private var isStarted = false

    init(
        store: StickyNotesStore,
        minimumSyncInterval: TimeInterval = 10,
        periodicSyncInterval: TimeInterval = 60,
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        pathMonitor: NWPathMonitor = NWPathMonitor()
    ) {
        self.automaticSyncScheduler = StickyNotesAutomaticSyncScheduler(
            minimumSyncInterval: minimumSyncInterval
        ) { [weak store] reason in
            await store?.syncAutomatically(reason: reason)
        }
        self.periodicSyncInterval = periodicSyncInterval
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.pathMonitor = pathMonitor
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observeApplicationActivation()
        observeSystemWake()
        startNetworkMonitoring()
        startPeriodicSync()
    }

    func stop() {
        for observation in notificationObservations {
            observation.center.removeObserver(observation.token)
        }
        notificationObservations.removeAll()

        periodicSyncTask?.cancel()
        periodicSyncTask = nil
        pathMonitor.cancel()
        automaticSyncScheduler.stop()
        isStarted = false
    }

    private func observeApplicationActivation() {
        let token = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.requestSync(reason: .appActivation)
            }
        }
        notificationObservations.append(NotificationObservation(center: notificationCenter, token: token))
    }

    private func observeSystemWake() {
        let token = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.requestSync(reason: .systemWake)
            }
        }
        notificationObservations.append(NotificationObservation(center: workspaceNotificationCenter, token: token))
    }

    private func startNetworkMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor [weak self] in
                self?.handleNetworkStatus(status)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func startPeriodicSync() {
        periodicSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.nanoseconds(for: periodicSyncInterval))
                } catch {
                    return
                }

                guard !Task.isCancelled else { return }
                await requestSync(reason: .periodicPoll)
            }
        }
    }

    private func handleNetworkStatus(_ status: NWPath.Status) {
        let previousStatus = latestPathStatus
        latestPathStatus = status

        guard let previousStatus, previousStatus != .satisfied, status == .satisfied else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.requestSync(reason: .networkRestored)
        }
    }

    private func requestSync(reason: StickyNotesAutomaticSyncReason) async {
        await automaticSyncScheduler.requestSync(reason: reason)
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64(max(0, interval) * 1_000_000_000)
    }
}
#endif
