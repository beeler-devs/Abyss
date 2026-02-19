import CoreGraphics

/// Centralized UI constants for consistent layout and sizing.
/// Tweak these values to adjust app-wide UI; changes here do not affect other UI regions.
enum UIConstants {

    // MARK: - Action Bar (bottom input controls)

    /// Height of the mic pill and adjacent action buttons.
    static let actionBarControlHeight: CGFloat = 42

    /// Icon size for action bar buttons (mic, send, event timeline).
    static let actionBarIconSize: CGFloat = 19

    /// Horizontal padding around the action bar HStack.
    static let actionBarHorizontalPadding: CGFloat = 12

    /// Top padding above the action bar.
    static let actionBarTopPadding: CGFloat = 8

    /// Bottom padding below the action bar.
    static let actionBarBottomPadding: CGFloat = 4

    /// Spacing between items in the action bar.
    static let actionBarSpacing: CGFloat = 12

    /// Horizontal padding inside the mic/typing pill.
    static let actionBarPillHorizontalPadding: CGFloat = 10

    /// Height of the waveform view when recording.
    static let actionBarWaveformHeight: CGFloat = 19

    /// Width of the clear spacer on each side of the mic icon in voice mode.
    static let actionBarVoiceSpacerWidth: CGFloat = 46

    /// Height of the voice bar spacers.
    static let actionBarVoiceSpacerHeight: CGFloat = 19
}
