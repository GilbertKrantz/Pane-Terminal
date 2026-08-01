#!/usr/bin/env bash
set -euo pipefail

output_directory="${1:-.ci/p2-artifacts}"
mkdir -p "$output_directory"

commit="$(git rev-parse HEAD)"
branch="$(git symbolic-ref --short -q HEAD || printf detached)"
xcode_version="unavailable"
if raw_xcode_version="$(xcodebuild -version 2>/dev/null)"; then
  xcode_version="$(printf '%s' "$raw_xcode_version" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
fi
swift_version="unavailable"
if raw_swift_version="$(swift --version 2>/dev/null)"; then
  swift_version="$(printf '%s' "$raw_swift_version" | head -n 1)"
fi
macos_version="$(sw_vers -productVersion)"
macos_build="$(sw_vers -buildVersion)"
architecture="$(uname -m)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

/usr/bin/python3 - \
  "$output_directory/ci-metadata.json" \
  "$commit" \
  "$branch" \
  "$xcode_version" \
  "$swift_version" \
  "$macos_version" \
  "$macos_build" \
  "$architecture" \
  "$timestamp" <<'PY'
import json
import pathlib
import sys

(
    destination,
    commit,
    branch,
    xcode_version,
    swift_version,
    macos_version,
    macos_build,
    architecture,
    timestamp,
) = sys.argv[1:]

payload = {
    "architecture": architecture,
    "branch": branch,
    "commit": commit,
    "macOSBuild": macos_build,
    "macOSVersion": macos_version,
    "swiftVersion": swift_version,
    "timestamp": timestamp,
    "xcodeVersion": xcode_version,
}
pathlib.Path(destination).write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

printf 'Sanitized CI metadata written to %s\n' "$output_directory/ci-metadata.json"
