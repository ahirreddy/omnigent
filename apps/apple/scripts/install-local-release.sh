#!/usr/bin/env bash
# Builds a Release OmnigentMac for this Mac only, signs it ad hoc, and installs it as
# ~/Applications/Omnigent Native.app (bundle id ai.omnigent.mac), apart from the Debug
# "Omnigent Lab" and the Electron "Omnigent". For day-to-day use before Developer ID builds exist.
#
# Usage: install-local-release.sh [--skip-prereqs] [--no-launch]
#
# Without a team the app is not entitled to the data-protection keychain, so it keeps sign-ins in
# files only the user can read (KeychainModeSelection). Sparkle stays off: the build has no
# update key. Everything runs at background priority with two jobs so the Mac stays usable.
# --skip-prereqs reuses the current Rust core, CEF and generated workspace.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=release/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/release/common.sh"

skip_prereqs=0
launch=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-prereqs) skip_prereqs=1; shift ;;
    --no-launch) launch=0; shift ;;
    -h | --help) sed -n '2,12p' "$0" >&2; exit 64 ;;
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
  taskpolicy -b nice -n 20 "$@"
}

if [[ $skip_prereqs -eq 0 ]]; then
  log "build-core.sh release --sim-only (host macOS and iOS simulator)"
  CARGO_BUILD_JOBS=2 background bash "$apple_root/scripts/build-core.sh" release --sim-only
  log "fetch-cef.sh --arch $arch"
  background bash "$apple_root/scripts/fetch-cef.sh" --arch "$arch"
  log "tuist install && tuist generate"
  (cd "$apple_root" && background mise exec -- tuist install)
  (cd "$apple_root" && background mise exec -- tuist generate --no-open)
fi

# Under the root .gitignore's `build/` rule; kept between runs so rebuilds are incremental.
output="$apple_root/build/LocalRelease"
build_number="$(date +%Y%m%d%H%M)"
mkdir -p "$output"
build_log="$output/archive.log"
log "archiving Release ($arch, build $build_number); log: $build_log"
if ! background bash "$release_dir/archive-mac-developer-id.sh" \
  --marketing-version "$(settings_constant marketingVersion)" --build-number "$build_number" \
  --output "$output" --archs "$arch" --skip-prereqs >"$build_log" 2>&1; then
  grep -E "(error|fatal): " "$build_log" | sort -u | head -40 >&2 || tail -40 "$build_log" >&2
  die "the Release archive failed; see $build_log"
fi
app="$(tail -1 "$build_log")"
[[ -d "$app" ]] || die "the archive did not produce an app (got '$app')"

staged="$output/Omnigent Native.app"
rm -rf "$staged"
ditto "$app" "$staged"
for key in CFBundleDisplayName CFBundleName; do
  plutil -replace "$key" -string "Omnigent Native" "$staged/Contents/Info.plist"
done

# Without keychain-access-groups, which ad-hoc code cannot carry, and without hardened runtime,
# whose library validation refuses ad-hoc frameworks.
background bash "$release_dir/sign-mac-developer-id.sh" --app "$staged" --identity - \
  --app-entitlements "$apple_root/Apps/Omnigent-macOS/OmnigentMac-Debug.entitlements" \
  --no-hardened-runtime
codesign --verify --deep --strict "$staged"

installed="$HOME/Applications/Omnigent Native.app"
if pgrep -qf "$installed/Contents/MacOS/"; then
  log "quitting the running Omnigent Native"
  osascript -e 'tell application id "ai.omnigent.mac" to quit'
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
