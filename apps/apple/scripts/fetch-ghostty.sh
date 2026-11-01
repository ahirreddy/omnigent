#!/usr/bin/env bash
# Fetch the pinned libghostty source (the MIT manaflow-ai/ghostty fork), verify its SHA-256,
# build GhosttyKit.xcframework with the pinned Zig, and stage it under apps/apple/Vendor/ghostty.
#
# Usage: fetch-ghostty.sh [--target universal|native] [--force]
#   universal (default): macOS arm64+x86_64, iOS arm64 and iOS simulator arm64 slices.
#   native: the host macOS slice only (faster local iteration; no iOS).
#
# Output layout (consumed by Packages/OmnigentGhosttyKit/Package.swift):
#   Vendor/ghostty/out/GhosttyKit.xcframework   ghostty.h + module map + static libghostty
#   Vendor/ghostty/out/LICENSE                  Ghostty's MIT license (ship it in notices)
#   Vendor/ghostty/out/GHOSTTY_VERSION          pinned source, Zig and target, written last
#
# Caches (safe to persist in CI, keyed on this file's hash):
#   Vendor/ghostty/downloads/   verified source tarballs
#   Vendor/ghostty/zig-cache/   ZIG_GLOBAL_CACHE_DIR (Zig package and build cache)
#
# Requirements: Xcode with the Metal toolchain (xcodebuild -downloadComponent MetalToolchain),
# mise (installs the pinned Zig), curl, shasum, tar.
#
# Idempotent: a matching GHOSTTY_VERSION stamp short-circuits. Every failure exits non-zero.
set -euo pipefail

# Pinned source. See Packages/OmnigentTerminalUI/DESIGN.md ("Which libghostty") for why this
# is the manaflow-ai fork and what to check when bumping it. To bump: pick a commit, update
# GHOSTTY_COMMIT, run with --force, copy the printed SHA-256 into GHOSTTY_SHA256, and confirm
# the REQUIRED_SYMBOLS below still exist.
GHOSTTY_REPO="manaflow-ai/ghostty"
GHOSTTY_COMMIT="2c1a19d7e4fae25ed2224da65592215c9013c785"
GHOSTTY_SHA256="7a32351b3662a197669051c4d18fdce34e92a646875c6eba0d416ed988da0cf2"
# build.zig.zon minimum_zig_version at that commit.
ZIG_VERSION="0.16.0"
# The fork-only embedding API OmnigentTerminalUI depends on.
REQUIRED_SYMBOLS=(
  ghostty_surface_process_output
  GHOSTTY_SURFACE_IO_MANUAL_MIRROR
  io_write_cb
  ghostty_surface_set_size
  ghostty_surface_size
  ghostty_platform_ios_s
)

die() { echo "fetch-ghostty: error: $*" >&2; exit 1; }

TARGET="universal"
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
case "$TARGET" in
  universal|native) ;;
  *) die "unsupported --target '$TARGET' (expected universal or native)" ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || die "GhosttyKit builds on macOS only"
for tool in curl shasum tar mise xcrun; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found on PATH"
done
xcrun -sdk macosx metal --version >/dev/null 2>&1 \
  || die "the Metal toolchain is missing; run: xcodebuild -downloadComponent MetalToolchain"
if [[ "$TARGET" == "universal" ]]; then
  xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1 || die "the iOS SDK is missing from Xcode"
  xcrun -sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 \
    || die "the iOS simulator SDK is missing from Xcode"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$(cd "$SCRIPT_DIR/.." && pwd)/Vendor/ghostty"
DOWNLOADS="$VENDOR/downloads"
SRC_ROOT="$VENDOR/src"
OUT="$VENDOR/out"
SHORT="${GHOSTTY_COMMIT:0:12}"
# `headers:GhosttyKit` is the staged layout (see "Namespace the headers" below); changing the
# layout changes the stamp, so an older staging is rebuilt.
STAMP_CONTENT="$GHOSTTY_REPO@$GHOSTTY_COMMIT zig-$ZIG_VERSION $TARGET ReleaseFast no-sentry headers:GhosttyKit memset-localized"

if [[ $FORCE -eq 0 && -f "$OUT/GHOSTTY_VERSION" && "$(cat "$OUT/GHOSTTY_VERSION")" == "$STAMP_CONTENT" ]]; then
  echo "fetch-ghostty: GhosttyKit ($SHORT, $TARGET) already staged at $OUT"
  exit 0
fi

mkdir -p "$DOWNLOADS" "$SRC_ROOT"

verify() {
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [[ "$actual" != "$GHOSTTY_SHA256" ]]; then
    echo "fetch-ghostty: SHA-256 mismatch for $1: expected $GHOSTTY_SHA256, got $actual" >&2
    return 1
  fi
}

ARCHIVE="$DOWNLOADS/ghostty-$GHOSTTY_COMMIT.tar.gz"
if [[ -f "$ARCHIVE" ]] && ! verify "$ARCHIVE"; then
  echo "fetch-ghostty: cached archive failed verification; re-downloading" >&2
  rm -f "$ARCHIVE"
