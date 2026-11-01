#!/usr/bin/env bash
# Localize libghostty's `memset` (src/quirks_memset.zig, exported hidden from libghostty_zcu.o)
# in every slice of a GhosttyKit.xcframework, so code linked into the same image as libghostty
# (Swift, the Rust core) binds `memset` to libSystem again.
#
# Why: quirks_memset declares `fn memset(dest, c: u8, len)`, but the C prototype is `int c`.
# C/Rust callers may pass a sign-extended int (LLVM lowers `write_bytes(p, 0xFF, n)` to
# `mov w1, #-1; bl _memset`). The Zig body does not truncate `c` to a byte, so 0xFFFFFFFF
# splats to FF FE FE FE ... and hashbrown tables get corrupt control bytes.
#
# usage: localize-ghostty-memset.sh <GhosttyKit.xcframework>
set -euo pipefail

die() { echo "localize-ghostty-memset: error: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <GhosttyKit.xcframework>"
xcframework="$1"
[[ -d "$xcframework" ]] || die "no xcframework at $xcframework"

# Rewrites libghostty_zcu.o in one thin archive, localizing `_memset` only.
localize_thin() {
  local archive="$1" work="$2"
  rm -rf "$work"
  mkdir -p "$work"
  (
    cd "$work"
    xcrun ar x "$archive" libghostty_zcu.o || die "$archive has no libghostty_zcu.o"
    chmod 644 libghostty_zcu.o
    xcrun nm -g -m libghostty_zcu.o | grep -q ' _memset$' \
      || die "libghostty_zcu.o in $archive does not define _memset (quirk removed upstream?)"
    # nmedit -s keeps the listed globals and localizes every other one.
    xcrun nm -g libghostty_zcu.o | awk '$2 ~ /^[A-TV-Z]$/ {print $3}' | grep -vx '_memset' \
      | sort -u >keep.txt
    xcrun nmedit -s keep.txt libghostty_zcu.o
    if xcrun nm -g libghostty_zcu.o | awk '$2 ~ /^[A-TV-Z]$/ {print $3}' | grep -qx '_memset'; then
      die "_memset is still global in $archive"
    fi
    xcrun ar r "$archive" libghostty_zcu.o 2>/dev/null
    xcrun ranlib "$archive"
  )
}

found=0
while IFS= read -r -d '' archive; do
  found=1
  work="$(mktemp -d)"
  archs="$(xcrun lipo -archs "$archive")"
  if [[ "$archs" == *" "* ]]; then
    thins=()
    for arch in $archs; do
      xcrun lipo "$archive" -thin "$arch" -output "$work/$arch.a"
      localize_thin "$work/$arch.a" "$work/$arch"
      thins+=("$work/$arch.a")
    done
    xcrun lipo -create "${thins[@]}" -output "$archive"
  else
    localize_thin "$archive" "$work/thin"
  fi
  rm -rf "$work"
  echo "localize-ghostty-memset: localized _memset in $archive ($archs)"
done < <(find "$xcframework" -name '*.a' -print0)
[[ $found -eq 1 ]] || die "no static archives under $xcframework"
