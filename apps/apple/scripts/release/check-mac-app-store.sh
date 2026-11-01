#!/usr/bin/env bash
# Checks an archived OmnigentMacAppStore app before it is exported and uploaded:
#   - no Chromium anywhere in the bundle (WebHost/Scripts/check-no-chromium.sh, the same check
#     the target's build phase runs)
#   - no Sparkle: the App Store updates the app, and App Review rejects self-updaters
#   - the signed app has App Sandbox, as the Mac App Store requires
#
# Usage: check-mac-app-store.sh --app PATH
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?}"; shift 2 ;;
    -h | --help) sed -n '2,9p' "$0" >&2; exit 64 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[[ -n "$app" ]] || die "usage: $(basename "$0") --app PATH"
[[ -d "$app/Contents/MacOS" ]] || die "$app is not an app bundle"
require_tools codesign python3

log "check-no-chromium.sh"
TARGET_BUILD_DIR="$(dirname "$app")" WRAPPER_NAME="$(basename "$app")" \
  bash "$apple_root/WebHost/Scripts/check-no-chromium.sh"

log "checking that Sparkle is absent"
found="$(find "$app" \( -iname 'Sparkle*' -o -name 'Autoupdate' -o -name 'SUUpdater*' \) -print -quit)"
[[ -z "$found" ]] || die "$app must not contain Sparkle, but has $found"

log "checking App Sandbox"
entitlements="$(codesign -d --entitlements - --xml "$app")"
python3 -I -c '
import plistlib, sys
data = sys.argv[1].encode()
entitlements = plistlib.loads(data) if data.strip() else {}
sys.exit(0 if entitlements.get("com.apple.security.app-sandbox") is True else 1)
' "$entitlements" || die "$app is not signed with com.apple.security.app-sandbox"
log "$app is a WebKit-only, sandboxed App Store build"
