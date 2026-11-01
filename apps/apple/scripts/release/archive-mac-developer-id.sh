#!/usr/bin/env bash
# Builds an unsigned Release archive of OmnigentMac (the Developer ID edition). Signing happens
# afterwards, inside-out, in sign-mac-developer-id.sh, so the archive is built with
# CODE_SIGNING_ALLOWED=NO.
#
# Usage: archive-mac-developer-id.sh --marketing-version V --build-number N --output DIR
#                                    [--archs "arm64 x86_64"] [--skip-prereqs]
#
# Prerequisites (skipped with --skip-prereqs, for a workspace that is already generated):
#   scripts/build-core.sh release          universal Rust core xcframework + bindings
#   scripts/fetch-cef.sh --arch universal  CEF for both architectures
#   tuist install && tuist generate        (through mise when it is installed)
#
# --archs defaults to "arm64 x86_64" (universal). A thinner value is for local dry runs against
# a host-only core and CEF.
#
# Output: DIR/Omnigent.xcarchive; prints the path of the archived app last.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  sed -n '2,17p' "$0" >&2
  exit 64
}

marketing_version=""
build_number=""
output=""
archs="arm64 x86_64"
skip_prereqs=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --marketing-version) marketing_version="${2:?}"; shift 2 ;;
    --build-number) build_number="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    --archs) archs="${2:?}"; shift 2 ;;
    --skip-prereqs) skip_prereqs=1; shift ;;
    -h | --help) usage ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ -n "$marketing_version" && -n "$build_number" && -n "$output" ]] || usage
[[ "$build_number" =~ ^[0-9]+$ ]] || die "--build-number must be a positive integer, got '$build_number'"
[[ "$marketing_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "--marketing-version must be MAJOR.MINOR.PATCH, got '$marketing_version'"

require_tools xcodebuild lipo plutil

run_tuist() {
  if command -v mise >/dev/null 2>&1; then
    (cd "$apple_root" && mise exec -- tuist "$@")
  else
    require_tools tuist
    (cd "$apple_root" && tuist "$@")
  fi
}

if [[ $skip_prereqs -eq 0 ]]; then
  log "build-core.sh release (universal macOS slice)"
  bash "$apple_root/scripts/build-core.sh" release
  log "fetch-cef.sh --arch universal"
  bash "$apple_root/scripts/fetch-cef.sh" --arch universal
  log "tuist install && tuist generate"
  run_tuist install
  run_tuist generate --no-open
fi
[[ -d "$apple_root/Omnigent.xcworkspace" ]] ||
  die "$apple_root/Omnigent.xcworkspace is missing; run without --skip-prereqs or 'just apple-generate'"

mkdir -p "$output"
output="$(cd "$output" && pwd)"
archive="$output/Omnigent.xcarchive"
rm -rf "$archive"

log "xcodebuild archive OmnigentMac ($marketing_version, build $build_number, archs: $archs)"
xcodebuild archive \
  -workspace "$apple_root/Omnigent.xcworkspace" \
  -scheme OmnigentMac \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -derivedDataPath "$output/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="$archs" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number"

app="$archive/Products/Applications/Omnigent.app"
[[ -d "$app" ]] || die "archive has no $app"
host="$app/Contents/Helpers/$web_host_name.app"
[[ -x "$host/Contents/MacOS/$web_host_name" ]] || die "archive app does not embed $host"
[[ -d "$host/Contents/Frameworks/$cef_framework_name" ]] || die "web host has no $cef_framework_name"

# Every bundle carries the injected versions, and every Mach-O has every requested arch.
while IFS= read -r -d '' plist; do
  short="$(plutil -extract CFBundleShortVersionString raw -o - "$plist")"
  version="$(plutil -extract CFBundleVersion raw -o - "$plist")"
  bundle="${plist%/Contents/Info.plist}"
  case "$bundle" in
    "$app" | "$host" | "$host/Contents/Frameworks/$web_host_name Helper"*)
      [[ "$short" == "$marketing_version" && "$version" == "$build_number" ]] ||
        die "$bundle has version $short ($version), expected $marketing_version ($build_number)"
      ;;
  esac
done < <(find "$app" -path '*/Contents/Info.plist' -print0)

while IFS= read -r -d '' file; do
  if is_macho "$file"; then
    have="$(lipo -archs "$file")"
    for arch in $archs; do
      [[ " $have " == *" $arch "* ]] || die "$file has [$have], missing $arch"
    done
  fi
done < <(find "$app" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)

log "archived $app"
echo "$app"
