#!/usr/bin/env bash
# CI only: build Omnigent's CEF minimal distribution for one macOS architecture from source,
# with Omnigent's patches, and stage the archive and its SHA-256 for a GitHub release. Developers
# never run this; they fetch the result with `fetch-cef.sh --source omnigent`.
# See apps/apple/docs/browser-engine-decision.md, "Prebuilt engine pipeline".
#
# Usage: build-cef.sh --arch arm64|x86_64 --cef-branch <branch> --cef-commit <commit>
#                     --build <omnigent build id> --work <dir> --out <dir>
#   --cef-branch   CEF release branch (the Chromium build number, e.g. 8078 for 156.0.8078.x).
#   --cef-commit   CEF commit to check out on that branch.
#   --build        Omnigent build ID, e.g. 156.0.8078.80-omnigent.1.
#   --work         Persistent work directory (about 150 GB): depot_tools, the Chromium checkout
#                  and build output. Keep it between runs; incremental builds are much faster.
#   --out          Where omnigent-cef-<build>-<platform>-minimal.tar.bz2 and .sha256 go.
#
# Patches: scripts/engine/patches/chromium/*.patch apply to chromium/src and
# scripts/engine/patches/cef/*.patch to chromium/src/cef, in name order. Every patch must apply
# cleanly; a failure stops the build.
#
# Requirements: macOS with the Xcode version Chromium's branch needs, python3, git, about 150 GB of
# free disk and 32 GB of RAM.
set -euo pipefail

die() { echo "build-cef: error: $*" >&2; exit 1; }

ARCH="" CEF_BRANCH="" CEF_COMMIT="" BUILD_ID="" WORK="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --cef-branch) CEF_BRANCH="${2:-}"; shift 2 ;;
    --cef-commit) CEF_COMMIT="${2:-}"; shift 2 ;;
    --build) BUILD_ID="${2:-}"; shift 2 ;;
    --work) WORK="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
for name in ARCH CEF_BRANCH CEF_COMMIT BUILD_ID WORK OUT; do
  [[ -n "${!name}" ]] || die "missing --$(echo "$name" | tr '[:upper:]_' '[:lower:]-')"
done
case "$ARCH" in
  arm64) PLATFORM=macosarm64; ARCH_FLAG=--arm64-build ;;
  x86_64) PLATFORM=macosx64; ARCH_FLAG=--x64-build ;;
  *) die "unsupported --arch '$ARCH' (expected arm64 or x86_64)" ;;
esac
[[ "$(uname -s)" == "Darwin" ]] || die "Chromium for macOS builds on macOS only"
for tool in curl git python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found on PATH"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHES="$SCRIPT_DIR/patches"
DEPOT_TOOLS="$WORK/depot_tools"
DOWNLOAD="$WORK/download"
AUTOMATE="$WORK/automate-git.py"
mkdir -p "$WORK" "$OUT" "$DOWNLOAD"

if [[ ! -d "$DEPOT_TOOLS/.git" ]]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
fi
export PATH="$DEPOT_TOOLS:$PATH"
curl --fail --location --show-error --retry 3 --output "$AUTOMATE" \
  "https://raw.githubusercontent.com/chromiumembedded/cef/${CEF_COMMIT}/tools/automate/automate-git.py"

# Release build settings. Proprietary codecs (H.264, AAC) need a patent license review before
# they are turned on; see the decision doc.
export GN_DEFINES="is_official_build=true chrome_pgo_phase=0 symbol_level=1"
export CEF_ARCHIVE_FORMAT=tar.bz2

automate() {
  python3 "$AUTOMATE" --download-dir="$DOWNLOAD" --depot-tools-dir="$DEPOT_TOOLS" \
    --branch="$CEF_BRANCH" --checkout="$CEF_COMMIT" "$ARCH_FLAG" --minimal-distrib \
    --no-debug-build --no-distrib-docs "$@"
}

# 1. Check out (or update) Chromium and CEF without building.
automate --no-build --no-distrib

# 2. Apply Omnigent's patches to a clean tree.
SRC="$DOWNLOAD/chromium/src"
[[ -d "$SRC/cef" ]] || die "checkout did not produce $SRC/cef"
apply_patches() {
  local tree="$1" directory="$2" patch
  [[ -d "$directory" ]] || return 0
  for patch in "$directory"/*.patch; do
    [[ -e "$patch" ]] || continue
    echo "build-cef: applying $(basename "$patch") to $tree"
    git -C "$tree" apply --check "$patch" || die "$(basename "$patch") does not apply to $tree"
    git -C "$tree" apply "$patch"
  done
}
git -C "$SRC" checkout -- . && git -C "$SRC" clean -fdq -e cef -e out
git -C "$SRC/cef" checkout -- . && git -C "$SRC/cef" clean -fdq
apply_patches "$SRC" "$PATCHES/chromium"
apply_patches "$SRC/cef" "$PATCHES/cef"

# 3. Build and package with the patched tree.
automate --no-update --force-build --force-distrib

DISTRIB="$(find "$SRC/cef/binary_distrib" -maxdepth 1 -name "cef_binary_*_${PLATFORM}_minimal.tar.bz2" \
  -newer "$AUTOMATE" | head -1)"
[[ -n "$DISTRIB" ]] || die "no ${PLATFORM} minimal distribution was produced"
ASSET="omnigent-cef-${BUILD_ID}-${PLATFORM}-minimal.tar.bz2"
cp "$DISTRIB" "$OUT/$ASSET"
(cd "$OUT" && shasum -a 256 "$ASSET" >"$ASSET.sha256")
CEF_VERSION="$(basename "$DISTRIB" | sed -E "s/^cef_binary_(.*)_${PLATFORM}_minimal\\.tar\\.bz2$/\\1/")"
echo "build-cef: OMNIGENT_CEF_VERSION=\"$CEF_VERSION\""
echo "build-cef: OMNIGENT_CEF_SHA256_$(echo "$PLATFORM" | tr '[:lower:]' '[:upper:]')=\"$(awk '{print $1}' "$OUT/$ASSET.sha256")\""
