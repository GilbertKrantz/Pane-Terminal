# Pane

Pane is a native macOS terminal that combines structured, Warp-style command blocks with Apple interface conventions. Terminal content occupies one continuous surface, while a multiline command composer stays pinned at the bottom. A submitted command remains live in that composer until it finishes or is interrupted, then becomes a finalized block in the timeline above it.

One long-running `/bin/zsh -l -i` process runs inside a real pseudoterminal. Pane does not execute commands as isolated subprocesses, so `cd`, aliases, functions, exports, virtual environments, and other shell state persist for the session.

See [DESIGN.md](DESIGN.md) for the implemented visual hierarchy, semantic color system, spacing, and rendering boundaries.

## Requirements

- macOS 14 or newer
- Xcode 26 or newer with the macOS 26 SDK installed; the built app still runs on macOS 14 or newer
- Network access the first time Swift Package Manager resolves dependencies

The project pins [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) `1.14.0` exactly. App Sandbox is intentionally disabled because a useful local shell needs access to the user's executables and filesystem.

If Xcode reports a missing Metal toolchain while compiling SwiftTerm, install Apple's optional component once:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Setup, build, and run

### Open the app project directly

Open `Pane.xcodeproj` itself, not the containing folder and not `Package.swift`.

SwiftPM intentionally exposes only the non-runnable `PaneCore` library for command-line builds and tests. The `@main` app entry point, bundle identifier, signing, and macOS application lifecycle belong to the Xcode target. Opening the package alone will not offer a runnable Pane GUI product.

1. Open `Pane.xcodeproj`.
2. Let Xcode resolve SwiftTerm.
3. Select the `Pane` scheme and **My Mac**.
4. Press **Command-R** to build and run the bundled app.
5. Press **Command-U** to run the Xcode test target.

For local signing, choose your development team or use **Sign to Run Locally**. No custom entitlements are required.

### Command line

SwiftPM supports dependency resolution, compilation of `PaneCore`, and the test suite:

```sh
swift package resolve
swift build
swift test
```

To build the macOS app bundle from a shell at a predictable DerivedData location:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project Pane.xcodeproj \
  -scheme Pane \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$PWD/DerivedData" \
  build
```

The resulting app is `DerivedData/Build/Products/Debug/Pane.app` inside the checkout. In this workspace its exact path is `/Users/chandraw/Documents/Webe's Term/DerivedData/Build/Products/Debug/Pane.app`. Quit any older Pane process, then launch that bundle:

```sh
open "$PWD/DerivedData/Build/Products/Debug/Pane.app"
```

The latest verified Debug bundle from this implementation pass was also copied to `/Users/chandraw/Documents/Webe's Term/Build/Pane.app` for direct use. It has the stable bundle identifier `com.gilbertkrantz.Pane`; `Build/` is ignored because it is a generated product.

SwiftPM deliberately exposes no GUI executable. Run `Pane.app` from Xcode or with `open`; do not launch `Pane.app/Contents/MacOS/Pane` directly. The bundle supplies the application identity, icon resources, and AppKit lifecycle. `Assets.xcassets/AppIcon.appiconset` contains the complete macOS icon set, and the app also assigns the compiled `AppIcon.icns` at launch so the Dock, App Expose, and window previews use the Pane icon.

## Architecture

```text
Pane/
├── App/
│   └── PaneApp.swift
├── Assets.xcassets/
│   └── AppIcon.appiconset/
├── Models/
│   ├── CommandAutocomplete.swift
│   ├── CommandBlock.swift
│   ├── CommandHistory.swift
│   └── InputMode.swift
├── Terminal/
│   ├── AlternateScreenTranscriptFilter.swift
│   ├── BlockOutputSanitizer.swift
│   ├── BlockStreamParser.swift
│   ├── CommandSerializer.swift
│   ├── ShellConfiguration.swift
│   ├── ShellIntegration.swift
│   ├── TerminalSession.swift
│   ├── TerminalViewRepresentable.swift
│   └── WarmZshCompletionClient.swift
└── Views/
    ├── BlocksView.swift
    ├── CommandBlockView.swift
    ├── CommandComposerView.swift
    ├── ContentView.swift
    └── ModeIndicatorView.swift

Tests/
└── PaneTests/
```

