#!/bin/bash
# Copies the signed web host bundle into the app's Contents/Helpers. Runs as a post-build phase
# of the app target (see BrowserTargets.swift); Xcode signs the app after all phases, sealing the
# nested host.
# Usage: embed-web-host.sh "<Host product name>"
set -euo pipefail

host_name="$1"
source="${BUILT_PRODUCTS_DIR}/${host_name}.app"
if [[ ! -x "$source/Contents/MacOS/$host_name" ]]; then
  echo "error: $source was not built; the app target must depend on the web host target." >&2
  exit 1
fi
if [[ ! -d "$source/Contents/Frameworks/Chromium Embedded Framework.framework" ]]; then
  echo "error: $source has no Chromium Embedded Framework; its embed step did not run." >&2
  exit 1
fi
dest="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "$dest"
rsync -a --delete "$source/" "$dest/${host_name}.app/"
