import AppKit
import SwiftUI

struct CommandComposerView: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isFocused = false
    @State private var editorHeight: CGFloat = 24
    @State private var caretUTF16Offset = 0
    @State private var autocompleteSuggestions: [CommandAutocompleteSuggestion] = []
    @State private var autocompleteSelection = CommandAutocompleteSelection()
    @State private var suggestionsQuery: AutocompleteQuery?
    @State private var dismissedQuery: AutocompleteQuery?
    @State private var selectionRequest: ComposerSelectionRequest?

    private var canSubmit: Bool {
        session.isShellRunning
            && (presentedCommandBlock != nil
                || !session.commandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var autocompleteQuery: AutocompleteQuery {
        AutocompleteQuery(
            draft: session.commandDraft,
            caretUTF16Offset: min(
                max(0, caretUTF16Offset),
                (session.commandDraft as NSString).length
            ),
            isCommandActive: session.isCommandActive
        )
    }

    private var visibleSuggestions: [CommandAutocompleteSuggestion] {
        let query = autocompleteQuery
        guard !session.isSecureInputActive,
              !query.isCommandActive,
              query.hasCurrentToken,
              suggestionsQuery == query,
              dismissedQuery != query else { return [] }
        return autocompleteSuggestions
    }

    /// The first queued block represents a command sent to the shell whose
    /// lifecycle start marker has not arrived yet. Keeping it visible avoids
    /// an ambiguous idle composer during that short hand-off.
    private var presentedCommandBlock: CommandBlock? {
        if let activeBlock = session.activeCommandBlock {
            return activeBlock
        }
        return session.blocks.first { block in
            if case .queued = block.state { return true }
            return false
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        composerContent
            .padding(PaneMetrics.composerInnerInset)
            .background(.regularMaterial, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    isFocused ? Color(nsColor: .keyboardFocusIndicatorColor) : PaneTheme.separator,
                    lineWidth: isFocused || colorSchemeContrast == .increased ? 1.25 : 0.75
                )
            }
            .padding(.horizontal, PaneMetrics.composerOuterInset)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .task(id: autocompleteQuery) {
                await refreshAutocomplete(for: autocompleteQuery)
            }
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let commandBlock = presentedCommandBlock {
                ActiveCommandSurface(block: commandBlock, session: session)
                    .padding(.bottom, 6)
            }

            if session.isSecureInputActive {
                SecureInputIndicator()
                    .padding(.bottom, 4)
            } else if !visibleSuggestions.isEmpty {
                AutocompleteSuggestionsRow(
                    suggestions: visibleSuggestions,
                    highlightedSuggestionID: autocompleteSelection.highlightedSuggestionID,
                    onAccept: acceptSuggestion
                )
                .padding(.bottom, 4)
            }

            editorRow
        }
    }

    private var editorRow: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if session.isSecureInputActive {
                    EmptyView()
                } else if session.commandDraft.isEmpty {
                    Text(editorPlaceholder)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }

                if session.isSecureInputActive {
                    Text("Password input — characters are hidden")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                        .accessibilityLabel("Password input characters are hidden")
                } else {
                    composerTextView
                        .frame(height: editorHeight)
                        .help(editorHelp)
                }
            }
            .frame(minHeight: 40, maxHeight: 44, alignment: .center)
            .frame(maxWidth: .infinity, alignment: .leading)

            submitButton
        }
    }

    private var composerTextView: some View {
        ComposerTextView(
            text: $session.commandDraft,
            isFocused: $isFocused,
            measuredHeight: $editorHeight,
            selectionUTF16Offset: $caretUTF16Offset,
            selectionRequest: selectionRequest,
            shouldFocus: session.mode == .blocks,
            shouldRouteTerminalControlKeys: session.isCommandActive,
            onSubmit: { session.submitDraft() },
            onInterrupt: { session.sendInterrupt() },
            onEndOfFile: { session.sendEndOfFile() },
            onHistoryPrevious: historyPreviousAction,
            onHistoryNext: historyNextAction,
            onHandleTab: handleTabAutocomplete,
            onConfirmAutocomplete: confirmAutocomplete,
            onDismissAutocomplete: { dismissAutocomplete() }
        )
    }

    private var submitButton: some View {
        Button {
            guard !session.isSecureInputActive else { return }
            session.submitDraft()
        } label: {
            Image(systemName: presentedCommandBlock != nil ? "return" : "arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 15, height: 15)
        }
        .buttonStyle(ComposerSubmitButtonStyle())
        .frame(width: 28, height: 28)
        .disabled(session.isSecureInputActive || !canSubmit)
        .keyboardShortcut(.return, modifiers: [])
        .help(presentedCommandBlock != nil ? "Send input (Return)" : "Execute command (Return)")
    }

    private var historyPreviousAction: (() -> Void)? {
        guard presentedCommandBlock == nil else { return nil }
        return { session.historyPrevious() }
    }

    private var historyNextAction: (() -> Void)? {
        guard presentedCommandBlock == nil else { return nil }
        return { session.historyNext() }
    }

    private var isAwaitingContinuation: Bool {
        guard let block = presentedCommandBlock,
              block.id == session.activeCommandBlock?.id else { return false }
        if case .queued = block.state { return true }
        return false
    }

    private var editorPlaceholder: String {
        if session.isSecureInputActive {
            return "Password input — characters are hidden"
        }
        if isAwaitingContinuation {
            return "Continue the command…"
        }
        if let activeBlock = session.activeCommandBlock {
            return "Send input to \(activeBlock.processName)…"
        }
        if presentedCommandBlock != nil {
            return "Continue the command…"
        }
        return "Type a command…"
    }

    private var editorHelp: String {
        if session.isSecureInputActive {
            return "Password input — characters are hidden"
        }
        if isAwaitingContinuation {
            return "The shell is waiting for the rest of this command. Return sends the next line."
        }
        if session.isCommandActive {
            return "Return sends input to the active command. Shift-Return inserts a newline. Use Terminal mode for direct key input."
        }
        if presentedCommandBlock != nil {
            return "The shell is waiting for the rest of this command. Return sends the next line."
        }
        return "Return runs the command. Shift-Return inserts a newline. Tab and Shift-Tab select completions; Return accepts the selection. Up and Down browse history."
    }

    @MainActor
    private func refreshAutocomplete(for query: AutocompleteQuery) async {
        guard !session.isSecureInputActive,
              !query.isCommandActive,
              query.hasCurrentToken,
              dismissedQuery != query else {
            if suggestionsQuery != nil || !autocompleteSuggestions.isEmpty {
                suggestionsQuery = nil
                autocompleteSuggestions = []
                autocompleteSelection.reset()
            }
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(110))
        } catch {
            return
        }
        guard !Task.isCancelled, autocompleteQuery == query else { return }

        let suggestions = await session.autocompleteSuggestions(
            for: query.draft,
            cursorUTF16Offset: query.caretUTF16Offset
        )
        guard !Task.isCancelled, autocompleteQuery == query else { return }

        if suggestionsQuery != query {
            suggestionsQuery = query
            autocompleteSelection.reset()
        }
        if autocompleteSuggestions != suggestions {
            autocompleteSuggestions = suggestions
            if autocompleteSelection.selected(from: suggestions) == nil {
                autocompleteSelection.reset()
            }
        }
    }

    private func handleTabAutocomplete(by offset: Int) -> ComposerTabAutocompleteResult? {
        let suggestions = visibleSuggestions
        guard let action = autocompleteSelection.handleTab(
            by: offset,
            through: suggestions
        ) else { return nil }

        switch action {
        case .cycle:
            return .cycle
        case .accept(let suggestion):
            autocompleteSuggestions = []
            suggestionsQuery = nil
            let query = autocompleteQuery
            return .accept(session.autocompleteEdit(
                for: suggestion,
                in: query.draft,
                cursorUTF16Offset: query.caretUTF16Offset
            ))
        }
    }

    private func confirmAutocomplete(
        draft: String,
        cursorUTF16Offset: Int
    ) -> CommandAutocompleteEdit? {
        let query = AutocompleteQuery(
            draft: draft,
            caretUTF16Offset: cursorUTF16Offset,
            isCommandActive: session.isCommandActive
        )
        guard !session.isSecureInputActive,
              !query.isCommandActive,
              query.hasCurrentToken,
              suggestionsQuery == query,
              dismissedQuery != query,
              let suggestion = autocompleteSelection.selected(
                from: autocompleteSuggestions
              ) else { return nil }

        autocompleteSelection.reset()
        autocompleteSuggestions = []
        suggestionsQuery = nil

        return session.autocompleteEdit(
            for: suggestion,
            in: draft,
            cursorUTF16Offset: query.caretUTF16Offset
        )
    }

    private func dismissAutocomplete() -> Bool {
        let query = autocompleteQuery
        guard !visibleSuggestions.isEmpty else { return false }
        if dismissedQuery != query {
            dismissedQuery = query
        }
        autocompleteSelection.reset()
        return true
    }

    private func acceptSuggestion(_ suggestion: CommandAutocompleteSuggestion) {
        let query = autocompleteQuery
        guard !query.isCommandActive else { return }

        let edit = session.autocompleteEdit(
            for: suggestion,
            in: query.draft,
            cursorUTF16Offset: query.caretUTF16Offset
        )
        if session.commandDraft != edit.draft {
            session.commandDraft = edit.draft
        }
        selectionRequest = ComposerSelectionRequest(offset: edit.cursorUTF16Offset)
        autocompleteSelection.reset()
        autocompleteSuggestions = []
        suggestionsQuery = nil
    }
}


