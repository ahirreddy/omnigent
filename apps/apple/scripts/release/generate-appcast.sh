#!/usr/bin/env bash
# Adds a Developer ID release to the Sparkle appcast and EdDSA-signs its update archive.
#
# Usage: generate-appcast.sh --archive ZIP --output-dir DIR --download-url-prefix URL
#                            [--existing-appcast FILE|URL | --new-feed]
#                            [--release-notes FILE.md] [--maximum-versions N]
#
#   --archive              the notarized, stapled update zip from package-mac-developer-id.sh
#   --download-url-prefix  where the zip will be served from (ends with "/")
#   --existing-appcast     the live appcast to extend (a local file or an https URL); old items
#                          are kept, up to --maximum-versions (default 10)
#   --new-feed             start a new appcast (first release only); otherwise one is required
#   --release-notes        Markdown embedded in the new item
#
# The private EdDSA key is read from the SPARKLE_ED_PRIVATE_KEY environment variable (the
# base64 key `generate_keys -x` exports) and is passed to Sparkle's tools on stdin only. The
# script fails unless the public half matches the archived app's SUPublicEDKey.
#
# Output: DIR/appcast.xml plus a copy of the archive; upload both (see RELEASE.md).
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  sed -n '2,20p' "$0" >&2
  exit 64
}

archive=""
output_dir=""
prefix=""
existing=""
new_feed=0
notes=""
maximum_versions=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --archive) archive="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --download-url-prefix) prefix="${2:?}"; shift 2 ;;
    --existing-appcast) existing="${2:?}"; shift 2 ;;
    --new-feed) new_feed=1; shift ;;
    --release-notes) notes="${2:?}"; shift 2 ;;
    --maximum-versions) maximum_versions="${2:?}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ -n "$archive" && -n "$output_dir" && -n "$prefix" ]] || usage
[[ -f "$archive" && "$archive" == *.zip ]] || die "--archive must be an existing .zip, got '$archive'"
[[ "$prefix" == https://*/ ]] || die "--download-url-prefix must be an https URL ending in '/'"
if [[ $new_feed -eq 1 && -n "$existing" ]]; then
  die "pass either --existing-appcast or --new-feed, not both"
fi
if [[ $new_feed -eq 0 && -z "$existing" ]]; then
  die "pass --existing-appcast (the live feed) or, for the first release only, --new-feed"
fi
[[ -z "$notes" || -f "$notes" ]] || die "no release notes at $notes"
: "${SPARKLE_ED_PRIVATE_KEY:?set SPARKLE_ED_PRIVATE_KEY to the base64 private EdDSA key}"
require_tools unzip plutil openssl base64 xxd python3 curl

bin="$(bash "$release_dir/fetch-sparkle-tools.sh" | tail -1)"

# The public key for the private key: a 32-byte seed (current format) is expanded with
# openssl; the legacy 96-byte format already ends with the public key.
public_key_for_private() {
  local length
  length="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | base64 -D | wc -c | tr -d ' ')"
  case "$length" in
    32)
      {
        printf '302e020100300506032b657004220420' | xxd -r -p
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | base64 -D
      } | openssl pkey -inform DER -pubout -outform DER | tail -c 32 | base64
      ;;
    96) printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | base64 -D | tail -c 32 | base64 ;;
    *) die "SPARKLE_ED_PRIVATE_KEY decodes to $length bytes; expected a 32- or 96-byte EdDSA key" ;;
  esac
}

app_name="$(unzip -Z1 "$archive" | sed -n 's|^\([^/]*\.app\)/Contents/Info.plist$|\1|p' | head -1)"
[[ -n "$app_name" ]] || die "$archive does not contain an app bundle at its top level"
info="$(unzip -p "$archive" "$app_name/Contents/Info.plist")"
app_key="$(plutil -extract SUPublicEDKey raw -o - - <<<"$info")" ||
  die "$app_name has no SUPublicEDKey in its Info.plist"
build_number="$(plutil -extract CFBundleVersion raw -o - - <<<"$info")"
short_version="$(plutil -extract CFBundleShortVersionString raw -o - - <<<"$info")"
signing_key="$(public_key_for_private)"
[[ "$app_key" == "$signing_key" ]] ||
  die "SUPublicEDKey in $app_name ($app_key) does not match SPARKLE_ED_PRIVATE_KEY's public key ($signing_key)"

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
work="$output_dir/appcast-work"
rm -rf "$work"
mkdir -p "$work"
base="$(basename "$archive" .zip)"
cp "$archive" "$work/$base.zip"
if [[ -n "$notes" ]]; then
  cp "$notes" "$work/$base.md"
fi

if [[ -n "$existing" ]]; then
  if [[ "$existing" == https://* ]]; then
    log "fetching the live appcast $existing"
    curl --fail --location --show-error --silent --retry 3 --output "$work/appcast.xml" "$existing"
  else
    [[ -f "$existing" ]] || die "no appcast at $existing"
    cp "$existing" "$work/appcast.xml"
  fi
  # Sparkle compares CFBundleVersion; a build at or below the newest item would never install.
  python3 -I - "$work/appcast.xml" "$build_number" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
path, build = sys.argv[1], int(sys.argv[2])
versions = [int(v.text) for v in ET.parse(path).getroot().iterfind("channel/item/sparkle:version", ns)]
if versions and build <= max(versions):
    sys.exit(f"error: build {build} is not newer than the appcast's latest build {max(versions)}")
PY
fi

log "generate_appcast ($short_version, build $build_number)"
generate_args=(--ed-key-file - --download-url-prefix "$prefix" --maximum-versions "$maximum_versions"
  -o "$work/appcast.xml")
if [[ -n "$notes" ]]; then
  generate_args+=(--embed-release-notes)
fi
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$bin/generate_appcast" "${generate_args[@]}" "$work"

# The new item must be there, point at the uploaded name, and carry a valid signature.
signature="$(python3 -I - "$work/appcast.xml" "$build_number" "$prefix$base.zip" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
path, build, url = sys.argv[1], sys.argv[2], sys.argv[3]
for item in ET.parse(path).getroot().iterfind("channel/item"):
    if item.findtext("sparkle:version", namespaces=ns) == build:
        enclosure = item.find("enclosure")
        if enclosure is None or enclosure.get("url") != url:
            sys.exit(f"error: item for build {build} does not point at {url}")
        signature = enclosure.get("{%s}edSignature" % ns["sparkle"])
        if not signature:
            sys.exit(f"error: item for build {build} has no sparkle:edSignature")
        print(signature)
        break
else:
    sys.exit(f"error: appcast has no item for build {build}")
PY
)"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
  "$bin/sign_update" --verify --ed-key-file - "$work/$base.zip" "$signature"

cp "$work/appcast.xml" "$output_dir/appcast.xml"
log "wrote $output_dir/appcast.xml (upload $base.zip to $prefix)"
