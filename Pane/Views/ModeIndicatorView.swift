import AppKit
import SwiftUI

enum PaneTheme {
    static let workspaceBackground = Color(nsColor: .windowBackgroundColor)
    static let contentSurface = Color(nsColor: .textBackgroundColor)
    static let blockBackground = Color(nsColor: .controlBackgroundColor)
    static let selectedBlockBackground = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let subtleControlFill = Color.primary.opacity(0.08)
    static let subtleControlHoverFill = Color.primary.opacity(0.14)
    static let subtleControlPressedFill = Color.primary.opacity(0.20)

    static func terminalBackground(for appearance: NSAppearance) -> NSColor {
        NSColor.textBackgroundColor
    }

    static func terminalForeground(for appearance: NSAppearance) -> NSColor {
        NSColor.textColor
    }
}

enum PaneMetrics {
    /// Composer outer inset (18) + text inset (16) = the shared 34 pt text column.
    static let contentTextColumn: CGFloat = 34
    static let blockOuterInset: CGFloat = 18
    static let blockInnerInset: CGFloat = 16
    static let composerOuterInset: CGFloat = 18
    static let composerOuterVerticalInset: CGFloat = 8
    static let composerInnerInset: CGFloat = 0
    static let composerHorizontalTextInset: CGFloat = 16
    static let composerTrailingControlReserve: CGFloat = 6
    static let composerVerticalTextInset: CGFloat = 7
}