- `TerminalSession` owns the SwiftTerm `LocalProcess`, PTY lifecycle, command writes, resize propagation, input mode, history, block timeline, transcript filtering, and cleanup.
- `PaneTerminalView` is a small SwiftTerm `TerminalView` subclass that observes real buffer activation and invalidates the complete native drawing surface when the active buffer changes.
- `TerminalViewRepresentable` creates one terminal view and keeps it mounted across SwiftUI refreshes and mode changes. Its update callback does not feed a transcript, recreate emulator state, or resize the PTY.
- `AlternateScreenTranscriptFilter` separates full-screen frames from the structured Blocks transcript without changing the byte stream delivered to SwiftTerm.
- `ShellIntegration` installs additive zsh `preexec` and `precmd` hooks. Private OSC 777 markers identify command start and completion without replacing Oh My Zsh hooks. It also registers a normal `zle -F` completion handler on a private per-shell Unix-domain socket.
- `BlockStreamParser` removes those markers from captured output and updates working directory, exit status, and timing.
- `CommandBlockTimeline` manages queued, running, completed, and interrupted blocks.
- `CommandAutocomplete` presents at most 12 deduplicated candidates captured from the active zsh completion system. A bounded local history, command, executable, and filesystem engine remains available when warm-shell capture is unavailable.
- `CommandComposerView` wraps a native `NSTextView`; it grows from one through six visible lines, then scrolls. While a command is active, it also hosts a read-only SwiftTerm mirror and changes the editor into line-oriented stdin.

PTY bytes have two deliberately separate destinations:

1. Every byte is fed exactly once to SwiftTerm, which exclusively owns the live normal and alternate terminal buffers.
2. A filtered copy is parsed into plain-text command blocks. Alternate-screen frames never enter that transcript.

## Interface hierarchy

Pane uses three visual layers:

1. The native macOS title and toolbar area, including shell status, the Blocks/Terminal segmented control, and a restrained actions menu.
2. One uninterrupted terminal content surface for either the structured block timeline or SwiftTerm.
3. A bottom interactive material layer: the command composer in Blocks mode or a compact return strip in Terminal mode.

The terminal canvas has no glass wrapper. On macOS 26, the mode switcher and toolbar actions use the system's real interactive Liquid Glass and suppress the toolbar's automatic shared background to avoid nested capsules. On macOS 14 and 15, Pane falls back to a native segmented picker and borderless menu. The bottom composer uses one continuous rounded `.regularMaterial` on every supported release, with one matching outline, a transparent native text editor, and one centered SF Symbol action inside the same group.

Terminal text, block text, and composer input share the same optical 24-point leading column. Colors come from semantic AppKit values and the user's macOS accent, so light mode, dark mode, increased contrast, and Reduce Transparency retain native behavior.

## Modes and keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| **Return** | Accept the highlighted autocomplete suggestion; otherwise run an idle draft or send one line to the active command |
| **Shift-Return** | Insert a composer newline |
| **Tab / Shift-Tab** | Select the next / previous visible autocomplete suggestion without changing the draft |
| **Escape** | Dismiss visible autocomplete suggestions; otherwise use normal text behavior |
| **Up / Down** | Navigate session command history while no command is active |
| **Command-Shift-I** | Toggle Blocks / Terminal mode |
| **Command-Up / Command-Down** | Select the previous / next block |
| **Command-Return** | Rerun the selected block |
| **Command-E** | Put the selected command in the composer |
| **Control-C** | Interrupt the active Blocks command, or send `ETX` directly in Terminal mode |
| **Control-D** | Send `EOT` to the active Blocks command, or directly in Terminal mode |
| **Command-K** | Clear blocks or the terminal for the current mode |
| **Command-Shift-R** | Restart the login shell |

Option acts as Meta in Terminal mode. The native toolbar and **Terminal** menu expose the primary mode and lifecycle actions without requiring pointer input.

### Blocks mode

When the shell is idle, Return writes the complete draft followed by one carriage return to the existing PTY. Shift-Return inserts a literal newline in the draft; multiline submission uses bracketed paste so the entire draft reaches zsh as one line-editor buffer, one shell lifecycle, and one eventual block. The composer clears only after the bytes are accepted, and command history persists for the current app session.

