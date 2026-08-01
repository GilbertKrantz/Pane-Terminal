# Pane P2 release validation

This checklist is the release record for P2 Daily-Driver Hardening. Keep test,
launch, interactive, visual, Instruments, and soak evidence separate. An
automated pass does not imply that a manual or workday gate passed.

## Release identity

Record these before starting:

| Field | Value |
| --- | --- |
| Pane commit | Pending |
| Candidate version | Pending |
| Date and operator | Pending |
| Mac model and memory | Pending |
| macOS build | Pending |
| Xcode and Swift versions | Pending |
| Default shell | Pending |
| Compatibility evidence snapshot | `Tests/Compatibility/Snapshots/compatibility-evidence.json` |

Use `Scripts/P2/check-integrity.sh` before recording evidence. Do not edit the
generated compatibility table directly; update its checked-in evidence source
and regenerate it through the compatibility tooling.

## Automated gates

Attach the workflow URL, artifact name, `.xcresult`, sanitized diagnostics, and
date for every completed row.

| Gate | Required evidence | Status | Evidence |
| --- | --- | --- | --- |
| Repository integrity | Conflict-marker scan and `git diff --check` | Pending | |
| SwiftPM | Full standard suite | Pending | |
| Native PaneTests | `PaneTests.xcresult` | Pending | |
| Native compatibility | Non-parallel `PaneCompatibilityTests.xcresult` | Pending | |
| Compatibility | Full matrix JSON and fixture logs | Pending | |
| Multi-session | Real 12-tab baseline with final per-tab markers | Pending | |
| Lifecycle | 100 create/close cycles | Pending | |
| Large output | 100,000 lines, 10 MB, long line, ANSI, invalid UTF-8 | Pending | |
| Search | 10,000-block indexed search | Pending | |
| Persistence | Corruption, migration, future schema, and concurrent SQLite | Pending | |
| Resource sampling | Memory, CPU, threads, descriptors, and debug counters | Pending | |
| Clean app build | Native Debug build with signing disabled | Pending | |

Pull-request CI runs integrity checks, the standard SwiftPM suite, short
compatibility fixtures, and both native test targets. P2 Nightly enables the
large compatibility fixtures, explicitly runs
`testRealPTYBaselineWhenExplicitlyEnabled` with
`PANE_RUN_REAL_STRESS=1`, and enables the 100-cycle resource test before running
the focused output, search, resource, and persistence suites. The inventory
requires both opt-in test hooks and records their presence in
`nightly-hook-status.json`; a successful inventory proves that the hooks exist,
not that their release evidence passed.

## Manual sessions

Record Pass, Fail, or Pending with a dated note.

- [ ] Create 16 tabs.
- [ ] Switch rapidly across all tabs without focus loss or input crossover.
- [ ] Reorder tabs without recreating their terminal views or PTYs.
- [ ] Duplicate tabs and confirm each duplicate starts a distinct fresh shell.
- [ ] Close active and inactive tabs, including tabs with foreground work.
- [ ] Close six tabs and create six replacements.
- [ ] Restart shells repeatedly.
- [ ] Quit and restore the workspace; confirm restoration creates fresh shells.
- [ ] Confirm no pending focus callback targets an inactive or closed tab.
- [ ] Confirm every surviving stress tab completes its unique final marker.

## Manual applications

Each application needs launch, input, cursor movement, resize, switch away and
back, normal exit, interrupt, and active-tab close where applicable.

- [ ] Vim or Neovim
- [ ] tmux
- [ ] controlled local SSH fixture
- [ ] OpenCode
- [ ] Codex
- [ ] less and man
- [ ] fzf
- [ ] Python REPL
- [ ] Node REPL
- [ ] database CLI
- [ ] Docker shell
- [ ] top
- [ ] htop or btop when installed
- [ ] current Pane development TUI

Unavailable third-party applications stay Pending. A fixture pass must not
automatically promote a third-party application to Pass in
`docs/compatibility.md`.

## Manual input and rendering

- [ ] One-line paste
- [ ] Multiline and trailing-newline paste
- [ ] Multiline commands and shell continuation prompts
- [ ] Shell metacharacter paste
- [ ] Large paste without a main-thread stall
- [ ] Paste in Vim and REPLs
- [ ] CJK, emoji, variation selectors, skin tones, combining marks, and ZWJ
- [ ] Wide and ambiguous-width glyph cursor movement
- [ ] Right-to-left and mixed-width text where supported
- [ ] Selection copies complete grapheme sequences
- [ ] Mouse click, drag, wheel, and horizontal trackpad behavior
- [ ] Password prompt and manual secure input
- [ ] Control-C interruption
- [ ] Control-D / EOF
- [ ] Repeated resize in idle, output, alternate-screen, and multi-tab states
- [ ] No stale mouse, paste, resize, or keyboard event crosses sessions

