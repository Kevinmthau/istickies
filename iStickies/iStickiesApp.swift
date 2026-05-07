import SwiftUI

@main
struct iStickiesApp: App {
    @StateObject private var store: StickyNotesStore

#if os(macOS)
    @NSApplicationDelegateAdaptor(StickyNotesAppDelegate.self) private var appDelegate
    @StateObject private var windowCoordinator: MacStickyNoteWindowCoordinator
#endif

    init() {
        StickyNotesRuntime.prepareStoreForLaunchIfNeeded()

        let store = StickyNotesStore(
            fileStore: StickyNotesFileStore(fileURL: StickyNotesRuntime.fileStoreURL),
            cloudService: StickyNotesRuntime.cloudService,
            autoLoad: !StickyNotesRuntime.isRunningHostedUnitTests
        )
        _store = StateObject(wrappedValue: store)

#if os(macOS)
        StickyNotesAppDelegate.store = store
        _windowCoordinator = StateObject(wrappedValue: MacStickyNoteWindowCoordinator(store: store))
#endif
    }

    var body: some Scene {
#if os(macOS)
        Settings {
            EmptyView()
        }
        .commands {
            StickyNotesCommands(store: store, windowCoordinator: windowCoordinator)
        }
#else
        WindowGroup("Stickies") {
            MobileNotesSceneView()
                .stickyNotesStore(store)
        }
#endif
    }
}

#if os(macOS)
final class StickyNotesAppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: StickyNotesStore?

    private var isWaitingForTerminationReply = false
    private var syncScheduler: MacStickyNotesSyncScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if StickyNotesRuntime.isRunningHostedUnitTests {
            NSApp.setActivationPolicy(.prohibited)
            return
        }

        guard let store = Self.store else { return }
        let syncScheduler = MacStickyNotesSyncScheduler(store: store)
        self.syncScheduler = syncScheduler
        syncScheduler.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForTerminationReply else { return .terminateLater }
        guard let store = Self.store else { return .terminateNow }

        isWaitingForTerminationReply = true
        syncScheduler?.stop()
        syncScheduler = nil
        NotificationCenter.default.post(name: .stickyNotesWillTerminate, object: nil)

        Task { @MainActor in
            await store.flushPendingPersistence()
            sender.reply(toApplicationShouldTerminate: true)
            self.isWaitingForTerminationReply = false
        }

        return .terminateLater
    }
}

private struct StickyNotesCommands: Commands {
    let store: StickyNotesStore
    let windowCoordinator: MacStickyNoteWindowCoordinator

    var body: some Commands {
        CommandMenu("Stickies") {
            Button("New Note") {
                windowCoordinator.createAndFocusNote()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Show All Notes") {
                windowCoordinator.showAllNotes()
            }
            .keyboardShortcut("0", modifiers: [.command, .shift])

            Button("Tile Open Notes") {
                windowCoordinator.tileOpenNotesInGrid()
            }
            .keyboardShortcut("0", modifiers: [.command, .control])

            Button("Sync Now") {
                Task { await store.syncNow() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Delete Current Note") {
                windowCoordinator.deleteFocusedNote()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
        }
    }
}
#endif

private enum StickyNotesRuntime {
    private static let environment = ProcessInfo.processInfo.environment

    static var isRunningHostedUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var fileStoreURL: URL {
        guard let namespace = sanitizedStoreNamespace else {
            return StickyNotesFileStore.defaultFileURL()
        }

        let baseIdentifier = Bundle.main.bundleIdentifier ?? "com.mushpot.iStickies"
        return StickyNotesFileStore.defaultFileURL(bundleIdentifier: "\(baseIdentifier).\(namespace)")
    }

    static var cloudService: any StickyNotesCloudSyncing {
        if environment["ISTICKIES_USE_LOCAL_CLOUD"] == "1" {
            return LocalOnlyStickyNotesCloudService()
        }

        return StickyNotesCloudServiceFactory.makeDefaultService()
    }

    static func prepareStoreForLaunchIfNeeded() {
        guard environment["ISTICKIES_SEED_CORRUPT_STORE"] == "1" else { return }
        guard sanitizedStoreNamespace != nil else { return }

        let fileURL = fileStoreURL
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try Data("not json".utf8).write(to: fileURL, options: .atomic)
        } catch {
            StickyNotesLog.persistence.error(
                "Failed to seed corrupt UI-test snapshot: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private static var sanitizedStoreNamespace: String? {
        guard let namespace = environment["ISTICKIES_STORE_NAMESPACE"], !namespace.isEmpty else {
            return nil
        }

        let sanitized = namespace.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }

        return sanitized.isEmpty ? nil : sanitized
    }
}

extension Notification.Name {
    static let stickyNotesWillTerminate = Notification.Name("StickyNotesWillTerminate")
}
