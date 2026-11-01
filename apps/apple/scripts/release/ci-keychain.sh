#!/usr/bin/env bash
# Temporary signing keychain for CI runners. Never run this on a developer Mac: it changes the
# user keychain search list.
#
# Usage:
#   ci-keychain.sh create                   create and unlock the keychain, add it to the search
#                                           list, and print its path
#   ci-keychain.sh import P12_VAR PASS_VAR  import the base64 .p12 in the environment variable
#                                           named P12_VAR, protected by the password in PASS_VAR
#   ci-keychain.sh delete                   restore the search list and delete the keychain
#
# The secrets are read from environment variables by name, so they stay out of the workflow
# file and its logs. The .p12 password still reaches `security import -P`, which has no stdin
# option, so use this only on single-tenant CI runners.
# The keychain lives in $RUNNER_TEMP (or $TMPDIR) and has a random password kept next to it.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

usage() {
  sed -n '2,16p' "$0" >&2
  exit 64
}

[[ $# -ge 1 ]] || usage
temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
keychain="$temp_root/omnigent-release.keychain-db"
password_file="$temp_root/omnigent-release.keychain-password"
search_list_file="$temp_root/omnigent-release.keychain-search-list"
require_tools security base64 openssl

case "$1" in
  create)
    [[ $# -eq 1 ]] || usage
    [[ ! -e "$keychain" ]] || die "$keychain already exists; run '$0 delete' first"
    umask 077
    openssl rand -base64 32 >"$password_file"
    security create-keychain -p "$(cat "$password_file")" "$keychain"
    # Lock after 6 hours of inactivity instead of the default 5 minutes, so long builds can sign.
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$(cat "$password_file")" "$keychain"
    security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//' >"$search_list_file"
    existing=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && existing+=("$line")
    done <"$search_list_file"
    security list-keychains -d user -s "$keychain" "${existing[@]+"${existing[@]}"}"
    echo "$keychain"
    ;;
  import)
    [[ $# -eq 3 ]] || usage
    p12_var="$2"
    pass_var="$3"
    [[ -f "$password_file" ]] || die "no keychain; run '$0 create' first"
    [[ -n "${!p12_var:-}" ]] || die "environment variable $p12_var is empty"
    [[ -n "${!pass_var+set}" ]] || die "environment variable $pass_var is not set"
    p12="$(mktemp "$temp_root/omnigent-cert.XXXXXX")"
    trap 'rm -f "$p12"' EXIT
    printf '%s' "${!p12_var}" | base64 -D >"$p12"
    security import "$p12" -k "$keychain" -f pkcs12 -P "${!pass_var}" \
      -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/security
    # Let codesign use the keys without a UI prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
      -k "$(cat "$password_file")" "$keychain" >/dev/null
    log "identities now in $keychain"
    security find-identity -v "$keychain"
    ;;
  delete)
    [[ $# -eq 1 ]] || usage
    if [[ -f "$search_list_file" ]]; then
      restored=()
      while IFS= read -r line; do
        [[ -n "$line" ]] && restored+=("$line")
      done <"$search_list_file"
      security list-keychains -d user -s "${restored[@]+"${restored[@]}"}"
      rm -f "$search_list_file"
    fi
    if [[ -e "$keychain" ]]; then
      security delete-keychain "$keychain"
    fi
    rm -f "$password_file"
    ;;
  *) usage ;;
esac
