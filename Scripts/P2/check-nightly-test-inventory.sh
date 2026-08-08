#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'usage: %s SWIFT_TEST_LIST [STATUS_JSON]\n' "$0" >&2
  exit 64
fi

test_list="$1"
status_json="${2:-.ci/p2-artifacts/nightly-hook-status.json}"

if [[ ! -f "$test_list" ]]; then
  printf 'error: test inventory does not exist: %s\n' "$test_list" >&2
  exit 66
fi

required_patterns=(
  'PaneCompatibilityTests'
  'WorkspaceStressTests'
  'WorkspaceStressRunnerTests'
  'testRealPTYBaselineWhenExplicitlyEnabled'
  'LargeOutputHardeningTests'
  'testIndexedSearchHandlesTenThousandBlocksAtSessionScope'
  'testCorruptDatabaseIsMovedAsideWithoutStartupLoop'
  'testEightConcurrentStoreOpensShareMigrationWithoutBusyFailure'
  'WorkspaceSnapshotStoreTests'
  'ResourceLifecycleHardeningTests'
  'testHundredCreateCloseCyclesWhenNightlyEnabled'
  'ResourcePerformanceTests'
)

for pattern in "${required_patterns[@]}"; do
  if ! grep -Fq -- "$pattern" "$test_list"; then
    printf 'error: required nightly test hook is missing: %s\n' "$pattern" >&2
    exit 1
  fi
done

real_stress=false
hundred_cycles=false
if grep -Fq -- 'testRealPTYBaselineWhenExplicitlyEnabled' "$test_list"; then
  real_stress=true
fi
if grep -Fq -- 'testHundredCreateCloseCyclesWhenNightlyEnabled' "$test_list"; then
  hundred_cycles=true
fi

mkdir -p "$(dirname "$status_json")"
printf '{\n' > "$status_json"
printf '  "realPTYStressHookPresent": %s,\n' "$real_stress" >> "$status_json"
printf '  "hundredCreateCloseHookPresent": %s,\n' "$hundred_cycles" >> "$status_json"
printf '  "missingHooksBlockRelease": %s\n' "$(
  if [[ "$real_stress" == true && "$hundred_cycles" == true ]]; then
    printf false
  else
    printf true
  fi
)" >> "$status_json"
printf '}\n' >> "$status_json"

if [[ "$real_stress" != true ]]; then
  printf 'warning: no named real-PTY 12-tab stress hook is present; release evidence remains Pending\n' >&2
fi
if [[ "$hundred_cycles" != true ]]; then
  printf 'warning: no named 100 create/close-cycle hook is present; release evidence remains Pending\n' >&2
fi

printf 'Nightly test inventory validated; required release hooks recorded in %s\n' "$status_json"