The submitted command first occupies an active surface inside the bottom composer. That surface shows its command, elapsed time, and a read-only terminal mirror that grows upward from one output row through ten, then scrolls within that ceiling. The editor below sends line-oriented stdin. Running and queued commands are deliberately omitted from the timeline. When the command completes, is interrupted, or the shell exits, its captured output and final status become a normal block above the composer.

If zsh requests more syntax before `preexec`—for example, after `if true; then`—the composer shows **Continue the command…**. Each Return sends the next line and appends it to the same queued command and history entry instead of creating another block. Only while a command is active or awaiting continuation, Control-C and Control-D are intercepted above AppKit's key-equivalent and text-editor paths and sent to the PTY as `ETX` or `EOT`. Control-C therefore cancels a continuation or requests interruption of a running command without changing any unsent draft; status 130 finalizes as interrupted. When the Blocks composer is idle, those keys retain normal macOS editor behavior. Other character-at-a-time input still belongs in Terminal mode.

The finalized timeline is bottom-anchored: a short history rests next to the composer, a newly finalized block scrolls to the bottom, and older content overflows upward. Hovering or selecting a block reveals copy output, rerun, collapse/expand, and overflow actions in a permanently reserved header slot, so disclosure changes opacity without moving block content. The overflow menu contains copy command, edit in composer, and delete.

Autocomplete appears only while the shell is idle and the caret follows a non-whitespace token. After a 110 ms debounce, Pane asks the active zsh for context-sensitive `compsys` candidates and shows up to 12 deduplicated results. Tab and Shift-Tab move the highlight forward and backward without changing the draft, Return accepts the highlighted result, Escape dismisses the current set, and any visible suggestion can be clicked.

The persistent PTY shell remains authoritative. Pane creates a private Unix-domain socket for each shell generation and sends completion requests over that socket, never through the main PTY. A regular `zle -F` handler in the warm shell accepts a bounded request and forks a short-lived `zpty` completion worker from that process. The worker therefore starts with the active shell's current directory, parameters and environment, aliases, functions, options, and loaded completion definitions instead of reconstructing session state in a cold sidecar shell. It runs zsh's own completion system and returns bounded, encoded candidates over the socket without changing the visible command line, history, terminal buffer, or PTY stream.

Capture has a short deadline and fixed request, candidate, and response-size caps so a slow or excessive completion definition cannot hold the app indefinitely. A failed, unavailable, malformed, or timed-out capture falls back to Pane's bounded local history, command, executable, and filesystem suggestions.

**Clear Blocks** removes the in-memory block timeline. It does not clear SwiftTerm scrollback or change shell state.

### Terminal mode

SwiftTerm becomes first responder and receives keyboard, control, Escape, paste, arrow, Tab, Option/Meta, and mouse events directly. The composer is replaced with a compact status and return strip. Use Terminal mode for password prompts, shell completion, ZLE widgets, REPLs, SSH, `fzf`, terminal coding agents, and any character-at-a-time workflow.

Manual switching through **Command-Shift-I** or the segmented control always remains available.

### Alternate-screen behavior

SwiftTerm owns both terminal buffers. On `ESC[?1049h`, the emulator activates a clean alternate buffer; Pane invalidates the complete native backing surface before the new frame is displayed. On `ESC[?1049l`, SwiftTerm restores the preserved normal buffer. The two buffers are never merged.

DEC private modes 47, 1047, and 1049 trigger automatic entry into Terminal mode when Blocks mode is visible. Pane returns to Blocks mode after the normal buffer is restored only when the original switch was automatic and the user has not manually overridden the mode.

The SwiftTerm view remains mounted while hidden, so mode changes preserve emulator parsing, scrollback, and both buffers. `updateNSView` applies appearance or schedules visibility only when those values actually change; it never replays the session transcript.

The structured block path suppresses all alternate-screen frame bytes and inserts one plain `[Alternate screen active]` placeholder per entry. Private command-lifecycle markers still pass through so the originating command can complete normally.

This is terminal-protocol detection, not process-name guessing. Programs that do not request an alternate buffer, including many prompts, SSH sessions, and REPLs, still require the manual Terminal mode switch.

