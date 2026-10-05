import AppKit
import SwiftUI

private struct OutputLink: Sendable {
    let range: NSRange
    let url: URL
}

/// Serialized, bounded link detection. Large excerpts never scan for links
/// synchronously while a history row is mounting on the main actor.
private actor OutputLinkDetector {
    static let shared = OutputLinkDetector()
    private let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private var cache: [String: [OutputLink]] = [:]
    private var retainedBytes = 0

    func links(in text: String) -> [OutputLink] {
        if let cached = cache[text] { return cached }
        guard !Task.isCancelled else { return [] }
        let links = Self.matches(text, detector: detector)
        guard !Task.isCancelled else { return [] }
        let cost = text.utf8.count
        if cache.count >= 64 || retainedBytes + cost > 4 * 1024 * 1024 {
            cache.removeAll(keepingCapacity: true)
            retainedBytes = 0
        }
        if cost <= 4 * 1024 * 1024 {
            cache[text] = links
            retainedBytes += cost
        }
        return links
    }

    func clear() {
        cache.removeAll()
        retainedBytes = 0
    }

    nonisolated static func matches(_ text: String, detector: NSDataDetector?) -> [OutputLink] {
        let value = text as NSString
        return (detector?.matches(in: text, range: NSRange(location: 0, length: value.length)) ?? [])
            .compactMap { match in
                guard let url = URL(string: value.substring(with: match.range)) else { return nil }
                return OutputLink(range: match.range, url: url)
            }
    }
}

private final class OutputHeightKey: NSObject {
    let text: String
    let font: NSFont?
    let width: CGFloat
    init(text: String, font: NSFont?, width: CGFloat) {
        self.text = text; self.font = font; self.width = width
    }
    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(text); hasher.combine(font?.fontName)
        hasher.combine(font?.pointSize); hasher.combine(width)
        return hasher.finalize()
    }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? OutputHeightKey else { return false }
        return width == other.width && font == other.font && text == other.text
    }
}

private enum OutputHeightCache {
    static let values: NSCache<OutputHeightKey, NSNumber> = {
        let cache = NSCache<OutputHeightKey, NSNumber>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 256
        return cache
    }()
}

struct CommandClickableTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let textColor: NSColor

    static func clearCachedOutput() {
        OutputHeightCache.values.removeAllObjects()
        Task { await OutputLinkDetector.shared.clear() }
    }

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
        let contentChanged = textView.string != text
        if contentChanged {
            textView.linkDetectionTask?.cancel()
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: textColor]
            ))
            textView.usesOutputHeightCache = true
        }
        textView.textColor = textColor
        textView.font = font
        textView.invalidateIntrinsicContentSize()
        guard contentChanged else { return }
        if text.utf8.count <= 8192 {
            textView.installLinks(OutputLinkDetector.matches(text, detector: Self.detector))
        } else {
            textView.linkGeneration &+= 1
            let revision = textView.linkGeneration
            textView.linkDetectionTask = Task { @MainActor [weak textView, text] in
                let links = await OutputLinkDetector.shared.links(in: text)
                // Decoration is chunked so a link-heavy excerpt cannot replace
                // an off-main scan with one large main-thread attribute pass.
                for start in stride(from: 0, to: links.count, by: 128) {
                    guard !Task.isCancelled, let view = textView,
                          view.linkGeneration == revision else { return }
                    view.installLinks(Array(links[start..<min(start + 128, links.count)]))
                    await Task.yield()
                }
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: CommandClickableNSTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: textView.height(fitting: width))
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
}

final class CommandClickableNSTextView: NSTextView, NSTextStorageDelegate {
    fileprivate var linkDetectionTask: Task<Void, Never>?
    fileprivate var usesOutputHeightCache = false
    fileprivate var linkGeneration: UInt64 = 0
    fileprivate private(set) var contentRevision: UInt64 = 0
    private var decoratingLinks = false
    private var copiedRevision: UInt64?
    private var measuredRevision: UInt64?
    private var ownedStorage: NSTextStorage?

    convenience init() { self.init(frame: .zero, textContainer: nil) }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let actualContainer: NSTextContainer
        let retainedStorage: NSTextStorage?
        if let container {
            actualContainer = container
            retainedStorage = container.layoutManager?.textStorage
        } else {
            let storage = NSTextStorage()
            retainedStorage = storage
            let layout = NSLayoutManager()
            actualContainer = NSTextContainer(size: NSSize(width: 0, height: 10_000_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(actualContainer)
        }
        super.init(frame: frameRect, textContainer: actualContainer)
        ownedStorage = retainedStorage
        textStorage?.delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        textStorage?.delegate = self
    }

    deinit { linkDetectionTask?.cancel() }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        if !decoratingLinks { contentRevision &+= 1 }
    }

    fileprivate func installLinks(_ links: [OutputLink]) {
        guard let storage = textStorage else { return }
        decoratingLinks = true
        storage.beginEditing()
        for link in links { storage.addAttribute(.link, value: link.url, range: link.range) }
        storage.endEditing()
        decoratingLinks = false
    }
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
        if measuredRevision == contentRevision, measuredWidth == width { return measuredHeight }
        let key = usesOutputHeightCache ? OutputHeightKey(text: string, font: font, width: width) : nil
        if let key, let cached = OutputHeightCache.values.object(forKey: key) {
            measuredWidth = width
            measuredHeight = CGFloat(cached.doubleValue)
            measuredRevision = contentRevision
            return measuredHeight
        }
        if measurementLayout.textStorage == nil {
            measurementStorage.addLayoutManager(measurementLayout)
            measurementLayout.addTextContainer(measurementContainer)
            measurementContainer.lineFragmentPadding = 0
        }
        if copiedRevision != contentRevision {
            measurementStorage.setAttributedString(textStorage)
            copiedRevision = contentRevision
        }
        if measuredRevision != contentRevision || measuredWidth != width {
            // sizeThatFits is a measurement, not a layout pass. Resizing the
            // displayed NSTextView here invalidates SwiftUI's current proposal
            // and makes the enclosing lazy timeline's height oscillate.
            measurementContainer.containerSize = NSSize(width: width, height: 10_000_000)
            measurementLayout.ensureLayout(for: measurementContainer)
            measuredWidth = width
            measuredHeight = ceil(measurementLayout.usedRect(for: measurementContainer).height)
            measuredRevision = contentRevision
            if let key {
                OutputHeightCache.values.setObject(NSNumber(value: Double(measuredHeight)), forKey: key,
                                                  cost: string.utf16.count * 2)
            }
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