private struct SecureInputIndicator: View {
    var body: some View {
        Label("Password input — characters are hidden", systemImage: "lock.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityLabel("Secure input is active. Password input characters are hidden.")
    }
}

private struct AutocompleteQuery: Equatable {
    let draft: String
    let caretUTF16Offset: Int
    let isCommandActive: Bool

    var hasCurrentToken: Bool {
        guard !draft.isEmpty else { return false }
        let text = draft as NSString
        let offset = min(max(0, caretUTF16Offset), text.length)
        guard offset > 0 else { return false }

        let scalar = text.character(at: offset - 1)
        guard let unicodeScalar = UnicodeScalar(scalar) else { return true }
        return !CharacterSet.whitespacesAndNewlines.contains(unicodeScalar)
    }
}

private enum ComposerTabAutocompleteResult {
    case accept(CommandAutocompleteEdit)
    case cycle
}

private struct ComposerSelectionRequest: Equatable {
    let id = UUID()
    let offset: Int
}

private struct ActiveCommandSurface: View {
    let block: CommandBlock
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)

                Text(block.command.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusText(at: context.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(minHeight: 28)
            .padding(.horizontal, 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                isRunning ? "Running \(block.command)" : "Starting \(block.command)"
            )

            if isRunning, session.isAlternateScreenActive {
                Label("Interactive terminal session active", systemImage: "rectangle.inset.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
                    .accessibilityLabel("Interactive terminal session active in Terminal mode")
            } else if isRunning {
                LiveCommandTerminalViewRepresentable(session: session, blockID: block.id)
                    // NSViewRepresentable coordinators retain their immutable
                    // block ID. Explicit identity prevents SwiftUI from
                    // recycling a completed block's terminal for its successor.
                    .id(block.id)
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    .frame(height: liveTerminalHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private var isRunning: Bool {
        if case .running = block.state { return true }
        return false
    }

    private var liveTerminalHeight: CGFloat {
        if session.isAlternateScreenActive { return 52 }
        // One command-output row stays compact; the surface grows upward only
        // as output arrives, then scrolls inside its ten-row ceiling.
        return CGFloat(min(max(session.activeCommandVisibleLineCount, 1), 10)) * 17 + 24
    }

    private func statusText(at date: Date) -> String {
        guard let startedAt = block.startedAt else { return "Starting…" }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        if elapsed < 1 { return "Running" }
        if elapsed < 60 { return "Running for \(Int(elapsed))s" }
        let totalSeconds = Int(elapsed)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if hours > 0 {
            return "Active · \(hours)h \(minutes)m"
        }
        return "Active · \(minutes)m"
    }
}

private struct ComposerSubmitButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background(isPressed: configuration.isPressed))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(PaneTheme.separator.opacity(isEnabled ? 0.65 : 0.35), lineWidth: 0.75)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovered = $0 }
    }

    private func background(isPressed: Bool) -> Color {
        guard isEnabled else { return Color(nsColor: .controlBackgroundColor).opacity(0.35) }
        if isPressed { return PaneTheme.selectedBlockBackground }
        if isHovered { return Color.accentColor.opacity(0.16) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.78)
    }
}

private struct AutocompleteSuggestionsRow: View {
    let suggestions: [CommandAutocompleteSuggestion]
    let highlightedSuggestionID: String?
    let onAccept: (CommandAutocompleteSuggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(suggestions) { suggestion in
                        AutocompleteSuggestionButton(
                            suggestion: suggestion,
                            isHighlighted: suggestion.id == highlightedSuggestionID
                        ) {
                            onAccept(suggestion)
                        }
                        .id(suggestion.id)
                    }
                }
            }
            .onChange(of: highlightedSuggestionID) { _, suggestionID in
                guard let suggestionID else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(suggestionID, anchor: .center)
                }
            }
        }
        .frame(height: 25)
        .accessibilityLabel("Command suggestions")
    }
}