## Oh My Zsh

Pane starts zsh as both a login and interactive shell, so normal startup processing loads `~/.zshrc` or `$ZDOTDIR/.zshrc`. It preserves `HOME`, `ZDOTDIR`, `ZSH`, `PATH`, and the inherited environment.

Oh My Zsh is not bundled or installed. If it is configured in `.zshrc`, its environment, aliases, functions, plugins, and completion definitions load into the same persistent shell. Warm-shell completion capture can therefore use completion definitions and runtime shell state added by Oh My Zsh or later interactive commands. Prompt themes and interactive ZLE behavior render in Terminal mode. Blocks mode deliberately presents captured output as plain text.

## Terminal behavior

- SwiftTerm provides ANSI/VT rendering, selection, copy and paste, hyperlinks, mouse reporting, alternate buffers, and 10,000 lines of scrollback.
- SwiftTerm `LocalProcess` uses `forkpty`; ordinary pipes are not used.
- Window changes update the emulator and PTY using `TIOCSWINSZ`, only when dimensions actually change.
- Shell exit interrupts unfinished blocks, restores the normal terminal buffer, and exposes **Restart Shell**.
- Restart terminates the old shell before starting a new `/bin/zsh -l -i` session.
- Closing the final window quits the app; application termination stops the shell and closes PTY I/O without publishing teardown state through a disappearing SwiftUI view.
- `TERM` defaults to `xterm-256color`, `COLORTERM` to `truecolor`, and `TERM_PROGRAM` to `Pane`.

Terminal delegate state is equality-guarded. Buffer-change notifications, visibility changes, composer focus changes, and text-height measurements are deferred out of representable update callbacks. Active output stays in private buffers and is coalesced into one pending main-loop feed for the read-only mirror; the finalized block output is published once at completion rather than on every PTY byte or frame.

## Known limitations

- The active-command mirror is a presentation-only emulator. It does not own the PTY, resize it, send terminal replies, or accept keyboard and mouse input. Its filtered stream and independent geometry can differ from the authoritative terminal for cursor-addressed output, live redraws, and full-screen applications.
- Finalized blocks are plain-text snapshots extracted from that mirror, with sanitized captured bytes as a fallback. They do not preserve colors or terminal interactivity; Terminal mode is the authoritative view.
- Commands typed directly in Terminal mode are not converted into structured blocks because they have no composer submission record.
- While a command is active, Return sends one line of stdin and Shift-Return only edits that line. Active-only Control-C and Control-D are routed directly to the PTY, but other control sequences, arrows, Escape, Tab, mouse reporting, and raw input require Terminal mode.
- Follow-up composer input can be consumed by an unexpected foreground program and may desynchronize block tracking. Switch to Terminal mode for prompts, secrets, REPLs, SSH, and other interactive commands.
- Passwords entered in the composer are visible. Enter Terminal mode before responding to a password prompt.
- Up and Down navigate command history rather than moving the caret vertically in a multiline draft.
- History and finalized blocks are memory-only. The active raw-output fallback retains only its newest 4 MiB and each SwiftTerm view has 10,000 lines of scrollback, but accumulated finalized block text can still consume substantial memory.
- Replacing zsh with `exec`, removing the integration hooks, or redefining them can prevent the completion marker and leave a block running until interruption, shell exit, or restart.
- Warm-shell autocomplete depends on zsh's socket, ZLE, PTY, and completion modules. If integration is unavailable, a custom completion exceeds the deadline or caps, or its response cannot be decoded, Pane uses its less context-aware local fallback.
- Completion workers inherit live shell state by forking from the active zsh, but they run in a short-lived child. Side effects produced only while computing a completion are discarded rather than applied back to the authoritative shell.
- Alternate-screen switching detects protocol state only; it is not general interactive-program detection.
- There are no tabs, AI features, synchronization, remote-session management, search/export, or settings UI.
- OSC 52 clipboard reads are enabled for terminal compatibility. A production release should add an explicit permission policy for untrusted remote programs.

## Implementation status

### Working

