#!/usr/bin/env bash
# Fetch the pinned CEF minimal distribution for Linux, verify it against pinned SHA-256 and
# SHA-1 checksums, and extract it under browser-host/third_party/cef (gitignored).
#
# Usage: fetch-cef-linux.sh [--arch x86_64|arm64] [--dest <dir>] [--force]
#   default arch is the host architecture; default dest is browser-host/third_party/cef.
#
# Prints the extracted distribution root (pass it to CMake as -DCEF_ROOT=<dir>) on success.
# The version pin matches apps/apple/scripts/fetch-cef.sh; bump both together.
set -euo pipefail

CEF_VERSION="156.0.15+gcf671c0+chromium-156.0.8078.80"
CEF_DIST="minimal"
CEF_CDN="https://cef-builds.spotifycdn.com"

# Pinned from https://cef-builds.spotifycdn.com/index.json and the published .sha256 files.
sha256_for() {
  case "$1" in
    linux64) echo "6873f975bb047316680ea1839980ed5bd4c33c8cd4ce45761c94211856605388" ;;
    linuxarm64) echo "806663a9eca2a8f7be185480ce7e779c5864b5cdd52bd77489053bdb1933feb8" ;;
    *) echo "fetch-cef-linux: no pinned sha256 for platform '$1'" >&2; return 1 ;;
  esac
}
sha1_for() {
  case "$1" in
    linux64) echo "09235427222e026a4f34399742df27c5d98a4f8a" ;;
    linuxarm64) echo "85602db8e813ad824b45ae54218476aa3d91d561" ;;
    *) echo "fetch-cef-linux: no pinned sha1 for platform '$1'" >&2; return 1 ;;
  esac
}

die() { echo "fetch-cef-linux: error: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCH="$(uname -m)"
DEST="$SCRIPT_DIR/../third_party/cef"
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

case "$ARCH" in
  x86_64|amd64) PLATFORM=linux64 ;;
  arm64|aarch64) PLATFORM=linuxarm64 ;;
  *) die "unsupported --arch '$ARCH' (expected x86_64 or arm64)" ;;
esac

for tool in curl sha256sum sha1sum tar bzip2; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found on PATH"
done

mkdir -p "$DEST/downloads"
DEST="$(cd "$DEST" && pwd)"
BASE="cef_binary_${CEF_VERSION}_${PLATFORM}_${CEF_DIST}"
ARCHIVE="$DEST/downloads/$BASE.tar.bz2"
DIST="$DEST/$BASE"

verify() {
  local file="$1" expected actual
  expected="$(sha256_for "$PLATFORM")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "fetch-cef-linux: SHA-256 mismatch for $file: expected $expected, got $actual" >&2
    return 1
  }
  expected="$(sha1_for "$PLATFORM")"
  actual="$(sha1sum "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "fetch-cef-linux: SHA-1 mismatch for $file: expected $expected, got $actual" >&2
    return 1
  }
}

if [[ $FORCE -eq 0 && -f "$DIST/.extracted" ]]; then
  echo "$DIST"
  exit 0
fi

if [[ -f "$ARCHIVE" ]] && ! verify "$ARCHIVE"; then
  echo "fetch-cef-linux: cached archive failed verification; re-downloading" >&2
  rm -f "$ARCHIVE"
fi
if [[ ! -f "$ARCHIVE" ]]; then
  encoded="${BASE//+/%2B}.tar.bz2"
  echo "fetch-cef-linux: downloading $CEF_CDN/$encoded" >&2
  curl --fail --location --show-error --silent --retry 3 --output "$ARCHIVE.partial" \
    "$CEF_CDN/$encoded"
  mv "$ARCHIVE.partial" "$ARCHIVE"
  verify "$ARCHIVE" || { rm -f "$ARCHIVE"; die "downloaded archive failed checksum verification"; }
fi
echo "fetch-cef-linux: verified $BASE (sha256 $(sha256_for "$PLATFORM"))" >&2

rm -rf "$DIST"
tar -xjf "$ARCHIVE" -C "$DEST"
[[ -d "$DIST/include" && -f "$DIST/Release/libcef.so" ]] || die "archive did not contain $BASE"
touch "$DIST/.extracted"
echo "$DIST"