Complex Unicode layout and real trackpad behavior require visual/manual
evidence even when byte-level automated fixtures pass.

## Resource and performance gates

Use a documented reference Mac for release decisions. Hosted CI records metrics
but does not weaken correctness assertions for runner variance.

- [ ] Debug resource counters converge exactly within five seconds of cleanup.
- [ ] After 100 create/close cycles, FD residual is at most
  `max(4, 5% of warm baseline)`.
- [ ] After 100 cycles, memory residual is below 15%.
- [ ] Closing seven of eight tabs releases at least half of tab-attributable
  memory growth.
- [ ] Thirty minutes of bounded output finishes within 15% of its stabilized
  rolling median and has no sustained positive slope.
- [ ] Eight-tab idle CPU median is at most
  `max(2%, one-tab baseline + 1.5 percentage points)`.
- [ ] Eight-tab idle CPU p95 is below 5%.
- [ ] Reference-runner tab-switch p95 is below 50 ms.
- [ ] Reference-runner block-publication p95 is below 16 ms.
- [ ] Input stays responsive during selected and background large output.
- [ ] Closing all tabs and quitting finishes within the bounded shutdown window.

Attach the raw samples and analysis rather than only recording the conclusion.

## Persistence and recovery

- [ ] Truncated workspace file opens to a usable workspace.
- [ ] Malformed JSON recovers valid entries and creates a default tab if needed.
- [ ] Unsupported workspace schema is quarantined without a crash loop.
- [ ] Duplicate tab IDs and missing selection are repaired.
- [ ] Missing working directories fall back safely.
- [ ] Workspace writes preserve the last-known-good snapshot across injected
  write, synchronization, and replacement faults.
- [ ] Runtime SQLite upgrades from every supported schema version.
- [ ] Interrupted and repeated migrations are transactional and idempotent.
- [ ] Future-schema databases remain untouched and use memory-only fallback.
- [ ] Confirmed corruption moves the main, WAL, and SHM files together.
- [ ] Interrupted commands never restore as successful.
- [ ] No active PTY, foreground process, alternate buffer, raw terminal bytes,
  or secure draft is restored.

## Soak evidence

Use the same runner for both durations:

```sh
Scripts/P2/run-soak.sh --preset 2h
Scripts/P2/run-soak.sh --preset 8h
```

The default interval is five minutes. Each interval records a marker, tab
switch, temporary create/close, autocomplete request, resize, and a
`PaneSoakSample`-shaped JSONL record. The expected topology is eight tabs: four
background producers, two interactive fixtures, and two idle shells.

For release evidence, set `PANE_SOAK_DRIVER` to the executable app-hosted driver
and require it:

```sh
PANE_SOAK_DRIVER=/absolute/path/to/pane-soak-driver \
Scripts/P2/run-soak.sh \
  --preset 8h \
  --artifact Artifacts/P2/pane-soak.jsonl \
  --diagnostics-dir Artifacts/P2/soak-diagnostics \
  --require-app-driver
```

Without an app driver, the runner uses eight isolated fixture PTYs only. Its
summary explicitly sets `releaseGateEligible` to `false`; this validates the
orchestration and bounded cleanup but does not satisfy the Pane workday gate.

The driver is invoked as an executable path, never through a shell command. It
implements `start`, `action`, `sample`, and `stop` subcommands, persists its
opaque state at the supplied `--state` path, and returns one JSON object from
`sample`. That object must contain every `PaneSoakSample` field. `stop` receives
`--timeout-seconds 2` and must close tabs, child processes, and PTYs within that
bound.

- [ ] Two-hour app-hosted soak artifact
- [ ] Eight-hour app-hosted workday artifact
- [ ] Samples remain complete at five-minute intervals
- [ ] All temporary tabs are closed after each interval
- [ ] Bounded cleanup succeeds on completion and injected interruption
- [ ] Sanitized diagnostics contain no transcript, command arguments,
  environment values, secure input, remote URLs, or unnecessary home paths

## Instruments and interactive evidence

- [ ] Instruments Leaks review
- [ ] Instruments Allocations review after create/close and output pressure
- [ ] Idle and background CPU review
- [ ] App launch smoke test
- [ ] Interactive TUI focus and tab-switch review
- [ ] Visual Unicode and resize review
- [ ] Full-workday daily-driver note

## Release decision

P2 can ship only when all automated correctness gates pass and the two-hour
soak, eight-hour workday artifact, Instruments review, corruption recovery
evidence, and complete manual checklist are attached. Known failures and flaky
tests must have an issue and owner; no unconditional retry or weakened assertion
counts as release evidence.

After P2, the roadmap advances to essential settings and distribution. Split
panes, MLX completion, plugin architecture, and other feature expansion remain
out of scope.
