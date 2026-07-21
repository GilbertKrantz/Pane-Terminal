# Pane — Apple-native block terminal

## Design intent

Pane combines a structured command timeline with a real terminal emulator. The terminal remains the dominant workspace; native chrome and material are reserved for controls rather than used as decoration.

The product has two explicit modes:

- **Blocks** is the primary composed-command experience. The current command stays live in the pinned composer; only finalized commands, plain-text output, working directory, duration, and completion state become navigable timeline units.
- **Terminal** exposes SwiftTerm directly for Vim, `less`, `top`, SSH, `fzf`, password prompts, REPLs, terminal coding agents, and other character-at-a-time programs.

The bottom composer is the only typing surface in Blocks mode. Terminal mode gives focus to SwiftTerm and replaces the composer with a compact return strip.

## One visual hierarchy

The implemented interface uses three layers only:

1. **Native title and toolbar** — macOS traffic lights, window title, shell status, the Blocks/Terminal segmented control, and one actions menu.
2. **Main terminal content surface** — one uninterrupted semantic surface containing either the bottom-anchored finalized-block timeline or the authoritative live SwiftTerm view.
3. **Bottom interactive material** — one floating composer containing the draft or active command in Blocks mode, or one compact mode strip in Terminal mode.

The terminal canvas has no material wrapper, outer card, decorative stroke, or nested rounded container. Blocks may gain a restrained semantic hover or selection surface, but they remain within the same terminal plane.

## Color scheme: Graphite + System Accent

Graphite is the neutral direction; the user's macOS accent supplies focus and primary action color. The implementation uses semantic system colors rather than fixed RGB values.

| Role | Native source | Use |
| --- | --- | --- |
| Content surface | `textBackgroundColor` | Terminal canvas and block viewport |
| Terminal text | `textColor` | SwiftTerm foreground |
| Primary labels | SwiftUI primary / `labelColor` | Commands and important controls |
| Secondary labels | SwiftUI secondary / `secondaryLabelColor` | Paths, metadata, help text |
| Hovered block | `controlBackgroundColor` | Temporary pointer affordance |
| Selected block | `unemphasizedSelectedContentBackgroundColor` | Keyboard and pointer selection |
| Separators | `separatorColor` | Composer outline and restrained boundaries |
| Focus and execute | `controlAccentColor` / keyboard focus color | Focus ring, caret, enabled execute action |
| Success / failure / interrupt | System green, red, and orange | Status, always paired with a symbol or text |

The result follows Aqua in light mode and Dark Aqua in dark mode. Native material provides the system's Reduce Transparency fallback, while semantic colors and an explicit stronger composer outline respond to increased contrast.

## Layout and optical alignment

The default window is 1120 × 720 points and the minimum is 760 × 520.

Pane aligns content by its text, not by the outside edge of every shape:

- Terminal text: 24-point leading and trailing inset.
- Block text: 12-point block-list inset plus 12-point block internal inset, yielding the same 24-point text column.
- Composer input: 18-point outer inset plus 6-point internal inset, also yielding 24 points.
- Main content top inset: 8 points.
- Composer separation: 6 points above and 10 points below, keeping it close to the terminal without touching the window edge.

These values form one alignment system while allowing the block and composer shapes to use different optical edges.

## Native toolbar

- Preserve the standard macOS traffic-light area and unified compact toolbar style.
- Keep shell status quiet: a six-point status dot and a short secondary process label.
- On macOS 26, use real interactive Liquid Glass for the custom **Blocks / Terminal** capsule and actions button, and hide the toolbar's automatic shared background to avoid nested glass pills.
- On macOS 14 and 15, fall back to a small native segmented `Picker` and borderless actions menu; do not imitate Liquid Glass.
- Put clear, interrupt, and restart actions in one borderless ellipsis menu.
- Keep lifecycle actions available in the native **Terminal** command menu with keyboard shortcuts.
- Keep Liquid Glass and material confined to controls; do not place either over the terminal surface.

The application identity follows the same native rule. `AppIcon.appiconset` supplies every macOS icon rendition, the app target is configured to declare `AppIcon`, and launch assigns that compiled icon to `NSApplication` as a runtime fallback for Dock, App Expose, and window previews. The bundled `.app`, never its bare Mach-O executable, is the supported launch unit.

## Main content surface

`ContentView` owns one persistent `ZStack`. The `PaneTerminalView` is created once and remains mounted; Blocks mode places the structured timeline above it and disables terminal hit testing. Terminal mode hides the block layer and exposes the same emulator instance.

This persistent identity is part of the visual design, not only an implementation detail: scrollback, cursor state, and normal/alternate terminal buffers must survive a mode change without a flash, transcript replay, or replacement view.

### Command blocks

Each block contains:

1. A compact header with working directory, a permanently reserved 116-point contextual-action slot, and status/duration.
2. The exact submitted command in a medium monospaced style.
3. Sanitized plain-text output when present and expanded.

