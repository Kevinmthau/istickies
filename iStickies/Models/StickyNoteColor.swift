import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum StickyNoteColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case yellow
    case mint
    case blue
    case orange
    case pink

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
        dynamicColor(light: lightTint, dark: darkTint)
    }

#if os(macOS)
    var nsColor: NSColor {
        dynamicNSColor(light: lightTint, dark: darkTint)
    }
#endif

    private var lightTint: RGB {
        switch self {
        case .yellow: RGB(red: 0.99, green: 0.96, blue: 0.63)
        case .mint: RGB(red: 0.68, green: 0.93, blue: 0.82)
        case .blue: RGB(red: 0.68, green: 0.82, blue: 0.96)
        case .orange: RGB(red: 0.99, green: 0.82, blue: 0.58)
        case .pink: RGB(red: 0.99, green: 0.75, blue: 0.82)
        }
    }

    private var darkTint: RGB {
        switch self {
        case .yellow: RGB(red: 0.99, green: 0.96, blue: 0.63)
        case .mint: RGB(red: 0.21, green: 0.36, blue: 0.30)
        case .blue: RGB(red: 0.20, green: 0.30, blue: 0.42)
        case .orange: RGB(red: 0.40, green: 0.29, blue: 0.17)
        case .pink: RGB(red: 0.40, green: 0.24, blue: 0.31)
        }
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double
    }

    private func color(from rgb: RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func dynamicColor(light: RGB, dark: RGB) -> Color {
#if os(iOS)
        Color(UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
#elseif os(macOS)
        Color(dynamicNSColor(light: light, dark: dark))
#else
        color(from: light)
#endif
    }

#if os(macOS)
    private func dynamicNSColor(light: RGB, dark: RGB) -> NSColor {
        NSColor(name: nil) { appearance in
            let bestAppearance = appearance.bestMatch(from: [.darkAqua, .aqua])
            let rgb = bestAppearance == .darkAqua ? dark : light
            return NSColor(calibratedRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        }
    }
#endif
}
