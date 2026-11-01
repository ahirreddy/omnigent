#!/bin/bash
# Copies Chromium Embedded Framework and the helper apps into the app's Contents/Frameworks and
# signs the framework. Runs as a post-build phase of the app target (see BrowserTargets.swift).
# Usage: embed-cef.sh <cef-out-dir> <expected-cef-version> "<App> Helper"
# CEF derives the variant names from the base helper name, so the suffixes are fixed.
set -euo pipefail

cef_out="$1"
expected="$2"
helper_base="$3"

"$(dirname "$0")/check-cef.sh" "$cef_out" "$expected"

dest="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
framework="Chromium Embedded Framework.framework"
mkdir -p "$dest"
rsync -a --delete "$cef_out/$framework/" "$dest/$framework/"

for suffix in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
  helper="$helper_base$suffix"
  source="${BUILT_PRODUCTS_DIR}/$helper.app"
  if [[ ! -x "$source/Contents/MacOS/$helper" ]]; then
    echo "error: helper $source was not built; the app target must depend on the helper targets." >&2
    exit 1
  fi
  rsync -a --delete "$source/" "$dest/$helper.app/"
done

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" ]]; then
  exit 0
fi
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="-"
fi
flags=(--force --sign "$identity" --options runtime)
if [[ "${CONFIGURATION:-Debug}" == "Release" && "$identity" != "-" ]]; then
  flags+=(--timestamp)
else
  flags+=(--timestamp=none)
fi
for library in "$dest/$framework/Libraries/"*.dylib; do
  codesign "${flags[@]}" "$library"
done
codesign "${flags[@]}" "$dest/$framework"
