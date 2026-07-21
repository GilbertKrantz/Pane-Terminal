import AppKit
import SwiftUI

enum PaneTheme {
    static let workspaceBackground = Color(nsColor: .windowBackgroundColor)
    static let contentSurface = Color(nsColor: .textBackgroundColor)
    static let blockBackground = Color(nsColor: .controlBackgroundColor)
    static let selectedBlockBackground = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    static func terminalBackground(for appearance: NSAppearance) -> NSColor {
        NSColor.textBackgroundColor
    }

    static func terminalForeground(for appearance: NSAppearance) -> NSColor {
        NSColor.textColor
    }
}

enum PaneMetrics {
    /// Block outer inset (12) + block inner inset (12) = the 24 pt text column.
    static let contentTextColumn: CGFloat = 24
    static let blockOuterInset: CGFloat = 12
    static let blockInnerInset: CGFloat = 12
    static let composerOuterInset: CGFloat = 16
    static let composerInnerInset: CGFloat = 8
    static let composerTextInset: CGFloat = 0
}
