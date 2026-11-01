#!/usr/bin/env bash
# Fetch the pinned CEF (Chromium Embedded Framework) binary distribution for macOS,
# verify it against pinned SHA-256 and SHA-1 checksums, build libcef_dll_wrapper, and
# stage a stable consumable layout under apps/apple/Vendor/cef/out.
#
# Usage: fetch-cef.sh [--arch arm64|x86_64|universal] [--source spotify|omnigent] [--force]
#   default arch is the host architecture.
#   --source spotify (default): the stock build from CEF's automated builder.
#   --source omnigent: Omnigent's own CEF build (CI, GitHub Releases), pinned in
#     scripts/engine/omnigent-cef.lock. See docs/browser-engine-decision.md. The source can
#     also be set with OMNIGENT_CEF_SOURCE.
#
# Output layout (consumed by OmnigentBrowser/Package.swift and BrowserTargets.swift):
#   Vendor/cef/out/include/...                          CEF headers (include "include/cef_app.h")
#   Vendor/cef/out/lib/libcef_dll_wrapper.a             C++ wrapper (static, per-arch or universal)
#   Vendor/cef/out/Chromium Embedded Framework.framework  (restaged in versioned layout)
#   Vendor/cef/out/CEF_VERSION                          pinned version + arch, written last
#
# Idempotent: a matching CEF_VERSION stamp short-circuits; downloads are cached and re-verified.
set -euo pipefail

CEF_VERSION="156.0.15+gcf671c0+chromium-156.0.8078.80"
CEF_DIST="minimal"
CEF_CDN="https://cef-builds.spotifycdn.com"

# Pinned from https://cef-builds.spotifycdn.com/index.json (stable channel) and the
# published <archive>.sha256 files.
sha256_for() {
  case "$1" in
    macosarm64) echo "a27f1d856e84047657ed2a14caf355fb04480c4fe1963f04249a8a3184af1c30" ;;
    macosx64) echo "e2aedb3cb41cc293ff2db81245f3462c61c49e13ac137f628872889c8a36c702" ;;
    *) echo "fetch-cef: no pinned sha256 for platform '$1'" >&2; return 1 ;;
  esac
}
sha1_for() {
  case "$1" in
    macosarm64) echo "bcdd1877edb300b0fb91d8f71c0b14aae256cd0f" ;;
    macosx64) echo "13756e3029307720fe00898d54aef8a64c9b4043" ;;
    *) echo "fetch-cef: no pinned sha1 for platform '$1'" >&2; return 1 ;;
  esac
}

die() { echo "fetch-cef: error: $*" >&2; exit 1; }

ARCH=""
FORCE=0
SOURCE="${OMNIGENT_CEF_SOURCE:-spotify}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

# Archive name on the server for a platform; the extracted directory keeps CEF's own name.
archive_name() { echo "cef_binary_${CEF_VERSION}_${1}_${CEF_DIST}.tar.bz2"; }
# Keeps Omnigent builds apart from stock ones, which extract to the same directory name.
SOURCE_TAG=""
case "$SOURCE" in
  spotify) ;;
  omnigent)
    lock="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/engine/omnigent-cef.lock"
    [[ -f "$lock" ]] || die "missing $lock"
    # shellcheck source=engine/omnigent-cef.lock
    source "$lock"
    [[ -n "${OMNIGENT_CEF_VERSION:-}" && -n "${OMNIGENT_CEF_RELEASE_URL:-}" ]] \
      || die "no Omnigent CEF build is pinned in $lock yet; use --source spotify"
    CEF_VERSION="$OMNIGENT_CEF_VERSION"
    SOURCE_TAG="omnigent-${OMNIGENT_CEF_BUILD:?OMNIGENT_CEF_BUILD is not set in $lock}"
    CEF_CDN="$OMNIGENT_CEF_RELEASE_URL"
    # GitHub Releases rewrites '+' in asset names, so Omnigent assets use their own names.
    archive_name() { echo "omnigent-cef-${OMNIGENT_CEF_BUILD}-${1}-${CEF_DIST}.tar.bz2"; }
    sha256_for() {
      local value
      case "$1" in
        macosarm64) value="${OMNIGENT_CEF_SHA256_MACOSARM64:-}" ;;
        macosx64) value="${OMNIGENT_CEF_SHA256_MACOSX64:-}" ;;
      esac
      [[ -n "$value" ]] || { echo "fetch-cef: no pinned sha256 for platform '$1' in $lock" >&2; return 1; }
      echo "$value"
    }
    # Omnigent builds pin SHA-256 only; the release workflow publishes no SHA-1.
    sha1_for() { echo "-"; }
    ;;
  *) die "unknown --source '$SOURCE' (expected spotify or omnigent)" ;;
esac
if [[ -z "$ARCH" ]]; then
  ARCH="$(uname -m)"
fi
case "$ARCH" in
  arm64) PLATFORMS=(macosarm64) ;;
  x86_64) PLATFORMS=(macosx64) ;;
  universal) PLATFORMS=(macosarm64 macosx64) ;;
  *) die "unsupported --arch '$ARCH' (expected arm64, x86_64 or universal)" ;;
esac

for tool in curl shasum tar cmake lipo; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found on PATH"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$(cd "$SCRIPT_DIR/.." && pwd)/Vendor/cef"
DOWNLOADS="$VENDOR/downloads"
DIST_ROOT="$VENDOR/dist${SOURCE_TAG:+-$SOURCE_TAG}"
OUT="$VENDOR/out"
STAMP_CONTENT="$CEF_VERSION $CEF_DIST $ARCH versioned-framework${SOURCE_TAG:+ $SOURCE_TAG}"
FRAMEWORK_NAME="Chromium Embedded Framework.framework"

