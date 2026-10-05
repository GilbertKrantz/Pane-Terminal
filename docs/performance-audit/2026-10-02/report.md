# Pane performance audit — 2 October 2026

**Baseline archive:** the authorized optimization work is now implemented. See [optimization results](optimization-results.md) for current measurements, validation, and remaining profiling limits. The findings and test failures below describe the original `292aef8` checkout.

The largest demonstrated bottleneck is the Blocks timeline. Long histories mount every output view, respond to unrelated session publications, and repeatedly derive the same timeline data. Optimize this path before changing the terminal engine or persistence architecture.

Scope: performance audit of checkout `292aef8`, using Impeccable's native audit workflow, source inspection, focused tests, and isolated Debug and optimized Release probes. No production implementation changed. The user's running Pane session was not restarted or attached to. This is not a visual, accessibility, or whole-product audit.

Performance assessment: **1/4 — major problems at long-history sizes**, based on the synthetic scaling measurements below. This score describes the audited Blocks path; startup, real-session input latency, frame delivery, and multi-tab resource behavior still need reference-Mac profiling.

## Measured baseline

Optimized Release objects from the current Pane and SwiftTerm source were linked into a standalone `-O` probe. The probe hosts the actual `BlocksView` in `NSHostingView`, with finalized one-line outputs and no live PTY. It mounts at 1120 × 620 points, resizes to 760 points wide, then assigns one draft character and yields three main-actor turns before forcing layout. Every trial verifies that the mounted output-view count equals the history count.

Times below are medians of three sequential trials. They are synthetic layout costs, **not** measured keystroke-to-screen or tab-switch p95. The run includes framework warm-up and sequential-process effects. macOS reported version 27.0.1; hardware model was unavailable under the sandbox. AppKit emitted sandbox/XPC service warnings, preserved in the raw log. Validate absolute timings in the shipped app on a documented reference Mac before making release claims.

| Finalized blocks | Mounted output views | Initial mount | Width change | Draft publication + layout |
| --- | --- | --- | --- | --- |
| 10 | 10 | 53 ms | 2.6 ms | 6.3 ms |
| 100 | 100 | 349 ms | 31.7 ms | 46.7 ms |
| 500 | 500 | 2,203 ms | 367 ms | 299 ms |
| 1,000 | 1,000 | 5,959 ms | 1,246 ms | 1,192 ms |

Other optimized measurements:

- A full search-index replacement over 1,000 blocks and 4,061,300 output bytes took a median **9.53 ms** across five warm repetitions. This runs on the search actor, not the main actor; its cost still repeats unnecessarily.
- For a link-heavy 262,108-byte output, attributed-text preparation took a median **93.2 ms**, and the separate height-measurement layout took **65.6 ms**. The combined per-trial median was **158.8 ms**. A 65,527-byte output required approximately **37.2 ms** combined. These measure a new text view and its first layout, not every update of an unchanged view.
- Debug probes showed the same scaling pattern. Release optimization did not remove the long-history problem.

Raw evidence: [Release measurements](release-measurements.log), [structured timeline metrics](metrics.json), [Debug probes](debug-probes.log), and [probe source](audit-probe.swift).

## Prioritized findings

### P1 — Eager history rendering amplifies broad session invalidation

Locations: `Pane/Views/BlocksView.swift:82`, `Pane/Views/CommandBlockView.swift:6`, `Pane/Views/TerminalWorkspaceView.swift:39`, `Pane/Terminal/TerminalSession.swift:97`.

The timeline uses `VStack` rather than a recycling container. Each row observes the complete `TerminalSession`, and the draft is a property on that same object. The probe mounted all 1,000 output text views and reproduced heavy layout work after a draft-only publication. Tab selection also replaces `ContentView` identity, creating a remount-sensitive path.

Impact: long-history tab changes, typing, and resizing can become visibly slow even when output is small. The 1,000-block size is permitted by the standard scrollback policy, so this is within supported bounds.

Recommendation: give the timeline a stable presentation snapshot and a narrower observable state boundary. Pass row data, selection, and actions without making every finalized row observe the entire session. Then evaluate viewport recycling with exact height and anchor management. Do not simply switch back to `LazyVStack`: the eager layout deliberately fixes blank viewport and scroll snap-back defects. Keep resize, remount, collapsed output, variable-height output, alternate-screen return, and newest-block visibility as correctness gates.

Suggested command: `$impeccable optimize`.

### P2 — Per-row timeline projection repeats an O(n) scan

Locations: `Pane/Views/BlocksView.swift:14`, `:25`, `:195`, `:204`, `:210`.

