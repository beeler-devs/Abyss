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

    // MARK: - Sidebar

    /// Sidebar selected row highlight (neutral opacity instead of blue accent).
    static func sidebarSelectedRow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.08)
    }

    /// Sidebar selected row text/icon color.
    static func sidebarSelectedText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? .white : .black
    }

    /// Sidebar fallback solid background (pre-iOS 26).
    static func sidebarBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.97)
    }

    /// Unified sidebar icon size (SF Symbol point size).
    static let sidebarIconSize: CGFloat = 16

    /// Unified sidebar icon frame (hit target / alignment).
    static let sidebarIconFrame: CGFloat = 24

    // MARK: - Event Timeline

    /// Event timeline header background (reduced opacity on iOS 26 to not occlude glass).
    static func eventTimelineHeaderBackground(for colorScheme: ColorScheme) -> Color {
        if #available(iOS 26, *) {
            return Color(UIColor.systemGray5.withAlphaComponent(0.5))
        }
        return Color(UIColor.systemGray5)
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

    // MARK: - Code Blocks

    /// Fenced code block background (dark terminal-like).
    static func codeBlockBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 18 / 255, green: 18 / 255, blue: 18 / 255)
            : Color(red: 38 / 255, green: 38 / 255, blue: 38 / 255)
    }

    /// Fenced code block text color.
    static func codeBlockText(for colorScheme: ColorScheme) -> Color {
        Color(red: 220 / 255, green: 220 / 255, blue: 220 / 255)
    }

    /// Fenced code block language label text.
    static func codeBlockLabelText(for colorScheme: ColorScheme) -> Color {
        Color.white.opacity(0.4)
    }

    /// Inline code background.
    static func inlineCodeBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.06)
    }

    // MARK: - Card Categories

    /// Per-type accent colors for card views.
    enum CardCategory {
        case canvas, email, calendar, agent, bridge, repository

        var accentColor: Color {
            switch self {
            case .canvas: return .indigo
            case .email: return .blue
            case .calendar: return .orange
            case .agent: return .green
            case .bridge: return .purple
            case .repository: return .teal
            }
        }
    }

    /// Accent-tinted icon circle fill (~12% opacity).
    static func cardIconBackground(category: CardCategory, colorScheme: ColorScheme) -> Color {
        category.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.10)
    }

    /// Standard card expand/collapse animation.
    static let cardExpandAnimation: Animation = .smooth(duration: 0.25)
}

// MARK: - Glass / Pill Background Helpers

extension View {
    /// Liquid glass on iOS 26+; standard pill background on earlier OS versions.
    @ViewBuilder
    func glassButtonBackground(cornerRadius: CGFloat, colorScheme: ColorScheme) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
                .background(RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppTheme.pillBackground(for: colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(AppTheme.pillStroke(for: colorScheme), lineWidth: 1))
        }
    }

    /// Material background for large sidebar surface: `.ultraThinMaterial` on iOS 26+, solid fallback.
    @ViewBuilder
    func sidebarGlassBackground(colorScheme: ColorScheme) -> some View {
        if #available(iOS 26, *) {
            self.background(.ultraThinMaterial, ignoresSafeAreaEdges: .all)
        } else {
            self.background(
                AppTheme.sidebarBackground(for: colorScheme)
                    .ignoresSafeArea()
            )
        }
    }

    /// Material card background with per-category accent stroke on iOS 26+; solid fallback on earlier.
    @ViewBuilder
    func cardBackground(category: AppTheme.CardCategory, cornerRadius: CGFloat = 16, colorScheme: ColorScheme) -> some View {
        if #available(iOS 26, *) {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(
                            category.accentColor.opacity(colorScheme == .dark ? 0.15 : 0.10),
                            lineWidth: 0.5
                        )
                )
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(AppTheme.agentCardBackground(for: colorScheme))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppTheme.agentCardStroke(for: colorScheme), lineWidth: 1)
                )
        }
    }

    /// Glass container for the event timeline panel: `.glassEffect` on iOS 26+, solid+stroke fallback.
    @ViewBuilder
    func eventTimelineGlassBackground(cornerRadius: CGFloat, colorScheme: ColorScheme) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
                .background(AppTheme.eventTimelineBackground(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(AppTheme.eventTimelineBorder(for: colorScheme), lineWidth: 0.5)
                )
        }
    }

    /// Glass background that turns solid red while recording (PTT active state).
    /// Uses non-interactive glass so the long-press gesture isn't stolen by the glass effect.
    @ViewBuilder
    func pttButtonBackground(isRecording: Bool, cornerRadius: CGFloat, colorScheme: ColorScheme) -> some View {
        if isRecording {
            self.background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.red))
        } else if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
                .background(RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(AppTheme.pillBackground(for: colorScheme)))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(AppTheme.pillStroke(for: colorScheme), lineWidth: 1))
        }
    }
}