if [[ $FORCE -eq 0 && -f "$OUT/CEF_VERSION" && "$(cat "$OUT/CEF_VERSION")" == "$STAMP_CONTENT" ]]; then
  echo "fetch-cef: CEF $CEF_VERSION ($ARCH) already staged at $OUT"
  exit 0
fi

mkdir -p "$DOWNLOADS" "$DIST_ROOT"

verify() {
  local file="$1" platform="$2" actual expected
  expected="$(sha256_for "$platform")"
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "fetch-cef: SHA-256 mismatch for $file: expected $expected, got $actual" >&2
    return 1
  }
  expected="$(sha1_for "$platform")"
  [[ "$expected" == "-" ]] && return 0
  actual="$(shasum -a 1 "$file" | awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || {
    echo "fetch-cef: SHA-1 mismatch for $file: expected $expected, got $actual" >&2
    return 1
  }
}

fetch_platform() {
  local platform="$1"
  local base="cef_binary_${CEF_VERSION}_${platform}_${CEF_DIST}"
  local name
  name="$(archive_name "$platform")"
  local archive="$DOWNLOADS/$name"
  local encoded="${name//+/%2B}"

  if [[ -f "$archive" ]] && ! verify "$archive" "$platform"; then
    echo "fetch-cef: cached archive failed verification; re-downloading" >&2
    rm -f "$archive"
  fi
  if [[ ! -f "$archive" ]]; then
    echo "fetch-cef: downloading $CEF_CDN/$encoded"
    curl --fail --location --show-error --retry 3 --output "$archive.partial" "$CEF_CDN/$encoded"
    mv "$archive.partial" "$archive"
    verify "$archive" "$platform" || { rm -f "$archive"; die "downloaded archive failed checksum verification"; }
  fi
  echo "fetch-cef: verified $name (sha256 $(sha256_for "$platform"))"

  local dist="$DIST_ROOT/$base"
  if [[ ! -f "$dist/.extracted" ]]; then
    rm -rf "$dist"
    tar -xjf "$archive" -C "$DIST_ROOT"
    [[ -d "$dist/include" ]] || die "archive did not contain $base/include"
    touch "$dist/.extracted"
  fi

  local project_arch
  case "$platform" in
    macosarm64) project_arch=arm64 ;;
    macosx64) project_arch=x86_64 ;;
  esac
  local build="$dist/build-wrapper"
  if [[ ! -f "$build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
    echo "fetch-cef: building libcef_dll_wrapper ($project_arch)"
    cmake -S "$dist" -B "$build" -G "Unix Makefiles" \
      -DPROJECT_ARCH="$project_arch" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
      >"$build.cmake.log" 2>&1 || { cat "$build.cmake.log" >&2; die "cmake configure failed"; }
    cmake --build "$build" --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)" \
      >"$build.build.log" 2>&1 || { tail -50 "$build.build.log" >&2; die "libcef_dll_wrapper build failed"; }
  fi
  FETCHED_DIST="$dist"
}

DISTS=()
for platform in "${PLATFORMS[@]}"; do
  FETCHED_DIST=""
  fetch_platform "$platform"
  DISTS+=("$FETCHED_DIST")
done

STAGE="$VENDOR/out.staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib"
cp -R "${DISTS[0]}/include" "$STAGE/include"
cp -R "${DISTS[0]}/Release/$FRAMEWORK_NAME" "$STAGE/$FRAMEWORK_NAME"

if [[ ${#DISTS[@]} -eq 1 ]]; then
  cp "${DISTS[0]}/build-wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a" "$STAGE/lib/"
else
  lipo -create \
    "${DISTS[0]}/build-wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a" \
    "${DISTS[1]}/build-wrapper/libcef_dll_wrapper/libcef_dll_wrapper.a" \
    -output "$STAGE/lib/libcef_dll_wrapper.a"
  # Merge every Mach-O inside the framework into a fat binary.
  while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    other="${DISTS[1]}/Release/$FRAMEWORK_NAME/$rel"
    [[ -f "$other" ]] || die "x86_64 framework is missing $rel"
    lipo -create "$STAGE/$FRAMEWORK_NAME/$rel" "$other" -output "$STAGE/$FRAMEWORK_NAME/$rel.fat"
    mv "$STAGE/$FRAMEWORK_NAME/$rel.fat" "$STAGE/$FRAMEWORK_NAME/$rel"
  done < <(cd "$STAGE/$FRAMEWORK_NAME" && find . -type f -print0 | while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then printf '%s\0' "$f"; fi
  done)
fi

# CEF ships a flat framework; Xcode's product validation and codesign expect the versioned
# macOS layout (Versions/A plus top-level symlinks), which CEF also loads correctly.
fw="$STAGE/$FRAMEWORK_NAME"
mkdir -p "$fw/Versions/A"
for item in "Chromium Embedded Framework" Libraries Resources; do
  [[ -e "$fw/$item" ]] || die "framework is missing $item"
  mv "$fw/$item" "$fw/Versions/A/$item"
done
ln -s A "$fw/Versions/Current"
for item in "Chromium Embedded Framework" Libraries Resources; do
  ln -s "Versions/Current/$item" "$fw/$item"
done

for file in "${DISTS[0]}/LICENSE.txt" "${DISTS[0]}/README.txt"; do
  [[ -f "$file" ]] && cp "$file" "$STAGE/"
done
echo "$STAMP_CONTENT" >"$STAGE/CEF_VERSION"

rm -rf "$OUT"
mv "$STAGE" "$OUT"
echo "fetch-cef: staged CEF $CEF_VERSION ($ARCH) at $OUT"