fi
if [[ ! -f "$ARCHIVE" ]]; then
  URL="https://codeload.github.com/$GHOSTTY_REPO/tar.gz/$GHOSTTY_COMMIT"
  echo "fetch-ghostty: downloading $URL"
  curl --fail --location --show-error --retry 3 --output "$ARCHIVE.partial" "$URL"
  mv "$ARCHIVE.partial" "$ARCHIVE"
  verify "$ARCHIVE" || { rm -f "$ARCHIVE"; die "downloaded archive failed checksum verification"; }
fi
echo "fetch-ghostty: verified ghostty-$SHORT.tar.gz (sha256 $GHOSTTY_SHA256)"

SRC="$SRC_ROOT/ghostty-$GHOSTTY_COMMIT"
if [[ ! -f "$SRC/.extracted" ]]; then
  rm -rf "$SRC"
  tar -xzf "$ARCHIVE" -C "$SRC_ROOT"
  [[ -f "$SRC/build.zig" ]] || die "archive did not contain ghostty-$GHOSTTY_COMMIT/build.zig"
  touch "$SRC/.extracted"
fi

for symbol in "${REQUIRED_SYMBOLS[@]}"; do
  grep -q "$symbol" "$SRC/include/ghostty.h" \
    || die "ghostty.h at $SHORT lacks $symbol, which OmnigentTerminalUI requires"
done

ZON_ZIG="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' "$SRC/build.zig.zon")"
[[ "$ZON_ZIG" == "$ZIG_VERSION" ]] \
  || die "build.zig.zon wants Zig $ZON_ZIG but this script pins $ZIG_VERSION"
ZON_VERSION="$(sed -n 's/^    \.version = "\([^"]*\)".*/\1/p' "$SRC/build.zig.zon")"
[[ -n "$ZON_VERSION" ]] || die "could not read .version from build.zig.zon"

echo "fetch-ghostty: installing Zig $ZIG_VERSION with mise"
mise install --yes "zig@$ZIG_VERSION" >/dev/null || die "mise could not install zig@$ZIG_VERSION"
ACTUAL_ZIG="$(mise exec "zig@$ZIG_VERSION" -- zig version)"
[[ "$ACTUAL_ZIG" == "$ZIG_VERSION" ]] || die "mise provided Zig $ACTUAL_ZIG, not $ZIG_VERSION"

export ZIG_GLOBAL_CACHE_DIR="$VENDOR/zig-cache"
LOG="$VENDOR/build-$TARGET.log"
echo "fetch-ghostty: building GhosttyKit.xcframework ($TARGET); log: $LOG"
# An explicit version string keeps the build from asking git, which would describe the
# enclosing Omnigent checkout rather than the extracted tarball. Sentry is off: Ghostty would
# otherwise install its own crash handler (local minidumps) inside the Omnigent app process.
(
  cd "$SRC"
  mise exec "zig@$ZIG_VERSION" -- zig build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target="$TARGET" \
    -Demit-macos-app=false \
    -Demit-docs=false \
    -Dsentry=false \
    -Dversion-string="$ZON_VERSION+omnigent.$SHORT"
) >"$LOG" 2>&1 || { tail -60 "$LOG" >&2; die "zig build failed (full log: $LOG)"; }

BUILT="$SRC/macos/GhosttyKit.xcframework"
[[ -f "$BUILT/Info.plist" ]] || die "the build did not produce $BUILT"
EXPECTED_SLICES=(macos-arm64_x86_64)
if [[ "$TARGET" == "native" ]]; then
  EXPECTED_SLICES=("macos-$(uname -m)")
else
  EXPECTED_SLICES+=(ios-arm64 ios-arm64-simulator)
fi
for slice in "${EXPECTED_SLICES[@]}"; do
  [[ -f "$BUILT/$slice/Headers/ghostty.h" ]] || die "GhosttyKit.xcframework lacks the $slice slice"
done

STAGE="$VENDOR/out.staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$BUILT" "$STAGE/GhosttyKit.xcframework"
# libghostty's quirks_memset takes its fill as a byte and so mishandles C callers passing an int;
# keep it private to libghostty so Swift and the Rust core in the same image bind libSystem's.
bash "$SCRIPT_DIR/localize-ghostty-memset.sh" "$STAGE/GhosttyKit.xcframework"
# Namespace the headers: Xcode copies every static xcframework's Headers into one
# `$(BUILT_PRODUCTS_DIR)/include`, so two of them with a top-level module.modulemap (this one and
# omnigent_ffiFFI's) collide ("Multiple commands produce .../include/module.modulemap"). Under
# Headers/GhosttyKit/ the module map is found by module name and nothing collides.
for slice in "${EXPECTED_SLICES[@]}"; do
  headers="$STAGE/GhosttyKit.xcframework/$slice/Headers"
  mkdir "$headers/GhosttyKit"
  find "$headers" -maxdepth 1 -type f -exec mv {} "$headers/GhosttyKit/" \;
  [[ -f "$headers/GhosttyKit/module.modulemap" ]] || die "no module map staged for $slice"
done
cp "$SRC/LICENSE" "$STAGE/LICENSE"
echo "$STAMP_CONTENT" >"$STAGE/GHOSTTY_VERSION"

rm -rf "$OUT"
mv "$STAGE" "$OUT"
echo "fetch-ghostty: staged GhosttyKit ($SHORT, $TARGET) at $OUT"