private struct AutocompleteSuggestionButton: View {
    let suggestion: CommandAutocompleteSuggestion
    let isHighlighted: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(suggestion.text)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)

                if let detail = suggestion.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 180, alignment: .leading)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background {
                if isHighlighted || isHovering {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isHighlighted
                                ? PaneTheme.selectedBlockBackground
                                : Color(nsColor: .quaternaryLabelColor)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
        .help(isHighlighted ? "Press Return to complete \(suggestion.text)" : "Complete \(suggestion.text)")
        .accessibilityValue(isHighlighted ? "Selected" : "")
    }

    private var symbolName: String {
        if suggestion.isDirectory { return "folder" }
        switch suggestion.source {
        case .zsh:
            return "sparkles"
        case .history:
            return "clock.arrow.circlepath"
        case .builtIn:
            return "terminal"
        case .executable:
            return "gearshape"
        case .fileSystem:
            return "doc"
        }
    }
}

private struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    @Binding var selectionUTF16Offset: Int
    let selectionRequest: ComposerSelectionRequest?
    let shouldFocus: Bool
    let shouldRouteTerminalControlKeys: Bool
    let onSubmit: () -> Void
    let onInterrupt: () -> Void
    let onEndOfFile: () -> Void
    let onHistoryPrevious: (() -> Void)?
    let onHistoryNext: (() -> Void)?
    let onHandleTab: (_ offset: Int) -> ComposerTabAutocompleteResult?
    let onConfirmAutocomplete: (_ draft: String, _ cursorUTF16Offset: Int) -> CommandAutocompleteEdit?
    let onDismissAutocomplete: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scrollView = ComposerScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: measuredHeight)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(
            width: PaneMetrics.composerTextInset,
            height: 2
        )
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        textView.delegate = context.coordinator
        textView.shouldRouteTerminalControlKeys = shouldRouteTerminalControlKeys
        textView.onSubmit = onSubmit
        textView.onInterrupt = onInterrupt
        textView.onEndOfFile = onEndOfFile
        textView.onHistoryPrevious = onHistoryPrevious
        textView.onHistoryNext = onHistoryNext
        textView.onHandleTab = onHandleTab
        textView.onConfirmAutocomplete = onConfirmAutocomplete
        textView.onDismissAutocomplete = onDismissAutocomplete
        scrollView.documentView = textView
        context.coordinator.isMounted = true

        scrollView.onLayout = { [
            weak scrollView,
            weak textView,
            weak coordinator = context.coordinator
        ] in
            guard let scrollView, let textView else { return }
            coordinator?.scheduleHeightMeasurement(textView: textView, scrollView: scrollView)
        }
        context.coordinator.scheduleHeightMeasurement(textView: textView, scrollView: scrollView)
        context.coordinator.scheduleSelectionUpdate(from: textView)
        context.coordinator.requestInitialFocus(for: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.shouldRouteTerminalControlKeys = shouldRouteTerminalControlKeys
        textView.onSubmit = onSubmit
        textView.onInterrupt = onInterrupt
        textView.onEndOfFile = onEndOfFile
        textView.onHistoryPrevious = onHistoryPrevious
        textView.onHistoryNext = onHistoryNext
        textView.onHandleTab = onHandleTab
        textView.onConfirmAutocomplete = onConfirmAutocomplete
        textView.onDismissAutocomplete = onDismissAutocomplete

        if textView.string != text {
            context.coordinator.synchronizeText(text, in: textView)
        }
        context.coordinator.applySelectionRequest(selectionRequest, to: textView)

        context.coordinator.scheduleHeightMeasurement(textView: textView, scrollView: scrollView)

        context.coordinator.requestInitialFocus(for: textView)
    }

    static func dismantleNSView(_ scrollView: ComposerScrollView, coordinator: Coordinator) {
        coordinator.isMounted = false
        scrollView.onLayout = nil
        if let textView = scrollView.documentView as? ComposerNSTextView {
            textView.delegate = nil
            textView.shouldRouteTerminalControlKeys = false
            textView.onSubmit = nil
            textView.onInterrupt = nil
            textView.onEndOfFile = nil
            textView.onHistoryPrevious = nil
            textView.onHistoryNext = nil
            textView.onHandleTab = nil
            textView.onConfirmAutocomplete = nil
            textView.onDismissAutocomplete = nil
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        private var heightUpdateQueued = false
        private var isSynchronizingFromSwiftUI = false
        private var focusRequestQueued = false
        private var didRequestInitialFocus = false
        private var selectionUpdateQueued = false
        private var lastSelectionRequestID: UUID?
        var isMounted = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizingFromSwiftUI,
                  let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            guard let scrollView = textView.enclosingScrollView as? ComposerScrollView else { return }
            scheduleHeightMeasurement(textView: textView, scrollView: scrollView)
            scheduleSelectionUpdate(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            scheduleSelectionUpdate(from: textView)
        }

        func synchronizeText(_ text: String, in textView: NSTextView) {
            isSynchronizingFromSwiftUI = true
            defer { isSynchronizingFromSwiftUI = false }

            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func applySelectionRequest(
            _ request: ComposerSelectionRequest?,
            to textView: NSTextView
        ) {
            guard let request,
                  lastSelectionRequestID != request.id else { return }
            lastSelectionRequestID = request.id

            let offset = min(max(0, request.offset), (textView.string as NSString).length)
            let selection = NSRange(location: offset, length: 0)
            if textView.selectedRange() != selection {
                textView.setSelectedRange(selection)
                textView.scrollRangeToVisible(selection)
            }
            requestFocus(for: textView)
        }

        func scheduleSelectionUpdate(from textView: NSTextView) {
            guard isMounted, !selectionUpdateQueued else { return }
            selectionUpdateQueued = true

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.selectionUpdateQueued = false
                guard self.isMounted, let textView else { return }
                let offset = min(
                    max(0, textView.selectedRange().location),
                    (textView.string as NSString).length
                )
                if self.parent.selectionUTF16Offset != offset {
                    self.parent.selectionUTF16Offset = offset
                }
            }
        }

        private func requestFocus(for textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self,
                      self.isMounted,
                      self.parent.shouldFocus,
                      let textView,
                      let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard isMounted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isMounted else { return }
                if !self.parent.isFocused {
                    self.parent.isFocused = true
                }
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard isMounted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isMounted else { return }
                if self.parent.isFocused {
                    self.parent.isFocused = false
                }
            }
        }

        func requestInitialFocus(for textView: NSTextView) {
            guard isMounted,
                  parent.shouldFocus,
                  !didRequestInitialFocus,
                  !focusRequestQueued else { return }
            focusRequestQueued = true

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.focusRequestQueued = false
                guard self.isMounted,
                      self.parent.shouldFocus,
                      let textView,
                      let window = textView.window else { return }
                if window.firstResponder === textView || window.makeFirstResponder(textView) {
                    self.didRequestInitialFocus = true
                }
            }
        }

        func scheduleHeightMeasurement(
            textView: NSTextView,
            scrollView: ComposerScrollView
        ) {
            guard !heightUpdateQueued else { return }
            heightUpdateQueued = true

            DispatchQueue.main.async { [weak self, weak textView, weak scrollView] in
                guard let self, self.isMounted else { return }
                self.heightUpdateQueued = false
                guard let textView, let scrollView else { return }
                self.measureHeight(textView: textView, scrollView: scrollView)
            }
        }

        private func measureHeight(textView: NSTextView, scrollView: ComposerScrollView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let width = max(1, scrollView.contentView.bounds.width)
            if abs(textView.frame.width - width) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            }

            textContainer.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textContainer.widthTracksTextView = true
            layoutManager.ensureLayout(for: textContainer)

            let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            let lineHeight = layoutManager.defaultLineHeight(for: font)
            let laidOutHeight = max(
                layoutManager.usedRect(for: textContainer).maxY,
                layoutManager.extraLineFragmentRect.maxY
            )
            let verticalInsets = textView.textContainerInset.height * 2
            let rawHeight = ceil(max(lineHeight, laidOutHeight) + verticalInsets)
            let minimumHeight = ceil(lineHeight + verticalInsets)
            let maximumHeight = ceil((lineHeight * 3) + verticalInsets)
            let targetHeight = min(max(rawHeight, minimumHeight), maximumHeight)

            let needsScroller = rawHeight > maximumHeight
            if scrollView.hasVerticalScroller != needsScroller {
                scrollView.hasVerticalScroller = needsScroller
            }

            let documentHeight = max(rawHeight, scrollView.contentView.bounds.height)
            if abs(textView.frame.width - width) > 0.5
                || abs(textView.frame.height - documentHeight) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: documentHeight))
            }

            if abs(parent.measuredHeight - targetHeight) > 0.5 {
                parent.measuredHeight = targetHeight
            }
        }
    }
}