- Native SwiftUI/AppKit app named Pane with semantic colors, system material, SF Symbols, native controls, and adaptive appearance
- macOS 26 Liquid Glass toolbar controls with native macOS 14 and 15 fallbacks
- Application-icon asset plus bundle and runtime integration for Finder, Dock, App Expose, and window previews
- Three-layer Apple visual hierarchy with one dominant terminal surface and one bottom-anchored composer
- Active command and adaptive one-to-ten-row live mirror in the composer, followed by a finalized Warp-style timeline block
- One-block multiline submission, shell-continuation collection, and active-command-only routing for Control-C and Control-D
- Bottom-anchored finalized timeline with selection, status, duration, output, copy, rerun, edit, collapse, and delete actions
- Warm-zsh `compsys` autocomplete over a private per-shell socket, with bounded local fallback
- PTY stderr preservation and nonzero exit-status reporting in both Terminal and finalized Blocks views
- Stable hover geometry and a content-sized one-to-six-line composer
- One persistent PTY-backed interactive login zsh with normal Oh My Zsh startup
- Manual Blocks/Terminal input routing and protocol-driven alternate-screen switching
- Isolated DEC 1049 alternate buffer with restoration of the unchanged normal buffer
- Alternate-screen transcript suppression, split-sequence handling, and manual mode override
- Resize, scrollback, copy/paste, mouse input, Meta input, clear, restart, shell-exit handling, and cleanup

### Verification

Verification is revision-specific; these results are from the current checkout after warm-zsh autocomplete, the icon-identity fix, and the stderr-descriptor fix:

- SwiftPM: **69 of 69 tests passed**, including protocol framing, candidate mapping, forward/reverse autocomplete selection, persistent PTY behavior, Control-C routing, alternate-buffer isolation, stderr-only output with a nonzero exit status, and a live integration test that defines a parameter and `compdef` after the shell has started and then captures that warm-only completion.
- Native Xcode build: **succeeded** for the `Pane` Debug scheme on macOS with SwiftTerm 1.14.0.
- Runtime: the generated `Pane.app` was registered and launched as a bundle. The app uses `com.gilbertkrantz.Pane`, contains the compiled `AppIcon.icns`, applies it to current and future window miniatures, and the corrected window-preview icon was visually confirmed.
- Generated app: `/Users/chandraw/Documents/Webe's Term/Build/Pane.app`.

### Verification limits

- Automated visual control of the running app was blocked because Codex did not have macOS Accessibility and Screen Recording permission. Visual behavior still needs a local human pass.
- Vim, `less`, `top`, SSH, and `fzf` were not each exercised end to end in this environment. Their underlying PTY routing and alternate-buffer protocols are covered, but individual third-party behavior is not claimed as manually verified.
- No automated screenshot regression suite currently covers appearance, composer geometry, hover stability, Reduce Transparency, increased contrast, or window-size variants.

Recommended local visual smoke test:

1. Open `Pane.xcodeproj`, run the `Pane` scheme, and execute `pwd`, `cd /tmp`, and `pwd` in Blocks mode.
2. Type a partial command or path; confirm suggestions are bounded, Tab and Shift-Tab move the highlight, Return accepts it, and Escape dismisses the list.
3. Submit a Shift-Return multiline draft; confirm all lines complete as one block.
4. Submit an incomplete shell construct, add its continuation lines in the composer, and confirm it remains one block; repeat and cancel it with Control-C.
5. Run a command that emits output over several seconds; confirm its mirror grows from one through ten rows, then scrolls, accepts line input, and becomes one finalized block only when it ends.
6. While a command is active, confirm composer Control-C interrupts it without erasing an unsent draft and Control-D sends end-of-file.
7. Add enough completed commands to overflow the viewport; confirm the newest block stays by the composer and older blocks overflow upward.
8. Hover several blocks; confirm the command, directory, and status remain stationary and collapse/expand is directly available.
9. Launch `vim` or `less`; confirm a single clean alternate frame appears and the previous normal terminal buffer returns unchanged on exit.
10. Resize the window in both modes and test arrows, Escape, Option/Meta, paste, and mouse input.
11. Confirm the Pane icon appears in Finder, the Dock, App Expose, and window previews when launching the `.app` bundle.
12. Check light mode, dark mode, Reduce Transparency, and increased contrast. On macOS 26, also check Liquid Glass; on macOS 14 or 15, check the native toolbar fallback.
