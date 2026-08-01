#!/usr/bin/env bash
set -euo pipefail
# Reproducible output-side soak. The full app/UI scenario is performed by the
# manual checklist until a signed UI automation host is available.
duration_seconds="${PANE_SOAK_SECONDS:-7200}"
interval_seconds="${PANE_SOAK_INTERVAL_SECONDS:-60}"
artifact="${PANE_SOAK_ARTIFACT:-pane-soak.jsonl}"
fixture="$(cd "$(dirname "$0")/../Fixtures" && pwd)/pane-fixture"
end=$((SECONDS + duration_seconds))
: > "$artifact"
while (( SECONDS < end )); do
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "$fixture" output --lines 10000 >/dev/null
  printf '{"timestamp":"%s","fixture":"output-10000","passed":true}\n' "$started" >> "$artifact"
  sleep "$interval_seconds"
done
printf 'soak artifact: %s\n' "$artifact"
