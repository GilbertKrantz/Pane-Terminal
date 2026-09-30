# Product

<!-- impeccable:product-schema 1 -->

## Platform

macOS

## Users

Pane is for macOS developers and terminal power users working in sustained command-line sessions. They want completed commands to remain readable and navigable without giving up the behavior, state, and compatibility of a real interactive shell.

## Product Purpose

Pane is an Apple-native terminal that combines a structured command timeline with an authoritative PTY-backed shell. It exists to make command-line work calmer and easier to understand while retaining the continuity and escape hatches expected from a serious terminal. Success means becoming reliable enough for daily use, including ordinary shell work, long-running commands, and interactive terminal applications.

## Positioning

Pane does not reproduce terminal behavior from isolated command subprocesses. Each tab owns a persistent interactive zsh session and one authoritative terminal emulator while Pane derives structured, sanitized command blocks from that same session. This lets block readability and genuine terminal semantics coexist in one native macOS workspace.

## Operating Context

- Users compose and run ordinary commands in Blocks mode, where completed commands become searchable, collapsible, copyable, editable, and rerunnable timeline entries.
- Users switch to the authoritative Terminal surface for direct byte input, secure prompts, raw-mode programs, alternate-screen applications, and other character-at-a-time workflows.
- Each tab keeps its own shell, terminal buffer, working directory, command timeline, completion state, and secure-input state.
- Pane is currently distributed as an unsigned, non-notarized direct-download beta for macOS 14 or newer. The immediate roadmap emphasizes daily-driver reliability, essential settings, and distribution readiness.

## Capabilities and Constraints

- Pane is local-first, privacy-conscious, macOS-only, and built with SwiftUI, AppKit, SwiftTerm, and a real pseudoterminal.
- A persistent `/bin/zsh -l -i` session preserves shell state such as working directory, aliases, functions, exports, virtual environments, prompt setup, and history.
- SwiftTerm owns authoritative ANSI/VT rendering, terminal buffers, selection, hyperlinks, mouse reporting, scrollback, and alternate-screen behavior.
- Pane records bounded safe runtime metadata locally and sanitizes sensitive commands and output before persistence.
- Workspace restoration creates fresh shells from safe metadata; it never resurrects PTYs, foreground processes, secure input, or raw terminal streams.
- The product currently uses a single-window, multi-tab workspace. Split panes, multiple windows, detachable tabs, cloud synchronization, collaboration, remote-session reconnection, cloud export, and generated AI predictions are outside the current product scope.
- Commands typed directly in Terminal mode become structured blocks only when Pane's shell lifecycle integration can identify them.
- The active Blocks-mode terminal mirror is presentation-only; the persistent SwiftTerm surface remains authoritative.

## Brand Commitments

- The product name is **Pane**.
- Pane is presented as an Apple-native, calm, trustworthy terminal rather than a web application wrapped for macOS.
- The application icon source and compiled renditions live under `Design/` and `Pane/Assets.xcassets/AppIcon.appiconset/`.
- Product language must stay precise about what is implemented, what has been manually verified, and what remains experimental.

## Evidence on Hand

- `README.md` documents the product promise, implemented workflows, architecture, requirements, keyboard behavior, known limitations, and roadmap.
- `DESIGN.md` records the incumbent interface system and native rendering boundaries.
- `docs/architecture.md` records ownership, state, shutdown, restoration, and preference-propagation boundaries.
- `docs/compatibility.md`, `COMPATIBILITY.md`, and `docs/p2-release-validation.md` define compatibility and release evidence.
- `docs/unsigned-beta.md` documents the current direct-download beta and its signing, notarization, and verification limitations.
- Automated tests cover shell integration, terminal sessions, command lifecycle, workspace restoration, autocomplete, persistence, security sanitization, compatibility fixtures, and resource behavior.
- No customer testimonials, adoption metrics, performance claims, or broad compatibility claims are established; future product work must not fabricate them.

## Product Principles

1. **Keep the shell real.** Preserve one authoritative PTY-backed terminal and the state of the user's interactive shell.
2. **Make command history understandable.** Turn completed work into durable, navigable blocks without misrepresenting terminal output.
3. **Earn daily-driver trust.** Favor lifecycle correctness, recovery, compatibility, bounded resource use, and honest verification over novelty.
4. **Keep private work local and safe.** Minimize persisted data, sanitize sensitive content, and never restore unsafe live state.
5. **Behave like a macOS application.** Preserve native interaction, accessibility, keyboard, window, and system conventions.

## Accessibility & Inclusion

Pane must preserve native keyboard navigation, focus behavior, text selection, copy and paste, input methods, and system accessibility settings. Status must never rely on color alone, and controls and terminal presentation must remain usable with increased contrast and reduced transparency.