Inactive blocks are transparent. Hover uses one semantic control surface. Selection uses one semantic selected surface plus a one-point system focus outline. The contextual toolbar appears by opacity only, so command, path, and status geometry never moves on hover.

Running and queued entries are filtered out of this surface. The timeline uses a bottom default scroll anchor, so a short history rests above the composer and overflow grows upward. When the active command finalizes, its completed or interrupted entry becomes visible and scrolls into the bottom position.

Status always combines color with a symbol, progress indicator, text, exit code, or duration. Color is never the only signal.

The implemented block actions are:

- copy output
- rerun command
- copy command
- edit in composer
- collapse or expand output
- delete block

Search, export, and share are intentionally not presented because they are not implemented.

## Unified bottom composer

The composer is one coherent native control platter:

- One continuous 12-point rounded shape.
- One `.regularMaterial` background clipped to that shape.
- One light matching outline on the exact same shape, strengthened for focus and increased contrast.
- No dark card behind the material.
- No separate material around the text editor.
- No separate material around the execute button.

The embedded `NSTextView` draws no background and therefore remains inside the continuous material. It uses the native text system for selection, undo, input methods, focus, copy, and paste.

When idle, the composer contains suggestions, the draft editor, and an `arrow.up` execute action. While a command is active, it adds a vertically centered command-and-human-duration header plus a read-only SwiftTerm mirror above the editor; the action changes to `return` and the editor sends line-oriented stdin. The mirror has 12–14 points of internal padding, begins at one 17-point output row plus its inset, and grows upward only as newline-delimited output arrives through a ten-row ceiling. Its unusable embedded scroller is hidden; the authoritative Terminal-mode view retains a native overlay scroller. Alternate-screen activation switches to that authoritative view and uses a quiet interactive-session status during the transition instead of presenting an empty mirror. The active surface disappears only when the command completes, is interrupted, or the shell terminates, at which point its output is finalized into the timeline.

The editor begins at one line in a 40-point row, grows with wrapping and explicit newlines through three visible lines, then enables an overlay scroller. Its height publication is deferred from AppKit layout and emitted only when the measured value changes materially.

The idle execute action:

- uses the SF Symbol `arrow.up`
- is a 28-point neutral rounded-square control with subtle hover and press feedback
- is vertically centered within the composer `HStack`
- receives the same six-point internal inset as the editor
- stays inside the shared material group
- is disabled and visually reduced when the command is empty or the shell is stopped
- supplements Return rather than replacing keyboard execution

Return executes an idle draft or sends one line to an active command. Shift-Return inserts a newline; bracketed-paste submission keeps a multiline draft inside one zsh line-editor buffer and one eventual block. If zsh is waiting for incomplete syntax before `preexec`, each Return appends a continuation line to that same queued command and history entry. Only while a foreground command is active or awaiting continuation, Control-C and Control-D are intercepted ahead of AppKit's key-equivalent and `NSTextView` paths and sent as `ETX` or `EOT`; idle composer keys keep native editor behavior. Control-C finalizes a cancelled continuation or status-130 command as interrupted while preserving any unsent draft. Unmodified Up and Down navigate session history only while idle.

Idle autocomplete waits 110 ms after the current token changes and then presents at most 12 deduplicated results from zsh's own context-sensitive completion system. Tab and Shift-Tab move a separate keyboard highlight without editing the draft, Return accepts the highlighted result, Escape dismisses the current query, and clicking accepts a specific result.

Each active shell generation owns a private Unix-domain socket. Pane sends completion requests over that socket rather than injecting bytes into the main PTY. A normal `zle -F` handler in the active warm zsh accepts the bounded request and forks a short-lived `zpty` worker from that process. The worker therefore inherits the authoritative shell's live working directory, parameters and environment, aliases, functions, options, and loaded completion definitions before running `compsys` and returning encoded candidates. It cannot mutate the visible ZLE buffer, command history, terminal buffers, or PTY transcript.

Requests, candidate counts, and responses are capped, and capture has a short deadline. Stale shell generations and late responses are discarded. If the socket integration, worker, response decoding, or completion system fails or times out, the UI falls back to deterministic local history, built-in, `PATH`, and filesystem prefix matching. Completion-only child-process side effects are intentionally discarded when the worker exits.

## Terminal and alternate-screen rendering

SwiftTerm is the sole renderer and owner of terminal buffers. Pane never constructs terminal frames in SwiftUI and never replays a transcript through `updateNSView`.

The PTY data path has two independent branches:

- The raw branch feeds every byte exactly once to the mounted SwiftTerm view.
- The structured branch passes a copy through `AlternateScreenTranscriptFilter` and the OSC block parser.

Autocomplete is a third, control-only path over the private per-shell Unix socket. Neither completion requests nor candidate responses travel through SwiftTerm or the main PTY, so completion cannot become terminal output or alter emulator replay and buffer switching.

