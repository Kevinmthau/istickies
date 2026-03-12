import SwiftUI

@main
struct iStickiesApp: App {
    @StateObject private var store: StickyNotesStore

#if os(macOS)
    @NSApplicationDelegateAdaptor(StickyNotesAppDelegate.self) private var appDelegate
    @StateObject private var windowCoordinator: MacStickyNoteWindowCoordinator
#endif

    init() {
        let store = StickyNotesStore()
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
                .environmentObject(store)
        }
#endif
    }
}

#if os(macOS)
final class StickyNotesAppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: StickyNotesStore?

    private var isWaitingForTerminationReply = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isWaitingForTerminationReply else { return .terminateLater }
        guard let store = Self.store else { return .terminateNow }

        isWaitingForTerminationReply = true
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
    @ObservedObject var store: StickyNotesStore
    @ObservedObject var windowCoordinator: MacStickyNoteWindowCoordinator

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

extension Notification.Name {
    static let stickyNotesWillTerminate = Notification.Name("StickyNotesWillTerminate")
}
