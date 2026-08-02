#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s <Pane.app> <version> <build>\n' "$0" >&2
  exit 64
fi

app_bundle="$1"
expected_version="$2"
expected_build="$3"
plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/Pane"

[[ -d "$app_bundle" ]] || { printf 'missing app bundle: %s\n' "$app_bundle" >&2; exit 1; }
[[ -f "$plist" ]] || { printf 'missing bundle Info.plist\n' >&2; exit 1; }
[[ -x "$executable" ]] || { printf 'missing bundle executable\n' >&2; exit 1; }

read_plist() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$plist"
}

[[ "$(read_plist CFBundleIdentifier)" == "com.gilbertkrantz.Pane" ]] || {
  printf 'unexpected bundle identifier\n' >&2
  exit 1
}
[[ "$(read_plist CFBundleShortVersionString)" == "$expected_version" ]] || {
  printf 'unexpected marketing version\n' >&2
  exit 1
}
[[ "$(read_plist CFBundleVersion)" == "$expected_build" ]] || {
  printf 'unexpected build number\n' >&2
  exit 1
}
[[ "$(read_plist LSMinimumSystemVersion)" == "14.0" ]] || {
  printf 'unexpected minimum macOS version\n' >&2
  exit 1
}
[[ "$(read_plist CFBundleIconName)" == "AppIcons" ]] || {
  printf 'unexpected icon name\n' >&2
  exit 1
}
[[ -f "$app_bundle/Contents/Resources/AppIcons.icns" ]] || {
  printf 'missing AppIcons.icns\n' >&2
  exit 1
}

architectures="$(/usr/bin/lipo -archs "$executable")"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
  printf 'expected universal arm64/x86_64 executable, found: %s\n' "$architectures" >&2
  exit 1
}

# This beta is deliberately built with signing disabled. A valid signature here
# would mean a local signing setting leaked into the public unsigned artifact.
if /usr/bin/codesign --verify --deep --strict "$app_bundle" >/dev/null 2>&1; then
  printf 'expected unsigned beta bundle, but signature verification succeeded\n' >&2
  exit 1
fi

printf 'Validated unsigned Pane bundle %s (%s), architectures: %s\n' \
  "$expected_version" "$expected_build" "$architectures"
