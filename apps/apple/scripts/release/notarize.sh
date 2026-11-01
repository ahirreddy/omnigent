#!/usr/bin/env bash
# Submits a zip, dmg or pkg to Apple's notary service with notarytool and an App Store Connect
# API key, waits for the verdict, prints the notary log, and staples the ticket.
#
# Usage: notarize.sh --file PATH [--staple PATH]
#   --staple    what to staple afterwards (the .app the zip was made from, or the dmg itself);
#               defaults to --file when it is a dmg or pkg. A zip cannot be stapled.
#
# Credentials come from the environment, as in the fastlane lanes:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to the AuthKey_<id>.p8 file)
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  sed -n '2,10p' "$0" >&2
  exit 64
}

file=""
staple=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) file="${2:?}"; shift 2 ;;
    --staple) staple="${2:?}"; shift 2 ;;
    -h | --help) usage ;;
    *) echo "error: unknown argument '$1'" >&2; usage ;;
  esac
done
[[ -n "$file" ]] || usage
[[ -f "$file" ]] || die "no file at $file"
if [[ -z "$staple" ]]; then
  case "$file" in
    *.dmg | *.pkg) staple="$file" ;;
  esac
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
[[ -f "$ASC_KEY_PATH" ]] || die "App Store Connect API key file not found: $ASC_KEY_PATH"
require_tools xcrun plutil

credentials=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
work="$(mktemp -d "${TMPDIR:-/tmp}/omnigent-notarize.XXXXXX")"
trap 'rm -rf "$work"' EXIT

log "notarytool submit $(basename "$file") (waiting for the verdict)"
submit_status=0
xcrun notarytool submit "$file" "${credentials[@]}" --wait --timeout 2h \
  --output-format json >"$work/submit.json" || submit_status=$?
cat "$work/submit.json"
echo
submission_id="$(plutil -extract id raw -o - "$work/submit.json")" ||
  die "notarytool did not return a submission id (exit $submit_status)"
verdict="$(plutil -extract status raw -o - "$work/submit.json")" ||
  die "notarytool did not return a status for $submission_id (exit $submit_status)"

log "notary log for $submission_id"
xcrun notarytool log "$submission_id" "${credentials[@]}" "$work/log.json"
cat "$work/log.json"
echo

if [[ "$verdict" != "Accepted" || $submit_status -ne 0 ]]; then
  die "notarization of $(basename "$file") ended '$verdict' (notarytool exit $submit_status)"
fi

if [[ -n "$staple" ]]; then
  log "stapler staple $(basename "$staple")"
  xcrun stapler staple "$staple"
  xcrun stapler validate "$staple"
fi
log "notarized $(basename "$file")"
