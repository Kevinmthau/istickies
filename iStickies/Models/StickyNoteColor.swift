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
        switch self {
        case .yellow: Self.stickyYellow
        case .mint: Color(red: 0.68, green: 0.93, blue: 0.82)
        case .blue: Color(red: 0.68, green: 0.82, blue: 0.96)
        case .orange: Color(red: 0.99, green: 0.82, blue: 0.58)
        case .pink: Color(red: 0.99, green: 0.75, blue: 0.82)
        }
    }

#if os(macOS)
    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(calibratedRed: 0.99, green: 0.96, blue: 0.63, alpha: 1)
        case .mint: NSColor(calibratedRed: 0.68, green: 0.93, blue: 0.82, alpha: 1)
        case .blue: NSColor(calibratedRed: 0.68, green: 0.82, blue: 0.96, alpha: 1)
        case .orange: NSColor(calibratedRed: 0.99, green: 0.82, blue: 0.58, alpha: 1)
        case .pink: NSColor(calibratedRed: 0.99, green: 0.75, blue: 0.82, alpha: 1)
        }
    }
#endif
}
