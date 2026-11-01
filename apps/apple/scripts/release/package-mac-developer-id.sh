#!/usr/bin/env bash
# Packages a signed (and, for a release, notarized and stapled) Omnigent.app as
#   <name>.zip   the Sparkle update archive (ditto, keeping the bundle's metadata)
#   <name>.dmg   the download, with an /Applications link, signed with the same identity
#
# Usage: package-mac-developer-id.sh --app PATH --output DIR --name BASENAME
#                                    --identity IDENTITY [--keychain KEYCHAIN]
#
# IDENTITY "-" ad-hoc signs the DMG for dry runs. Notarize and staple the DMG afterwards with
# notarize.sh; the zip needs no ticket of its own because the app inside is already stapled.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  sed -n '2,10p' "$0" >&2
  exit 64
}

app=""
output=""
name=""
identity=""
keychain=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    --name) name="${2:?}"; shift 2 ;;
    --identity) identity="${2:?}"; shift 2 ;;
    --keychain) keychain="${2:?}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ -n "$app" && -n "$output" && -n "$name" && -n "$identity" ]] || usage
[[ -d "$app" ]] || die "no app at $app"
require_tools ditto hdiutil codesign

mkdir -p "$output"
zip="$output/$name.zip"
dmg="$output/$name.dmg"
rm -f "$zip" "$dmg"

log "zip $(basename "$zip")"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

work="$(mktemp -d "${TMPDIR:-/tmp}/omnigent-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
staging="$work/Omnigent"
mkdir -p "$staging"
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

log "dmg $(basename "$dmg")"
hdiutil create -volname "Omnigent" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"

flags=(--force --sign "$identity")
if [[ "$identity" == "-" ]]; then
  flags+=(--timestamp=none)
else
  flags+=(--timestamp)
fi
if [[ -n "$keychain" ]]; then
  flags+=(--keychain "$keychain")
fi
codesign "${flags[@]}" "$dmg"
codesign --verify --verbose=2 "$dmg"
hdiutil verify "$dmg"

# The packaged app must still verify after the round trip.
mount="$work/mount"
mkdir -p "$mount"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount" >/dev/null
detach() { hdiutil detach "$mount" >/dev/null; }
if ! codesign --verify --deep --strict "$mount/$(basename "$app")"; then
  detach
  die "the app inside $(basename "$dmg") does not verify"
fi
detach

log "wrote $zip"
log "wrote $dmg"
