import Foundation
import OSLog

enum StickyNotesLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.mushpot.iStickies"

    static let cloudKit = Logger(subsystem: subsystem, category: "CloudKit")
    static let persistence = Logger(subsystem: subsystem, category: "Persistence")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let windowing = Logger(subsystem: subsystem, category: "Windowing")
}
