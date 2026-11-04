#!/usr/bin/env bash
# Signs an unsigned OmnigentMac.app inside-out with hardened runtime:
#   1. the web host's Chromium Embedded Framework (its Libraries/*.dylib, then the framework)
#   2. the five CEF helper apps, each with its own entitlements
#   3. Omnigent Web Host.app (no entitlements; BrowserTargets.swift gives it none)
#   4. the app's own Contents/Frameworks (third-party frameworks such as Sparkle, nested code
#      first, keeping each nested item's entitlements) and loose dylibs
#   5. the app, with OmnigentMac.entitlements
# Then it fails if any Mach-O in the bundle is still unsigned or is signed by someone else.
#
# Usage: sign-mac-developer-id.sh --app PATH --identity IDENTITY
#                                 [--entitlements-dir DIR] [--app-entitlements FILE]
#                                 [--keychain KEYCHAIN] [--no-hardened-runtime]
#
# IDENTITY is a codesign identity ("Developer ID Application: Databricks, Inc. (8RMX4WU6F8)")
# or "-" for an ad-hoc dry run, which uses no secure timestamp.
# --no-hardened-runtime is for an ad-hoc build meant to run: hardened runtime's library validation
# refuses ad-hoc frameworks ("different Team IDs"), so such an app dies at launch.
# --entitlements-dir defaults to Derived/Entitlements, where `tuist generate` writes the helper
# entitlements from BrowserTargets.helperVariants (OmnigentMacWebHostHelper<Variant>.entitlements).
# --app-entitlements defaults to Apps/Omnigent-macOS/OmnigentMac.entitlements.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  sed -n '2,21p' "$0" >&2
  exit 64
}

app=""
identity=""
entitlements_dir="$apple_root/Derived/Entitlements"
app_entitlements="$apple_root/Apps/Omnigent-macOS/OmnigentMac.entitlements"
keychain=""
hardened_runtime=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?}"; shift 2 ;;
    --identity) identity="${2:?}"; shift 2 ;;
    --entitlements-dir) entitlements_dir="${2:?}"; shift 2 ;;
    --app-entitlements) app_entitlements="${2:?}"; shift 2 ;;
    --keychain) keychain="${2:?}"; shift 2 ;;
    --no-hardened-runtime) hardened_runtime=0; shift ;;
    -h | --help) usage ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ -n "$app" && -n "$identity" ]] || usage
[[ -d "$app/Contents/MacOS" ]] || die "$app is not an app bundle"
[[ -f "$app_entitlements" ]] || die "missing app entitlements $app_entitlements"
require_tools codesign file plutil

if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$app_entitlements" >/dev/null 2>&1; then
  die "$app_entitlements enables App Sandbox, which the Chromium web host cannot run inside"
fi

flags=(--force --sign "$identity")
if [[ $hardened_runtime -eq 1 ]]; then
  flags+=(--options runtime)
fi
if [[ "$identity" == "-" ]]; then
  flags+=(--timestamp=none)
else
  flags+=(--timestamp)
fi
if [[ -n "$keychain" ]]; then
  flags+=(--keychain "$keychain")
fi

sign() {
  echo "    sign ${1#"$app"/}"
  codesign "${flags[@]}" "${@:2}" "$1"
}

host="$app/Contents/Helpers/$web_host_name.app"
host_frameworks="$host/Contents/Frameworks"
cef="$host_frameworks/$cef_framework_name"
[[ -d "$host" ]] || die "$app has no $host"
[[ -d "$cef" ]] || die "$host has no $cef_framework_name"

