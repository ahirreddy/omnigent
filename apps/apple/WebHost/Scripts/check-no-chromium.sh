#!/bin/bash
# Fails the build when Chromium (the web host or any CEF binary) is inside the product. Runs as a
# post-build phase of builds that must stay WebKit-only, such as the Mac App Store edition.
set -euo pipefail

bundle="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
found="$(find "$bundle" \( -name 'Omnigent Web Host*' -o -name 'Chromium Embedded Framework*' \
  -o -name 'libcef*' \) -print -quit)"
if [[ -n "$found" ]]; then
  echo "error: $bundle must not contain Chromium, but has $found" >&2
  exit 1
fi
