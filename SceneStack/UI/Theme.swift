import SwiftUI

/// SceneStack's colour system: a dark charcoal canvas with vivid saturated
/// accents, in the spirit of Live/Push hardware.
enum Theme {
    static let coral = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.25)
    static let mint = Color(red: 0.30, green: 0.90, blue: 0.63)
    static let cyan = Color(red: 0.25, green: 0.78, blue: 0.98)
    static let violet = Color(red: 0.62, green: 0.52, blue: 1.00)
    static let magenta = Color(red: 0.98, green: 0.45, blue: 0.82)

    /// Assigned round-robin to new tracks from Phase 3 onwards.
    static let trackPalette: [Color] = [coral, amber, mint, cyan, violet, magenta]
    static let paletteNames = ["Coral", "Amber", "Mint", "Cyan", "Violet", "Magenta"]

    static let surface = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let surfaceRaised = Color(red: 0.18, green: 0.18, blue: 0.22)
    static let dimmed = Color.white.opacity(0.35)

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.11, green: 0.10, blue: 0.15),
                Color(red: 0.06, green: 0.06, blue: 0.09),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Accent colour for the current transport mode.
    static func accent(for mode: TransportEngine.Mode, countingIn: Bool) -> Color {
        if countingIn { return amber }
        switch mode {
        case .stopped: return dimmed
        case .playing: return mint
        case .recording: return coral
        }
    }
}
