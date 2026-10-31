#!/usr/bin/env bash
set -euo pipefail

lab_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: bin/check.sh <iOS-simulator-UUID>

Runs core tests and the NativeLab UI journeys on a Mac with Xcode 26+.
Choose an iPhone with iOS 18+ from: xcrun simctl list devices available
Build output and the .xcresult bundle are saved in a new temporary directory.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The iOS build and UI tests require Xcode on macOS." >&2
  echo "Core tests also run on Linux: swift test --package-path $lab_dir" >&2
  exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Install Xcode 26+ and select it in Xcode > Settings > Locations > Command Line Tools." >&2
  exit 1
fi

run_dir="$(mktemp -d "${TMPDIR:-/tmp}/omnigent-native-lab.XXXXXX")"
echo "Validation artifacts: $run_dir"

xcrun swift test --package-path "$lab_dir" --scratch-path "$run_dir/core"
xcodebuild \
  -project "$lab_dir/NativeLab.xcodeproj" \
  -scheme NativeLab \
  -destination "platform=iOS Simulator,id=$1" \
  -derivedDataPath "$run_dir/DerivedData" \
  -resultBundlePath "$run_dir/NativeLab.xcresult" \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO \
  test

echo "Core and UI tests passed. Results: $run_dir/NativeLab.xcresult"