`commandBlockView` reads `lastFinalizedBlockID` for every row. That computed property re-filters `visibleBlocks`. At n rendered rows, this source path repeats O(n) work n times. Restored-session groups also repeatedly filter the finalized collection. During search, deriving `visibleBlocks` builds a match set and filters the timeline again.

Impact: avoidable CPU and allocations grow with history size and compound the view-creation costs. The scaling probe measures the combined path; it does not isolate this scan's percentage of total time.

Recommendation: compute finalized rows, the last ID, queued-state presence, and restored-session groups once per relevant snapshot or body evaluation, then pass those values into row creation. Invalidate cached projections when the timeline, query result, grouping, or queue changes. This is the first low-risk optimization to implement and measure.

Suggested command: `$impeccable optimize`.

### P2 — Every timeline mutation rebuilds the full search index

Locations: `Pane/Terminal/TerminalSession.swift:354`, `:907`, `Pane/Terminal/BlockSearchIndex.swift:43`.

Queueing, awaiting-start changes, starting, completing, collapsing, and deletion all publish the timeline and invoke `replace(blocks:)`. Replacement normalizes every command, output, directory, and status. It also performs a debounced search even when search is closed. A collapse change cannot alter searchable text, but still incurs a full rebuild. The task awaits replacement before checking cancellation, and the actor's synchronous replacement loop has no cancellation checks.

Impact: redundant background CPU, normalized-text allocations, delayed searches, and additional observable publications during command lifecycle changes. The measured 9.53 ms replacement is a per-rebuild cost, not a main-thread stall.

Recommendation: maintain documents by block ID and update only searchable fields that changed. Apply deletion/pruning deltas, skip collapse-only updates, and defer query execution when search is hidden. Check cancellation before actor work and coalesce superseded changes while preserving query-generation correctness.

Suggested command: `$impeccable optimize`.

### P1 — Large output text preparation and measurement block UI work

Locations: `Pane/Views/CommandClickableTextView.swift:39`, `:56`, `:76`, `:96`, `:102`, `Pane/Views/CommandBlockView.swift:103`.

Each newly mounted output builds attributed text, creates an `NSDataDetector`, scans the output for links, and performs TextKit layout. A second storage/layout stack measures height independently of the displayed text view. The capped output viewport limits visible height, but its first measurement still lays out the full stored excerpt. Width changes invalidate the measurement. The same-content guard and cached measured width already avoid some repeated work.

Impact: one near-limit link-heavy output takes approximately 159 ms for preparation and first measurement in the isolated optimized probe. Eager histories can contain several such blocks. That probe does not include the additional displayed-view layout or full timeline composition.

Recommendation: reuse link detection and cache link ranges or attributed output by immutable content revision. Measure whether preprocessing can move off the main actor, with AppKit view mutation remaining on it. Prefer bounded/viewport text layout where feasible, and cache heights by content revision, width, and typography. Preserve the separate measurement stack's correctness: resizing the displayed text view during SwiftUI measurement previously caused unstable geometry.

Suggested command: `$impeccable optimize`.

### P2 — Current instrumentation cannot establish end-to-end responsiveness

Locations: `Pane/Terminal/TerminalWorkspaceController.swift:491`, `Pane/Terminal/TerminalSession.swift:1198`, `Tests/PaneTests/ResourcePerformanceTests.swift:90`, `Tests/Compatibility/CompatibilityTests.swift:205`.

The tab-switch signpost ends when `selectTab` returns, before deferred focus/mount validation and SwiftUI rendering. The block-finalization signpost excludes later search indexing and actual row layout/paint. Resource tests assert the values of timing constants rather than observing those latency distributions. The standard Release test command also fails to compile existing tests that access DEBUG-only session hooks.

Impact: a short signpost duration or passing threshold-constant test can coexist with a slow visible UI. The usual test path currently cannot supply optimized-build performance evidence.

Recommendation: add intervals through the selected content's first rendered frame and through finalized-block visibility. Make an optimized measurement target compile independently of DEBUG-only tests, and record distributions on the reference Mac. Retain existing controller intervals as component timings. Track draft-to-paint, resize frame stalls, idle CPU, and resource convergence as separate measurements.

Suggested command: `$impeccable optimize`.

## Additional profiling candidate

The PTY path converts an incoming slice to `[UInt8]`, then to `Data`, then back to `[UInt8]`, before filtering/parsing another `Data` representation (`PTYController.swift:86`, `:397`, `TerminalSession.swift:1123`). Authoritative emulator feeding and structured parsing execute synchronously on the main actor; the active command can also feed a presentation mirror. Profile allocation and main-thread time under selected/background output bursts before changing this path. No current measurement establishes it as a dominant bottleneck. Preserve byte ordering, one authoritative feed, lifecycle-marker boundaries, and shell-generation rejection.

