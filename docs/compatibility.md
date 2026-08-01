# Pane P2 compatibility dashboard

A cell is **Pass** only when an automated test or a dated manual run exercises that behavior through Pane. A direct `pane-fixture` run proves that the test stimulus is deterministic; it does not, by itself, prove Pane rendering or third-party compatibility. **Pending** is an honest release gate, not an ignored test.

<!-- BEGIN GENERATED COMPATIBILITY MATRIX -->
| Application / behavior | Launch | Input | Resize | Tab switch | Exit | Evidence / notes |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| zsh and basic commands | Pass | Pass | Pending | Pending | Pass | `TerminalSessionIntegrationTests and PaneConnectedCompatibilityTests`; clean HOME/ZDOTDIR Pane PTY |
| Pane alternate-screen fixture | Pass | Pass | Pass | Pass | Pass | `PaneConnectedCompatibilityTests and WorkspaceStressRunnerTests`; selected/background input identity and stable authoritative view asserted |
| Bracketed paste fixture | Pass | Pass | N/A | Pass | Pass | `PaneConnectedCompatibilityTests.testBracketedPasteUsesSelectedPaneTerminalOnly`; SwiftTerm markers and selected-session isolation asserted with Unicode payload |
| Mouse reporting fixture | Pass | Pending | N/A | Pass | Pass | `PaneConnectedCompatibilityTests.testMouseReportingRejectsStaleBackgroundEvent`; click encoding and stale-background rejection pass; drag, wheel, and trackpad review remain Pending |
| Pane split-byte Unicode fixture | Pass | N/A | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testFixtureRunsThroughPanePTYAndAuthoritativeTerminal`; block output preserves tested graphemes |
| Pane SIGWINCH fixture | Pass | N/A | Pass | Pending | Pass | `PaneConnectedCompatibilityTests.testPanePTYResizeDeliversSIGWINCHToInteractiveFixture`; Pane terminal resize reaches the fixture PTY |
| Large output fixture (10k lines) | Pass | N/A | Pending | Pass | Pass | `PaneConnectedCompatibilityTests.testLargeOutputThroughBackgroundPaneSessionStaysIsolated`; background Pane PTY stays isolated and bounded while selected-session input completes |
| Vim | Pass | Pass | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testSystemVimEditsAcrossAlternateScreenAndExitsCleanly`; system Vim with clean configuration |
| Neovim | Pending | Pending | Pending | Pending | Pending | dated manual or self-hosted application run required |
| less | Pass | Pass | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testLessAndPythonREPLPreserveDirectInputAndReturnToComposer`; system less direct-input exit |
| man | Pass | Pass | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testSystemManAndTopExitWithoutTerminalStateCorruption`; system man with less pager |
| top | Pass | Pass | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testSystemManAndTopExitWithoutTerminalStateCorruption`; system top direct input and normal exit |
| htop / btop | Pending | Pending | Pending | Pending | Pending | optional tools remain Pending when unavailable |
| fzf | Pending | Pending | Pending | Pending | Pending | dated manual or self-hosted application run required |
| tmux | Pending | Pending | Pending | Pending | Pending | dated manual or self-hosted application run required |
| SSH (local fixture) | Pass | Pass | Pending | Pass | Pass | `PaneConnectedCompatibilityTests.testLocalSSHThroughPanePTYStaysSessionLocalAndExitsCleanly`; unprivileged loopback-only sshd with temporary host/client keys; no public host |
| Docker shell | Pending | Pending | Pending | Pending | Pending | local runtime required |
| Python REPL | Pass | Pass | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testLessAndPythonREPLPreserveDirectInputAndReturnToComposer`; raw input is kept distinct from secure input |
| Node REPL | Pass | Pass | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testNodeAndSQLiteREPLsPreserveSessionLocalInput`; installed Node direct-input REPL |
| database CLI | Pass | Pass | Pending | Pending | Pass | `PaneConnectedCompatibilityTests.testNodeAndSQLiteREPLsPreserveSessionLocalInput`; system SQLite in-memory REPL |
| OpenCode / Codex | Pending | Pending | Pending | Pending | Pending | dated manual application run required |
| Real trackpad and complex Unicode visual review | Pending | Pending | Pending | Pending | Pending | manual release review required |
<!-- END GENERATED COMPATIBILITY MATRIX -->

The checked-in evidence source is `Tests/Compatibility/Snapshots/compatibility-evidence.json`. Run:

```sh
/usr/bin/python3 Tests/Compatibility/Scripts/validate-compatibility-evidence.py
```

The validator rejects Pass cells without a dated source and fails when this generated table differs from the checked-in evidence snapshot. Use `--write` only after updating that snapshot.

## Automated tiers

- **Pull requests:** SwiftPM and both app-hosted Xcode test targets, short Pane-connected fixture tests, fixture smoke/Unicode/10k-line tests, migration/recovery tests, and one bounded lifecycle test.
- **Nightly:** set `PANE_RUN_LARGE_COMPATIBILITY=1`, run the full compatibility suite, explicitly run the real 12-tab baseline with `PANE_RUN_REAL_STRESS=1`, then run 100 create/close cycles, corruption recovery, and resource sampling.
- **Scheduled/manual soak:** run `Scripts/P2/run-soak.sh --preset 2h` for the short soak or `Scripts/P2/run-soak.sh --preset 8h` for the full-workday artifact. Fixture-only output is explicitly ineligible for the release gate; the app-hosted eight-tab driver remains Pending.

Every integration runner has startup, readiness, action, cleanup, and total deadlines. A failure records its fixture mode and stage, drains stdout/stderr concurrently, and performs bounded SIGTERM/SIGKILL cleanup. There are no unconditional retries.

## Manual P2 release validation

Use the full [P2 release-validation checklist](p2-release-validation.md) as the
evidence record.

Record Pane commit, macOS/Xcode version, hardware, shell, and date. Create 16 tabs; rapidly switch, reorder, duplicate, close, replace, and restore them. Run Vim/Neovim, tmux, local SSH, OpenCode, Codex, less, fzf, Python, and a Docker shell. Exercise Unicode, bracketed multiline paste, mouse reporting, password input, Control-C, Control-D, and repeated resize. Confirm input and focus never cross tabs.

During a workday run, sample memory, CPU, threads, descriptors, live sessions/PTYS/completion tasks, and block counts. Verify memory plateaus under bounded output, descriptor counts return near baseline after 100 create/close cycles, inactive CPU stays low, closing tabs releases resources, shutdown is bounded, corrupt snapshots recover to a usable default tab, and secure drafts never restore.
