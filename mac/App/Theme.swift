import AppKit

/// Visual constants. Apple-native calm (Things 3): system font, translucent material, generous continuous corners,
/// one accent (the user's macOS accent color), a warm yellow star for Today.
@MainActor
enum Theme {
    static let panelWidth: CGFloat = 440
    static let maxPanelHeight: CGFloat = 600
    static var panelSize: NSSize { NSSize(width: panelWidth, height: maxPanelHeight) }
    /// Transparent room around the panel for its own tight, menu-like shadow (the system window shadow is a heavy band).
    static let shadowMargin: CGFloat = 16
    static var windowWidth: CGFloat { panelWidth + shadowMargin * 2 }
    static let minPanelHeight: CGFloat = 240
    /// Matches current macOS menus and popovers: big, continuous corners.
    static let cornerRadius: CGFloat = 20
    static let rowRadius: CGFloat = 10
    static let indent: CGFloat = 22
    static let sidePadding: CGFloat = 16

    static var textSize: CGFloat { CGFloat(Prefs.shared.textSize) }
    static var itemFont: NSFont { .systemFont(ofSize: textSize) }
    static var noteFont: NSFont { .systemFont(ofSize: max(10, textSize - 1.5)) }
    static var chipFont: NSFont { .systemFont(ofSize: max(10, textSize - 2), weight: .medium) }
    static var sectionFont: NSFont { .systemFont(ofSize: max(10, textSize - 1.5), weight: .semibold) }
    /// The title line of a row; notes add lines below it.
    static var rowHeight: CGFloat { (textSize * 1.55 + 12).rounded() }
    static var noteLineHeight: CGFloat { (noteFont.ascender - noteFont.descender + noteFont.leading + 2).rounded(.up) }
    static var checkboxSize: CGFloat { (textSize + 4).rounded() }
    static let tagFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static var accent: NSColor { .controlAccentColor }
    static let star = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.13, alpha: 1)
    static let overdue = NSColor.systemRed
    static let fadedAlpha: CGFloat = 0.45
}