## Existing strengths to preserve

- Standard history bounds: 1,000 finalized blocks, 4 MiB retained output/replay, 256 KiB excerpt per block, and 10,000 terminal scrollback lines.
- Active output capture stays bounded and outside high-frequency SwiftUI state. The live mirror coalesces feeds, and the visible-row estimate caps at ten.
- Search normalization/filtering and SQLite/workspace persistence use actors.
- Autocomplete has debounce, cancellation, stale-generation rejection, provider budgets, PATH caching, and project/Git TTL caches.
- Foreground inspection stops for idle Blocks sessions and slows for inactive tabs.
- Completed output uses plain text rather than mounting a terminal emulator per completed block.

## Optimization sequence and validation

1. **`$impeccable optimize`**: precompute timeline projections and narrow row observation. Re-run the same probes to attribute the improvement.
2. **`$impeccable optimize`**: apply incremental search indexing and avoid hidden-query publication; measure rebuild count as well as duration.
3. **`$impeccable optimize`**: reduce output-text preparation/layout cost, then introduce recycling if history mount cost still dominates. Keep exact scrolling behavior and native text selection.
4. **`$impeccable audit`**: measure the complete flow on a documented reference Mac, including 1/8 tabs, 10/100/500/1,000 blocks, large/wrapped outputs, tab return, resizing, mode changes, output bursts, and cleanup. Existing release targets are tab-switch p95 <50 ms, block-publication p95 <16 ms, and eight-tab idle CPU p95 <5%; the synthetic table does not prove those gates.
5. **`$impeccable polish`**: confirm the optimized UI retains scroll stability, focus, text selection, keyboard use, and accessibility behavior.

The user can request these in sequence or together. Re-run the performance audit after implementation; measure improvement against the saved baseline before changing the assessment.

## Verification and reproduction

- **Passed:** 15 focused Debug tests across `ResourcePerformanceTests`, `LargeOutputHardeningTests`, and `CommandClickableTextViewTests`, with zero failures. [Log](focused-tests.log).
- **Passed:** two temporary Debug measurement probes; their assertions verified mounted output counts. The temporary test source was removed from the test target afterward.
- **Completed:** optimized standalone probe linked against Release Pane/SwiftTerm objects, including three measurement families and view-count preconditions.
- **Passed:** the documented optimized library-only reproduction build (`swift build -c release --target Pane -Xswiftc -enable-testing`). [Build log](release-library-build.log). This verifies the SwiftPM library, not the Xcode app bundle.
- **Failed:** ordinary `swift test -c release` compilation due to existing tests referencing DEBUG-only members. [Diagnostics](release-test-build.log). This is distinct from the successfully compiled Release library objects used by the standalone probe.
- **Not performed:** complete test suite, Xcode app-bundle build/launch, manual UI/VoiceOver checks, Instruments capture, reference-Mac p95, long soak, multi-tab memory/CPU measurements, or remote CI.

The first dependency fetch failed because network access was restricted. Copying the existing local SwiftPM repository caches into a writable `/tmp` cache allowed the focused build to proceed without fetching new dependencies.

To reproduce the optimized probe from the repository root, use a writable SwiftPM cache containing the locked dependencies:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH=/tmp/pane-audit-clang
export DEVELOPER_MODULE_CACHE_DIR=/tmp/pane-audit-module-cache
swift build -c release --target Pane --scratch-path /tmp/PanePerformanceAudit \
  --cache-path /tmp/pane-audit-cache --disable-sandbox --skip-update \
  -Xswiftc -enable-testing
xcrun swiftc -O -parse-as-library \
  -I /tmp/PanePerformanceAudit/arm64-apple-macosx/release/Modules \
  docs/performance-audit/2026-10-02/audit-probe.swift \
  /tmp/PanePerformanceAudit/arm64-apple-macosx/release/Pane.build/*.swift.o \
  /tmp/PanePerformanceAudit/arm64-apple-macosx/release/SwiftTerm.build/*.swift.o \
  -lsqlite3 -o /tmp/PaneAuditReleaseProbe
/tmp/PaneAuditReleaseProbe
```

The object/module paths above match this arm64 run; adjust for another architecture. The standalone probe creates synthetic sessions without starting shells and does not read the user's saved history. Retain raw samples and configuration when comparing results.
