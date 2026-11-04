#!/usr/bin/env bash
# Builds OmnigentMac (Debug, with the debug Rust core) for this Mac, signs it ad hoc, and installs
# it as ~/Applications/Omnigent Native.app (bundle id ai.omnigent.mac.lab), apart from the
# Electron "Omnigent". For day-to-day use before Developer ID builds exist. Debug, because its
# incremental builds take seconds where an optimized build of a shared module takes minutes.
#
# Usage: install-local.sh [--skip-prereqs] [--no-launch] [--full-priority]
#
# Debug builds keep sign-ins in files only the user can read (KeychainModeSelection). Sparkle
# stays off. Everything runs at background priority with two Rust jobs so the Mac stays usable;
# --full-priority drops both limits when nobody is using the Mac.
# --skip-prereqs reuses the current Rust core, CEF and generated workspace.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release/common.sh"

skip_prereqs=0
launch=1
full_priority=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-prereqs) skip_prereqs=1; shift ;;
    --no-launch) launch=0; shift ;;
    --full-priority) full_priority=1; shift ;;
    -h | --help) sed -n '2,13p' "$0" >&2; exit 64 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

require_tools taskpolicy ditto plutil codesign
case "$(uname -m)" in
  arm64) arch=arm64 ;;
  x86_64) arch=x86_64 ;;
  *) die "unsupported host architecture $(uname -m)" ;;
esac

background() {
  if [[ $full_priority -eq 1 ]]; then
    "$@"
  else
    taskpolicy -b nice -n 20 "$@"
  fi
}

if [[ $skip_prereqs -eq 0 ]]; then
  log "build-core.sh debug (host macOS and iOS simulator)"
  if [[ $full_priority -eq 1 ]]; then
    bash "$apple_root/scripts/build-core.sh" debug
  else
    CARGO_BUILD_JOBS=2 background bash "$apple_root/scripts/build-core.sh" debug
  fi
  log "fetch-cef.sh --arch $arch"
  background bash "$apple_root/scripts/fetch-cef.sh" --arch "$arch"
  log "tuist install && tuist generate"
  (cd "$apple_root" && background mise exec -- tuist install)
  (cd "$apple_root" && background mise exec -- tuist generate --no-open)
fi

# Under the root .gitignore's `build/` rule; kept between runs so rebuilds are incremental. A plain
# build, not an archive, which recompiles every module each time. The build number goes into
# Info.plist after the build, so it never invalidates the build.
output="$apple_root/build/LocalInstall"
derived="$output/BuildData"
build_number="$(date +%Y%m%d%H%M)"
mkdir -p "$output"
build_log="$output/build.log"
log "building Debug ($arch, build $build_number); log: $build_log"
if ! background xcodebuild build -workspace "$apple_root/Omnigent.xcworkspace" -scheme OmnigentMac \
  -configuration Debug -destination "platform=macOS,arch=$arch" -derivedDataPath "$derived" \
  >"$build_log" 2>&1; then
  grep -E "(error|fatal): " "$build_log" | sort -u | head -40 >&2 || tail -40 "$build_log" >&2
  die "the build failed; see $build_log"
fi
app="$derived/Build/Products/Debug/Omnigent.app"
host="$app/Contents/Helpers/$web_host_name.app"
[[ -x "$host/Contents/MacOS/$web_host_name" ]] || die "the build did not embed $host"

staged="$output/Omnigent Native.app"
rm -rf "$staged"
ditto "$app" "$staged"
for key in CFBundleDisplayName CFBundleName; do
  plutil -replace "$key" -string "Omnigent Native" "$staged/Contents/Info.plist"
done
plutil -replace CFBundleVersion -string "$build_number" "$staged/Contents/Info.plist"

# Re-signed after the Info.plist edits: without keychain-access-groups, which ad-hoc code cannot
# carry, and without hardened runtime, whose library validation refuses ad-hoc frameworks.
background bash "$release_dir/sign-mac-developer-id.sh" --app "$staged" --identity - \
  --app-entitlements "$apple_root/Apps/Omnigent-macOS/OmnigentMac-Debug.entitlements" \
  --no-hardened-runtime
codesign --verify --deep --strict "$staged"

installed="$HOME/Applications/Omnigent Native.app"
if pgrep -qf "$installed/Contents/MacOS/"; then
  log "quitting the running Omnigent Native"
  osascript -e "tell application id \"$(plutil -extract CFBundleIdentifier raw "$installed/Contents/Info.plist")\" to quit"
  for _ in $(seq 1 50); do
    pgrep -qf "$installed/Contents/MacOS/" || break
    sleep 0.2
  done
  ! pgrep -qf "$installed/Contents/MacOS/" || die "Omnigent Native is still running; quit it and rerun"
fi
mkdir -p "$HOME/Applications"
rm -rf "$installed"
ditto "$staged" "$installed"
log "installed $installed (build $build_number)"

if [[ $launch -eq 1 ]]; then
  open "$installed"
fi
