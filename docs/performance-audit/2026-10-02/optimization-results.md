# Pane performance optimization — 2 October 2026

Implemented all five actionable audit findings and removed redundant PTY byte conversions. The largest improvement is in long-history rendering: at 1,000 blocks, isolated mount cost fell from 5,959 ms to 55 ms while mounted output views fell from 1,000 to eight.

## Matched measurements

Release `-O`, arm64, macOS 27.0.1, synthetic finalized one-line output, actual `BlocksView` hosted at 1120 × 620 points, then resized to 760 points wide. Three sequential trials per history size; medians below. Each optimized trial asserts a positive, bounded output-view count. Saved-history loading and shell startup are excluded. The baseline and optimized probes ran in the same sandbox environment, which emitted AppKit service warnings. Absolute timing and CPU/memory conclusions need a real reference-app profile.

| Blocks | Mounted output views, before → after | Mount ms, before → after | Resize ms, before → after | Draft + forced layout ms, before → after |
| --- | --- | --- | --- | --- |
| 10 | 10 → 8 | 53.0 → 33.8 | 2.6 → 4.2 | 6.3 → 3.2 |
| 100 | 100 → 8 | 348.7 → 48.8 | 31.7 → 4.1 | 46.7 → 0.7 |
| 500 | 500 → 8 | 2,203.1 → 57.1 | 366.9 → 5.0 | 299.1 → 1.0 |
| 1,000 | 1,000 → 8 | 5,959.3 → 55.1 | 1,246.4 → 5.2 | 1,192.2 → 1.2 |

At 1,000 blocks this is approximately 99.1% lower mount cost, 99.6% lower resize cost, and 99.9% lower draft/layout cost. Small-history resizing pays slightly more native recycler overhead; no universal speedup is claimed. These measurements include layout and main-actor yielding, **not keystroke-to-screen, GPU frame latency, or tab-switch p95**.

Replacing the unchanged 1,000-document search index (~4.06 MB searchable output) fell from **9.53 ms to 0.155 ms** median over five replacements. This measures reuse after initial indexing; new or changed text still needs normalization. Tests verify the number of normalized documents, collapse-only reuse, changed output, and document deletion.

For a 262,108-byte link-heavy output, main-thread text preparation fell from **93.2 ms to 2.0 ms** median. Links on large excerpts now arrive asynchronously. First uncached preparation plus height measurement was **58.2 ms**; the two subsequent trials were **17.3 and 17.6 ms** with shared height-cache reuse. Link scanning/completion and displayed-view drawing are excluded from this preparation metric. Cold TextKit measurement remains a meaningful cost for a newly encountered large excerpt.

Raw measurements: [baseline](release-measurements.log), [optimized](optimized-measurements.log), [baseline metrics](metrics.json), [optimized metrics](optimized-metrics.json). The original audit source and measurements are preserved.

## Changes

- **History rendering:** native viewport recycling with bounded overscan, explicit document geometry, synchronous visible-row measurement, bottom/row-relative anchors, and offscreen selection scrolling. Existing row content, actions, output caps, restored-session groups, and native output selection remain. Focused output views are retained while scrolling; resizing retains the same native text view and selected range. Automatic mounting focus cannot select an arbitrary row and recenter history.
- **Observation and projection:** one coalesced presentation snapshot derives finalized rows, restored groups, latest ID, queue, notices, and selection. Finalized rows receive immutable data. Draft-only changes with nonempty history do not publish a timeline snapshot. Search-result membership is cached.
- **Search:** documents keyed by block ID reuse normalization when searchable fields match. Replacements prune missing IDs, reject cancellation, and advance index generation only when searchable content/order changes. Hidden search neither rebuilds the index nor publishes results; opening search indexes current history, retaining query and timeline generation checks.
- **Output text:** reused detectors, off-main scanning for excerpts above 8 KiB, cancellation and revision checks for stale results, chunked main-thread link decoration, revision-based nonmutating measurement, and bounded shared height/link caches. Permanent history deletion clears these caches. Font and text edits invalidate measured height; appearance changes preserve pending link detection.
- **PTY:** removes redundant conversions between arrays and `Data`; terminal feeding, byte order, generation rejection, transcript filtering, and lifecycle parsing remain intact.
- **Measurement:** existing controller timings remain. New `TabDisplaySubmitted` and `BlockDisplaySubmitted` intervals extend through the native drawing turn, retain at most 256 successful samples per kind, and export through session diagnostics. Superseded/hidden/cancelled intervals carry `completed=0` and do not count as successful samples. Block timing waits for the expected visible block. This is display submission, not WindowServer/GPU presentation.
- **Optimized verification:** SwiftPM enables `PANE_TESTING` for read-only hooks and renderer test instrumentation used by existing tests. Xcode's shipping Release build excludes those hooks/instrumentation. Debug lifecycle logging remains Debug-only.