private final class ComposerScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class ComposerNSTextView: NSTextView {
    var shouldRouteTerminalControlKeys = false
    var onSubmit: (() -> Void)?
    var onInterrupt: (() -> Void)?
    var onEndOfFile: (() -> Void)?
    var onHistoryPrevious: (() -> Void)?
    var onHistoryNext: (() -> Void)?
    var onHandleTab: ((_ offset: Int) -> ComposerTabAutocompleteResult?)?
    var onConfirmAutocomplete: ((_ draft: String, _ cursorUTF16Offset: Int) -> CommandAutocompleteEdit?)?
    var onDismissAutocomplete: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleTerminalControlKey(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }

        if handleTerminalControlKey(event) {
            return
        }

        switch event.keyCode {
        case 36, 76:
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else if let edit = confirmedAutocompleteEdit() {
                applyAutocompleteEdit(edit)
            } else {
                onSubmit?()
            }
        case 48:
            let modifiers = event.modifierFlags.intersection([
                .command, .option, .control, .shift
            ])
            let direction = modifiers.isEmpty ? 1 : (modifiers == .shift ? -1 : 0)
            if direction == 0 {
                super.keyDown(with: event)
            } else if let result = onHandleTab?(direction) {
                switch result {
                case .accept(let edit):
                    applyAutocompleteEdit(edit)
                case .cycle:
                    break
                }
            } else {
                super.keyDown(with: event)
            }
        case 53:
            if onDismissAutocomplete?() != true {
                super.keyDown(with: event)
            }
        case 126 where event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty:
            if let onHistoryPrevious {
                onHistoryPrevious()
            } else {
                super.keyDown(with: event)
            }
        case 125 where event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty:
            if let onHistoryNext {
                onHistoryNext()
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    private func handleTerminalControlKey(_ event: NSEvent) -> Bool {
        guard shouldRouteTerminalControlKeys,
              let action = TerminalControlKeyRouter.action(for: event) else {
            return false
        }
        switch action {
        case .interrupt:
            onInterrupt?()
        case .endOfFile:
            onEndOfFile?()
        }
        return true
    }

    private func applyAutocompleteEdit(_ edit: CommandAutocompleteEdit) {
        let currentLength = (string as NSString).length
        let fullRange = NSRange(location: 0, length: currentLength)
        guard shouldChangeText(in: fullRange, replacementString: edit.draft) else { return }

        textStorage?.replaceCharacters(in: fullRange, with: edit.draft)
        didChangeText()

        let caret = min(
            max(0, edit.cursorUTF16Offset),
            (edit.draft as NSString).length
        )
        let selection = NSRange(location: caret, length: 0)
        setSelectedRange(selection)
        scrollRangeToVisible(selection)
    }

    private func confirmedAutocompleteEdit() -> CommandAutocompleteEdit? {
        let caret = min(
            max(0, selectedRange().location),
            (string as NSString).length
        )
        return onConfirmAutocomplete?(string, caret)
    }
}

enum TerminalControlKeyRouter {
    enum Action: Equatable {
        case interrupt
        case endOfFile
    }

    static func action(for event: NSEvent) -> Action? {
        let modifiers = event.modifierFlags.intersection([
            .command, .option, .control, .shift
        ])
        guard modifiers == .control else { return nil }

        // Physical key codes make this independent of keyboard layout; the
        // character fallback also supports synthesized/AppKit key events.
        switch event.keyCode {
        case 8:
            return .interrupt
        case 2:
            return .endOfFile
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": return .interrupt
            case "d": return .endOfFile
            default: return nil
            }
        }
    }
}
