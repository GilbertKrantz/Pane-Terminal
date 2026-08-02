#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if [[ -n "$(git status --porcelain)" ]]; then
  printf 'release packaging requires a clean checkout\n' >&2
  exit 1
fi

commit="$(git rev-parse HEAD)"
short_commit="$(git rev-parse --short HEAD)"
artifact_directory="${1:-$repo_root/Artifacts/Release/$short_commit}"

if [[ -e "$artifact_directory" ]]; then
  printf 'refusing to overwrite existing release artifact directory: %s\n' "$artifact_directory" >&2
  exit 1
fi

mkdir -p "$artifact_directory/tests" "$artifact_directory/DerivedData" \
  "$artifact_directory/SourcePackages" "$artifact_directory/SwiftPM"

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR="$developer_dir"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/pane-release-clang}"
export DEVELOPER_MODULE_CACHE_DIR="${DEVELOPER_MODULE_CACHE_DIR:-/tmp/pane-release-module-cache}"

Scripts/P2/check-integrity.sh

set -o pipefail
swift test --scratch-path "$artifact_directory/SwiftPM" \
  2>&1 | tee "$artifact_directory/tests/swiftpm.log"

xcodebuild \
  -project Pane.xcodeproj \
  -scheme Pane \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$artifact_directory/DerivedData" \
  -clonedSourcePackagesDirPath "$artifact_directory/SourcePackages" \
  -resultBundlePath "$artifact_directory/tests/PaneTests.xcresult" \
  -only-testing:PaneTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test \
  2>&1 | tee "$artifact_directory/tests/pane-tests.log"

xcodebuild \
  -project Pane.xcodeproj \
  -scheme Pane \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$artifact_directory/DerivedData" \
  -clonedSourcePackagesDirPath "$artifact_directory/SourcePackages" \
  -resultBundlePath "$artifact_directory/tests/PaneCompatibilityTests.xcresult" \
  -only-testing:PaneCompatibilityTests \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  test \
  2>&1 | tee "$artifact_directory/tests/pane-compatibility-tests.log"

xcodebuild \
  -project Pane.xcodeproj \
  -scheme Pane \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$artifact_directory/DerivedData" \
  -clonedSourcePackagesDirPath "$artifact_directory/SourcePackages" \
  ARCHS='arm64 x86_64' \
  CODE_SIGNING_ALLOWED=NO \
  clean build \
  2>&1 | tee "$artifact_directory/tests/release-build.log"

app_bundle="$artifact_directory/DerivedData/Build/Products/Release/Pane.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_bundle/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_bundle/Contents/Info.plist")"
Scripts/Release/validate-bundle.sh "$app_bundle" "$version" "$build" \
  | tee "$artifact_directory/tests/bundle-validation.log"

zip_name="Pane-$version-unsigned.zip"
zip_path="$artifact_directory/$zip_name"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$zip_path"
/usr/bin/shasum -a 256 "$zip_path" > "$zip_path.sha256"

architectures="$(/usr/bin/lipo -archs "$app_bundle/Contents/MacOS/Pane")"
/usr/bin/python3 - \
  "$artifact_directory/release-manifest.json" \
  "$version" "$build" "$commit" "$architectures" "$zip_name" <<'PY'
import json
import pathlib
import sys

destination, version, build, commit, architectures, zip_name = sys.argv[1:]
manifest = {
    "architectures": architectures.split(),
    "build": build,
    "commit": commit,
    "minimumMacOS": "14.0",
    "package": zip_name,
    "signing": "unsigned-not-notarized",
    "testArtifacts": [
        "tests/swiftpm.log",
        "tests/PaneTests.xcresult",
        "tests/PaneCompatibilityTests.xcresult",
        "tests/bundle-validation.log",
    ],
    "version": version,
}
pathlib.Path(destination).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

printf 'Unsigned beta package: %s\n' "$zip_path"
printf 'Checksum: %s.sha256\n' "$zip_path"
printf 'Manifest: %s/release-manifest.json\n' "$artifact_directory"