## Validation

| Evidence | Result |
| --- | --- |
| Complete Debug SwiftPM suite, before final selection/timing refinements | 364 XCTest cases, four opt-in skips, zero failures; seven Swift Testing cases passed |
| Final focused Debug native tests | 27 cases, zero failures: scrolling, text, search, resource/timing |
| Complete Release SwiftPM suite | 364 XCTest cases, four opt-in skips, zero failures; seven Swift Testing cases passed |
| Shipping Release Xcode app bundle | Build succeeded for arm64 and x86_64, signing disabled |
| Isolated visual inspection | Light 1120-point and dark 760-point history renders inspected; latest block, large capped output, and links visible |
| Source hygiene | `git diff --check` passed |

Native test windows used macOS services outside the restricted shell sandbox. The full suite covers actual isolated PTY sessions, byte/generation handling, shell integration, alternate screens, mode changes, workspace lifecycle, persistence, search, and scrolling. The new recycler test covers 1,000 rows, top scrolling, offscreen block selection, bounded mounts, and text-view identity/selection across width changes. Existing tests cover remount/resize, delayed scroll stability, collapse, bulk variable-height output, and return from an alternate screen. Some Debug-only counter assertions are intentionally absent in Release; Debug verification remains separate.

Logs: [Debug suite](debug-full-tests.log), [final focused Debug](final-debug-tests.log), [Release suite](release-full-tests.log), [shipping Release build](release-app-build.log). Visuals: [light history](light-wide.png), [dark compact history](dark-compact.png). The screenshots show synthetic isolated history, not the user's active app.

**Remaining evidence limits:** the user's running Pane process was preserved and was not restarted or exercised with this build. Manual app keyboard/VoiceOver review, Instruments frame capture, real draft-to-paint latency, reference-Mac p95 targets, eight-tab idle CPU/memory convergence, long soak, signing, and remote CI were not performed. The implementation and measurements address the demonstrated audit bottlenecks; they do not establish every shipping performance target.

## Reproduce

From the repository root, with the locked dependencies available in a writable local SwiftPM cache:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH=/tmp/pane-audit-clang
export DEVELOPER_MODULE_CACHE_DIR=/tmp/pane-audit-module-cache
swift test -c release --scratch-path /tmp/PanePerformanceAudit \
  --cache-path /tmp/pane-audit-cache --disable-sandbox --skip-update
xcrun swiftc -O -parse-as-library \
  -I /tmp/PanePerformanceAudit/arm64-apple-macosx/release/Modules \
  docs/performance-audit/2026-10-02/optimized-probe.swift \
  /tmp/PanePerformanceAudit/arm64-apple-macosx/release/Pane.build/*.swift.o \
  /tmp/PanePerformanceAudit/arm64-apple-macosx/release/SwiftTerm.build/*.swift.o \
  -lsqlite3 -o /tmp/PaneOptimizedProbe
/tmp/PaneOptimizedProbe
```

Use `visual-probe.swift` in the same link command to produce the isolated screenshot tool; pass an existing output directory to it. Adjust object paths for another architecture. Native window tests need normal macOS window services. For the shipping build, use `xcodebuild -project Pane.xcodeproj -scheme Pane -configuration Release` with a writable derived-data directory and cached locked packages. Compare the baseline source against original checkout `292aef8`; its eager-mount assertions intentionally do not match the optimized implementation.
