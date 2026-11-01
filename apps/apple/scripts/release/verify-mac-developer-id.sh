#!/usr/bin/env bash
# Verifies a signed OmnigentMac.app:
#   - codesign --verify --deep --strict on the app
#   - hardened runtime on every signed executable bundle, web host and helper
#   - each CEF helper carries exactly the entitlements Tuist generated for it, and the app has
#     no App Sandbox
#   - with --notarized: spctl --assess (Gatekeeper) and a stapled ticket
#
# Usage: verify-mac-developer-id.sh --app PATH [--entitlements-dir DIR] [--notarized]
#
# Gatekeeper rejects ad-hoc and un-notarized Developer ID code by design, so spctl runs only
# with --notarized, after notarize.sh has stapled the app.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  sed -n '2,13p' "$0" >&2
  exit 64
}

app=""
entitlements_dir="$apple_root/Derived/Entitlements"
notarized=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?}"; shift 2 ;;
    --entitlements-dir) entitlements_dir="${2:?}"; shift 2 ;;
    --notarized) notarized=1; shift ;;
    -h | --help) usage ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ -n "$app" ]] || usage
[[ -d "$app" ]] || die "no app at $app"
require_tools codesign python3 spctl xcrun

log "codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$app"

host="$app/Contents/Helpers/$web_host_name.app"
host_frameworks="$host/Contents/Frameworks"

# Prints the entitlements of signed code as an XML plist ("" when it has none).
entitlements_of() {
  codesign -d --entitlements - --xml "$1"
}

# Compares the signed entitlements of $1 with the plist file $2 (or with none when $2 is "").
expect_entitlements() {
  local code="$1" expected="$2" actual
  actual="$(entitlements_of "$code")"
  python3 -I - "$expected" "$actual" "$code" <<'PY'
import plistlib, sys
expected_path, actual_xml, code = sys.argv[1], sys.argv[2], sys.argv[3]
expected = {}
if expected_path:
    with open(expected_path, "rb") as f:
        expected = plistlib.load(f)
actual = plistlib.loads(actual_xml.encode()) if actual_xml.strip() else {}
if actual != expected:
    sys.exit(f"error: {code} entitlements {actual} != expected {expected}")
PY
}

expect_runtime() {
  local code="$1" flags
  flags="$(codesign -d --verbose=2 "$code" 2>&1 | sed -n 's/^CodeDirectory .* flags=\([^ ]*\).*/\1/p')"
  [[ "$flags" == *"(runtime)"* || "$flags" == *",runtime"* ]] ||
    die "$code is not signed with hardened runtime (flags: ${flags:-none})"
}

log "hardened runtime and entitlements"
expect_runtime "$app"
if entitlements_of "$app" | grep -q 'com.apple.security.app-sandbox'; then
  die "$app is signed with App Sandbox; the Developer ID edition must not be"
fi
expect_runtime "$host"
expect_entitlements "$host" ""
for index in "${!helper_suffixes[@]}"; do
  helper="$host_frameworks/$web_host_name Helper${helper_suffixes[$index]}.app"
  expect_runtime "$helper"
  expect_entitlements "$helper" \
    "$entitlements_dir/OmnigentMacWebHostHelper${helper_identifiers[$index]}.entitlements"
  echo "    ok ${helper#"$app"/}"
done

if [[ $notarized -eq 1 ]]; then
  log "spctl --assess (Gatekeeper)"
  spctl --assess --type execute --verbose=4 "$app"
  log "stapler validate"
  xcrun stapler validate "$app"
else
  log "skipping spctl: only notarized Developer ID code passes Gatekeeper (pass --notarized)"
fi
log "verified $app"
