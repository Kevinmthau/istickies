import SwiftUI

#if os(macOS)
import AppKit
#endif

enum StickyNoteColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case mint
    case blue
    case orange
    case pink

    private static let stickyYellow = Color(red: 0.99, green: 0.96, blue: 0.63)

    var id: String { rawValue }

    var name: String {
        switch self {
        case .yellow:
            "Yellow"
        case .mint:
            "Mint"
        case .blue:
            "Blue"
        case .orange:
            "Orange"
        case .pink:
            "Pink"
        }
    }

    var tint: Color {
        Self.stickyYellow
    }

#if os(macOS)
    var nsColor: NSColor {
        NSColor(calibratedRed: 0.99, green: 0.96, blue: 0.63, alpha: 1)
    }
#endif
}
