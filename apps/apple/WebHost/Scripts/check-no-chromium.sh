#!/bin/bash
# Fails the build when Chromium (the web host or any CEF binary) is inside the product. Runs as a
# post-build phase of builds that must stay WebKit-only, such as the Mac App Store edition.
set -euo pipefail

bundle="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
fail() {
  echo "error: $bundle must not contain Chromium, but has $1" >&2
  exit 1
}

# Where the Developer ID edition embeds them. A stat needs no read access, so this holds under
# user script sandboxing, which denies listing the bundle's directories.
for path in "Contents/Helpers/Omnigent Web Host.app" \
  "Contents/Frameworks/Chromium Embedded Framework.framework" \
  "Contents/Frameworks/libcef.dylib"; do
  if [[ -e "$bundle/$path" ]]; then fail "$bundle/$path"; fi
done

# Anywhere else, when the bundle can be listed (outside the sandbox, as the release check runs).
if ls "$bundle/Contents" >/dev/null 2>&1; then
  found="$(find "$bundle" \( -name 'Omnigent Web Host*' -o -name 'Chromium Embedded Framework*' \
    -o -name 'libcef*' \) -print -quit)"
  if [[ -n "$found" ]]; then fail "$found"; fi
fi
