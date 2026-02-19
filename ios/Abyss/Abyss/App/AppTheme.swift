import SwiftUI

// MARK: - Appearance Preference

/// User-selectable appearance: Light, Dark, or follow system.
enum AppAppearance: String, CaseIterable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var iconName: String {
        switch self {
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - Centralized Theme Colors

/// All app colors in one place. Use `for colorScheme:` to get theme-aware values.
enum AppTheme {

    // MARK: - Pills & Action Bar

    /// Background for mic pill, typing bar, and action bar controls.
    /// Light: #EFEFEF, Dark: rgb(30,30,30)
    static func pillBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
            : Color(red: 239 / 255, green: 239 / 255, blue: 239 / 255)  // #EFEFEF
    }

    /// Stroke/border for pills and action bar controls.
    static func pillStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    /// Icon tint for action bar (mic, send, event timeline).
    static func actionBarIconTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 156 / 255, green: 156 / 255, blue: 156 / 255)
            : .black
    }

    // MARK: - Message Bubbles

    /// User message bubble background.
    static func userBubbleBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 33 / 255, green: 33 / 255, blue: 33 / 255)
            : Color(red: 220 / 255, green: 220 / 255, blue: 220 / 255)
    }

    /// User message bubble text color.
    static func userBubbleText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    // MARK: - Agent Progress Cards

    /// Agent card background.
    static func agentCardBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 20 / 255, green: 22 / 255, blue: 27 / 255)
            : Color(red: 248 / 255, green: 248 / 255, blue: 250 / 255)
    }

    /// Agent card stroke.
    static func agentCardStroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }

    /// Agent card primary text.
    static func agentCardText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    /// Agent card secondary/muted text.
    static func agentCardMutedText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.55)
            : Color.black.opacity(0.55)
    }

    /// Agent card tertiary text.
    static func agentCardTertiaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.6)
            : Color.black.opacity(0.6)
    }

    /// Agent card status badge background (derived from status color).
    static func agentCardStatusBadgeBackground(foreground: Color, colorScheme: ColorScheme) -> Color {
        foreground.opacity(colorScheme == .dark ? 0.16 : 0.12)
    }

    /// Agent card dismiss button background.
    static func agentCardDismissBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.06)
    }

    /// Agent card progress track background.
    static func agentCardProgressTrack(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.1)
    }

    /// Agent card step text for pending state.
    static func agentCardStepPendingText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.62)
            : Color.black.opacity(0.5)
    }

    /// Agent card step text for active/complete.
    static func agentCardStepActiveText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color.black.opacity(0.9)
    }

    // MARK: - Event Timeline

    /// Event timeline header background.
    static func eventTimelineHeaderBackground(for colorScheme: ColorScheme) -> Color {
        Color(.systemGray5)
    }

    /// Event timeline container background.
    static func eventTimelineBackground(for colorScheme: ColorScheme) -> Color {
        Color(.systemBackground)
    }

    /// Event timeline border.
    static func eventTimelineBorder(for colorScheme: ColorScheme) -> Color {
        Color(.systemGray4)
    }

    // MARK: - Warnings & Alerts

    /// API key warning banner background.
    static func warningBannerBackground(for colorScheme: ColorScheme) -> Color {
        Color.yellow.opacity(0.15)
    }

    // MARK: - Auth (GitHub Login)

    /// Auth screen background (full-screen, typically dark for branding).
    static let authBackground = Color.black

    /// Auth error text.
    static let authErrorText = Color(red: 1, green: 0.4, blue: 0.4)

    /// Auth error background.
    static let authErrorBackground = Color.red.opacity(0.12)

    /// Auth button background (normal).
    static let authButtonBackground = Color.white

    /// Auth button background (loading).
    static let authButtonBackgroundLoading = Color.white.opacity(0.7)
}
