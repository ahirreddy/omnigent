#!/bin/bash
# Fails the build unless the pinned CEF is staged for every architecture being built.
# Usage: check-cef.sh <cef-out-dir> <expected-cef-version>
set -euo pipefail

cef_out="$1"
expected="$2"
stamp="$cef_out/CEF_VERSION"

if [[ ! -f "$stamp" ]]; then
  echo "error: CEF is not staged at $cef_out. Run apps/apple/scripts/fetch-cef.sh." >&2
  exit 1
fi
read -r version _ <"$stamp"
if [[ "$version" != "$expected" ]]; then
  echo "error: staged CEF $version does not match pinned $expected. Re-run apps/apple/scripts/fetch-cef.sh." >&2
  exit 1
fi
staged_archs="$(lipo -archs "$cef_out/lib/libcef_dll_wrapper.a")"
for arch in ${ARCHS:-$(uname -m)}; do
  if [[ " $staged_archs " != *" $arch "* ]]; then
    echo "error: staged CEF has [$staged_archs] but the build needs $arch. Run apps/apple/scripts/fetch-cef.sh --arch universal." >&2
    exit 1
  fi
done
