#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  printf 'error: DEVELOPER_DIR must identify the pinned Xcode developer directory\n' >&2
  exit 1
fi

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  printf 'error: DEVELOPER_DIR does not exist: %s\n' "$DEVELOPER_DIR" >&2
  exit 1
fi

if [[ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
  printf 'error: xcodebuild is unavailable under DEVELOPER_DIR: %s\n' "$DEVELOPER_DIR" >&2
  exit 1
fi

# Hosted macOS runners can retain a global xcode-select path for a different
# Xcode than DEVELOPER_DIR. App-hosted tests do not reliably inherit the
# workflow environment, so align the global selection before they launch Git.
sudo -n xcode-select --switch "$DEVELOPER_DIR"

selected_developer_dir="$(xcode-select --print-path)"
expected_developer_dir="$(cd "$DEVELOPER_DIR" && pwd -P)"
selected_developer_dir="$(cd "$selected_developer_dir" && pwd -P)"
if [[ "$selected_developer_dir" != "$expected_developer_dir" ]]; then
  printf 'error: xcode-select chose %s instead of %s\n' \
    "$selected_developer_dir" "$expected_developer_dir" >&2
  exit 1
fi

xcodebuild -version
swift --version

git_executable="$(xcrun --find git)"
if [[ ! -x "$git_executable" ]]; then
  printf 'error: xcrun resolved a non-executable Git path: %s\n' \
    "$git_executable" >&2
  exit 1
fi

printf 'Git executable: %s\n' "$git_executable"
"$git_executable" --version
git --version
