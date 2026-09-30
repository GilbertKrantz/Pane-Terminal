import AppKit
import SwiftUI

struct CommandClickableTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor

    func makeNSView(context: Context) -> CommandClickableNSTextView {
        Self.makeTextView()
    }

    static func makeTextView() -> CommandClickableNSTextView {
        let textView = CommandClickableNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        return textView
    }

    func updateNSView(_ textView: CommandClickableNSTextView, context: Context) {
        updateTextView(textView)
    }

    func updateTextView(_ textView: CommandClickableNSTextView) {
        // Session status changes do not change finalized output. Avoid resetting
        // TextKit and invalidating the lazy row's size on every session update.
        guard textView.string != text || textView.font != font || textView.textColor != textColor else { return }
        textView.textStorage?.setAttributedString(attributedText)
        textView.textColor = textColor
        textView.font = font
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: CommandClickableNSTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: textView.height(fitting: width))
    }

    private var attributedText: NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: textColor
            ]
        )

        for match in Self.urlMatches(in: text) {
            let urlText = (text as NSString).substring(with: match.range)
            guard let url = URL(string: urlText) else { continue }
            attributed.addAttribute(.link, value: url, range: match.range)
        }

        return attributed
    }

    private static func urlMatches(in text: String) -> [NSTextCheckingResult] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, options: [], range: range)
    }
}

final class CommandClickableNSTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard bounds.width > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        guard let textContainer, let layoutManager else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(usedRect.height))
    }

    private let measurementStorage = NSTextStorage()
    private let measurementLayout = NSLayoutManager()
    private let measurementContainer = NSTextContainer(size: .zero)
    private var measuredWidth: CGFloat?
    private var measuredHeight: CGFloat = 0

    func height(fitting width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0, let textStorage else { return 0 }
        if measurementLayout.textStorage == nil {
            measurementStorage.addLayoutManager(measurementLayout)
            measurementLayout.addTextContainer(measurementContainer)
            measurementContainer.lineFragmentPadding = 0
        }
        let textChanged = !measurementStorage.isEqual(to: textStorage)
        if textChanged { measurementStorage.setAttributedString(textStorage) }
        if textChanged || measuredWidth != width {
            // sizeThatFits is a measurement, not a layout pass. Resizing the
            // displayed NSTextView here invalidates SwiftUI's current proposal
            // and makes the enclosing lazy timeline's height oscillate.
            measurementContainer.containerSize = NSSize(width: width, height: 10_000_000)
            measurementLayout.ensureLayout(for: measurementContainer)
            measuredWidth = width
            measuredHeight = ceil(measurementLayout.usedRect(for: measurementContainer).height)
        }
        return measuredHeight
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            invalidateIntrinsicContentSize()
        }
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard NSEvent.modifierFlags.contains(.command) else { return }

        if let url = link as? URL {
            NSWorkspace.shared.open(url)
        } else if let urlString = link as? String, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let textContainer, let layoutManager else { return }

        let fullRange = NSRange(location: 0, length: string.utf16.count)
        textStorage?.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value != nil else { return }
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: range,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer
            ) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }
}

/// The output viewport has an explicit text-derived height. A nested SwiftUI
/// ScrollView with only maxHeight can claim the entire cap for a single line,
/// leaving the timeline anchored to blank space as lazy row estimates change.
struct CommandOutputScrollView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor

    func makeNSView(context: Context) -> CommandOutputNSScrollView {
        let scrollView = CommandOutputNSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = CommandClickableTextView.makeTextView()
        return scrollView
    }

    func updateNSView(_ scrollView: CommandOutputNSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CommandClickableNSTextView else { return }
        CommandClickableTextView(text: text, font: font, textColor: textColor).updateTextView(textView)
        scrollView.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommandOutputNSScrollView,
                     context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let textView = nsView.documentView as? CommandClickableNSTextView else { return nil }
        return CGSize(width: width, height: min(PaneMetrics.blockOutputMaxHeight,
                                               textView.height(fitting: width)))
    }
}

final class CommandOutputNSScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? CommandClickableNSTextView else { return }
        let width = contentView.bounds.width
        guard width > 0 else { return }
        let height = max(contentView.bounds.height, textView.height(fitting: width))
        let size = NSSize(width: width, height: height)
        if textView.frame.size != size { textView.setFrameSize(size) }
    }
}