During an active Blocks-mode command, parsed ordinary output also feeds a second, presentation-only SwiftTerm emulator in the composer. That mirror has no terminal delegate, PTY ownership, resize authority, terminal replies, mouse reporting, or input. The persistent terminal remains authoritative. The mirror improves ordinary ANSI and carriage-return rendering before Pane extracts one plain-text snapshot at finalization, but its filtered stream and independent geometry cannot promise an identical view for cursor-addressed or full-screen programs.

When SwiftTerm activates a new buffer, `PaneTerminalView.bufferActivated` requests a complete emulator update and invalidates the whole AppKit and layer drawing surface. It then defers the SwiftUI mode notification until the next main-loop turn. This prevents the previous buffer's cells from being composited while SwiftTerm's repaint is pending and avoids re-entrant observable publication from `TerminalView.feed()`.

Required semantics are preserved:

- `ESC[?1049h` activates a clean alternate buffer; normal-buffer content is not visible or copied into it.
- Alternate-screen output remains only in the alternate buffer.
- `ESC[?1049l` restores the unchanged normal buffer.
- DEC modes 47, 1047, and 1049 can trigger automatic Terminal mode.
- Manual mode choice always overrides automatic return behavior.

The structured transcript suppresses alternate-screen frame bytes and emits one `[Alternate screen active]` placeholder on each inactive-to-active transition. Private OSC lifecycle markers continue through the filter so the command block still receives its completion event.

## SwiftUI and AppKit state boundary

Terminal engine state remains in SwiftTerm, `PaneTerminalView`, and the representable coordinator. SwiftUI observes coarse application state only: mode, shell status, title, working directory, command draft, selection, block timeline, whether an alternate buffer is active, and the active mirror's bounded one-to-ten visible-row estimate.

The implementation follows these update rules:

- `makeNSView` creates the emulator once and defers session attachment.
- `updateNSView` performs no PTY writes, terminal feeds, transcript replay, or resize feedback.
- Palette changes are applied only when the effective light/dark appearance changes.
- Visibility and first-responder changes are deduplicated and deferred.
- Alternate-buffer notifications are deduplicated, generation-checked, and deferred.
- Terminal title, working directory, mode, and PTY dimensions publish only when their value changes.
- Composer focus and height bindings are updated outside synchronous representable and layout callbacks.
- Active bytes remain outside observable SwiftUI state, and pending data is coalesced into a single next-main-loop mirror feed. Only the bounded visible-row estimate can publish during execution—at most nine layout changes per command—and final block output publishes once when lifecycle markers close the command.
- App termination cleans up the shell through `NSApplicationDelegate`, not a SwiftUI `onDisappear` mutation.

These constraints prevent feedback loops and keep high-frequency terminal frames outside SwiftUI's observation graph.

## Native behavior and accessibility

- Use SF Symbols and standard controls for all actions.
- Preserve native focus, keyboard navigation, input methods, selection, copy/paste, and undo.
- Use semantic system colors and appearance-aware SwiftTerm foreground/background colors.
- Keep hover actions available through selection, contextual menus, toolbar actions, and command-menu shortcuts.
- Provide accessibility labels for shell status and block command/status.
- Respect Retina backing scale when communicating PTY pixel dimensions.
- Use the system material response for Reduce Transparency and a stronger composer outline for increased contrast.
- Maintain usable layout at the 760 × 520 minimum window size and during dynamic resizing.

## Scope and current limits

Pane intentionally excludes tabs, AI completion, synchronization, collaboration, remote-session management, settings, search, export, and share. Automatic mode selection uses a deliberately bounded set of foreground process names plus PTY termios and alternate-screen signals; it is not a general process classifier. Autocomplete is shell-semantic through zsh `compsys`, but remains bounded by a short timeout and size caps; its deterministic local prefix engine is a failure fallback rather than the primary source.

The active mirror is read-only, and the Blocks editor sends complete lines rather than raw keystrokes. Active-only Control-C and Control-D are deliberate exceptions that route `ETX` and `EOT` directly from the composer; other control sequences, arrows, Escape, Tab, mouse events, terminal replies, password privacy, and character-at-a-time input belong in Terminal mode. Pane switches automatically for alternate-screen protocols 47, 1047, and 1049, recognized foreground programs, and raw PTY termios. Programs that expose none of those signals still require the manual mode control, which remains authoritative until foreground state changes. Commands typed directly in Terminal mode do not become blocks.

Finalized blocks are plain-text snapshots rather than interactive ANSI terminal fragments. Cursor-addressed output and full-screen applications can differ in the mirror and belong in the authoritative Terminal mode. Visual behavior across macOS 14 and 15 fallbacks, macOS 26 Liquid Glass, accessibility appearances, and window sizes still requires a local human pass when automated control is unavailable without macOS Accessibility and Screen Recording permission.
