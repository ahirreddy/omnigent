#!/usr/bin/env bash
# Downloads the pinned Sparkle release, verifies its SHA-256, and stages its command-line tools
# (generate_appcast, sign_update, BinaryDelta) under build/sparkle/<version>/bin.
# Prints the bin directory last. Idempotent: a verified, extracted copy short-circuits.
#
# Usage: fetch-sparkle-tools.sh
#
# SPARKLE_VERSION must match the exact Sparkle version the app links (the `exact:` pin of the
# Sparkle package dependency; see RELEASE.md, "Auto-update"), so the tools and the framework
# agree on the appcast and signature formats.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SPARKLE_VERSION="2.10.1"
# sha256 of Sparkle-2.10.1.tar.xz, from the GitHub release's asset digest.
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"

[[ $# -eq 0 ]] || { sed -n '2,10p' "$0" >&2; exit 64; }
require_tools curl shasum tar

root="$apple_root/build/sparkle/$SPARKLE_VERSION"
archive="$root/Sparkle-$SPARKLE_VERSION.tar.xz"
bin="$root/dist/bin"

if [[ -f "$root/.extracted" && -x "$bin/generate_appcast" && -x "$bin/sign_update" ]]; then
  echo "$bin"
  exit 0
fi

mkdir -p "$root"
verify() {
  local actual
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$SPARKLE_SHA256" ]] || {
    echo "fetch-sparkle-tools: SHA-256 mismatch for $archive: expected $SPARKLE_SHA256, got $actual" >&2
    return 1
  }
}
if [[ -f "$archive" ]] && ! verify; then
  echo "fetch-sparkle-tools: cached archive failed verification; re-downloading" >&2
  rm -f "$archive"
fi
if [[ ! -f "$archive" ]]; then
  url="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "fetch-sparkle-tools: downloading $url" >&2
  curl --fail --location --show-error --silent --retry 3 --output "$archive.partial" "$url"
  mv "$archive.partial" "$archive"
  verify || { rm -f "$archive"; die "downloaded Sparkle archive failed checksum verification"; }
fi

rm -rf "$root/dist"
mkdir -p "$root/dist"
tar -xJf "$archive" -C "$root/dist"
for tool in generate_appcast sign_update BinaryDelta; do
  [[ -x "$bin/$tool" ]] || die "Sparkle $SPARKLE_VERSION archive has no bin/$tool"
done
touch "$root/.extracted"
echo "$bin"
