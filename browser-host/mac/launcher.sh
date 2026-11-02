#!/bin/sh
# Runs the host inside its app bundle: CEF finds its framework relative to argv[0].
exec "$(cd "$(dirname "$0")" && pwd)/omnigent-browser-host.app/Contents/MacOS/omnigent-browser-host" "$@"