log "1/5 Chromium Embedded Framework"
shopt -s nullglob
cef_libraries=("$cef/Versions/A/Libraries/"*.dylib)
shopt -u nullglob
[[ ${#cef_libraries[@]} -gt 0 ]] || die "$cef has no Libraries/*.dylib; is the CEF layout versioned?"
for library in "${cef_libraries[@]}"; do
  sign "$library"
done
sign "$cef"

log "2/5 CEF helpers"
for index in "${!helper_suffixes[@]}"; do
  helper="$host_frameworks/$web_host_name Helper${helper_suffixes[$index]}.app"
  entitlements="$entitlements_dir/OmnigentMacWebHostHelper${helper_identifiers[$index]}.entitlements"
  [[ -d "$helper" ]] || die "missing helper $helper"
  [[ -f "$entitlements" ]] || die "missing helper entitlements $entitlements (run tuist generate)"
  sign "$helper" --entitlements "$entitlements"
done
# Anything else in the host's Frameworks would be unsigned or carry the wrong entitlements.
while IFS= read -r -d '' entry; do
  name="$(basename "$entry")"
  known=0
  [[ "$name" == "$cef_framework_name" ]] && known=1
  for suffix in "${helper_suffixes[@]}"; do
    [[ "$name" == "$web_host_name Helper$suffix.app" ]] && known=1
  done
  [[ $known -eq 1 ]] || die "unexpected item in the web host's Frameworks: $entry"
done < <(find "$host_frameworks" -mindepth 1 -maxdepth 1 -print0)

log "3/5 web host"
sign "$host"

# Signs a third-party framework (such as Sparkle) inside-out: loose executables directly in
# Versions/<v>/ (Sparkle's Autoupdate), then nested bundles (Updater.app, XPCServices/*.xpc),
# each keeping its own entitlements, then the framework itself.
sign_framework() {
  local framework="$1" binary_name item
  binary_name="$(basename "$framework" .framework)"
  [[ -d "$framework/Versions" ]] || die "$framework is not a versioned framework"
  while IFS= read -r -d '' item; do
    if [[ "$(basename "$item")" != "$binary_name" ]] && is_macho "$item"; then
      sign "$item" --preserve-metadata=entitlements
    fi
  done < <(find "$framework/Versions" -mindepth 2 -maxdepth 2 -type f -print0)
  while IFS= read -r -d '' item; do
    sign "$item" --preserve-metadata=entitlements
  done < <(find "$framework/Versions" -mindepth 2 -maxdepth 3 \( -name '*.app' -o -name '*.xpc' \) -prune -print0)
  sign "$framework"
}

log "4/5 app frameworks"
if [[ -d "$app/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' entry; do
    case "$entry" in
      *.framework) sign_framework "$entry" ;;
      *.dylib) sign "$entry" ;;
      *) die "unexpected item in the app's Frameworks: $entry" ;;
    esac
  done < <(find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 -print0)
fi
for location in PlugIns XPCServices Library/LoginItems; do
  [[ ! -e "$app/Contents/$location" ]] ||
    die "$app/Contents/$location exists; teach sign-mac-developer-id.sh to sign it"
done

log "5/5 app"
sign "$app" --entitlements "$app_entitlements"

log "checking every Mach-O is signed by this identity"
expected_team=""
if [[ "$identity" != "-" ]]; then
  expected_team="$(codesign -d --verbose=2 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ -n "$expected_team" && "$expected_team" != "not set" ]] || die "$app has no TeamIdentifier"
fi
failures=0
while IFS= read -r -d '' file; do
  is_macho "$file" || continue
  if ! details="$(codesign -d --verbose=2 "$file" 2>&1)"; then
    echo "error: unsigned Mach-O: $file" >&2
    echo "$details" >&2
    failures=$((failures + 1))
    continue
  fi
  if [[ -n "$expected_team" ]]; then
    team="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"
    if [[ "$team" != "$expected_team" ]]; then
      echo "error: $file is signed by team '$team', expected '$expected_team'" >&2
      failures=$((failures + 1))
    fi
  fi
done < <(find "$app" -type f -print0)
[[ $failures -eq 0 ]] || die "$failures Mach-O file(s) are not signed correctly"
log "signed $app"
