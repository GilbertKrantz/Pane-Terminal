import AppKit
import SwiftUI

enum PaneTheme {
    static let workspaceBackground = Color(nsColor: .windowBackgroundColor)
    static let contentSurface = Color(nsColor: .textBackgroundColor)
    static let blockBackground = Color(nsColor: .controlBackgroundColor)
    static let selectedBlockBackground = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let tabStripBackground = Color(nsColor: .windowBackgroundColor)
    static let hoveredTabBackground = Color.primary.opacity(0.045)
    static let subtleControlFill = Color.primary.opacity(0.08)
    static let subtleControlHoverFill = Color.primary.opacity(0.14)
    static let subtleControlPressedFill = Color.primary.opacity(0.20)
    static let composerContextForeground = Color.secondary

    static func selectedTabBackground(increasedContrast: Bool) -> Color {
        Color.primary.opacity(increasedContrast ? 0.14 : 0.075)
    }

    static func selectedTabBorder(increasedContrast: Bool) -> Color {
        Color.primary.opacity(increasedContrast ? 0.28 : 0.10)
    }

    static func terminalBackground(for appearance: NSAppearance) -> NSColor {
        NSColor.textBackgroundColor
    }

    static func terminalForeground(for appearance: NSAppearance) -> NSColor {
        NSColor.textColor
    }
}

enum PaneMetrics {
    static let tabStripHeight: CGFloat = 36
    static let searchRowHeight: CGFloat = 38
    static let composerMinHeight: CGFloat = 58
    static let contentTextColumn: CGFloat = 28
    static let blockOuterInset: CGFloat = 12
    static let blockInnerInset: CGFloat = 16
    static let blockVerticalSpacing: CGFloat = 18
    static let blockOutputMaxHeight: CGFloat = 320
    static let timelineRailWidth: CGFloat = 2
    static let systemEventHeight: CGFloat = 32
    static let composerOuterInset: CGFloat = 12
    static let composerHorizontalInset: CGFloat = 20
    static let composerOuterVerticalInset: CGFloat = 6
    static let composerInnerInset: CGFloat = 0
    static let composerHorizontalTextInset: CGFloat = 0
    static let composerVerticalTextInset: CGFloat = 5
    static let composerContextHeaderHeight: CGFloat = 16
    static let composerContextEditorGap: CGFloat = 2
    static let composerContextSpacing: CGFloat = 5
    static let composerContextLargeWidth: CGFloat = 500
    static let composerContextNameVisibilityWidth: CGFloat = 320
    static let composerContextLargeTextMaxWidth: CGFloat = 240
    static let composerContextMediumTextMaxWidth: CGFloat = 160
    static let composerContextIconSize: CGFloat = 12
    static let composerEditorMinHeight: CGFloat = 28
    static let composerEditorMaxHeight: CGFloat = 60
    static let composerEditorLineIncrement: CGFloat = 16
    static let composerEditorSubmitSpacing: CGFloat = 8
    static let composerSubmitButtonSize: CGFloat = 28
}
