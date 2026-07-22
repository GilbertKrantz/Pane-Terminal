import AppKit
import SwiftUI

struct CommandClickableTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor

    func makeNSView(context: Context) -> CommandClickableNSTextView {
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

    func height(fitting width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 0 }

        if abs(frame.width - width) > 0.5 {
            setFrameSize(NSSize(width: width, height: frame.height))
        }
        textContainer.containerSize.height = CGFloat.greatestFiniteMagnitude
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height)
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
