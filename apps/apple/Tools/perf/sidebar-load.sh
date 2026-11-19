#!/usr/bin/env bash
# Times how the Mac app's sidebar loads from a server one round trip away. Run it in a test VM,
# never on a Mac in use: it builds the app as the UI flows do, starts a second API server with its
# own data on 6790 (the shared one on 6767 is left alone), seeds it with several hundred sessions
# in projects, pinned, archived, in families and shared, puts latency-proxy.py on 6791 in front of
# it, then launches the app on the proxy a few times and prints each launch's requests and the
# app's sidebar signposts from the launch, with when the first rows and the whole list showed.
# The first launch has no saved list; the last one also loses the network for three seconds.
#   sidebar-load.sh [--rtt-ms 150] [--seconds 20] [--runs 2] [--no-build] [--sample] [--release]
# --sample also samples each launch's first four seconds and breaks the main thread's time down.
# --release times the optimized app (install-local.sh --release) instead of the Debug one.
set -euo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/../../../.."
# The app's processes carry the physical path (a VM's ~/w links elsewhere).
repo=$(pwd -P)
rtt=150 seconds=20 runs=2 build=1 sample=0 release=0
while (($#)); do
  case "$1" in
    --rtt-ms) rtt=$2; shift 2 ;;
    --seconds) seconds=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --no-build) build=0; shift ;;
    --sample) sample=1; shift ;;
    --release) release=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
derived=apps/apple/build/DerivedData configuration=Debug
# Release as install-local.sh --release builds it: optimized, with the release core.
((release)) && derived=apps/apple/build/ReleaseData configuration=Release
app="$repo/$derived/Build/Products/$configuration/Omnigent.app"
runtime="${TMPDIR:-/tmp}/omnigent-sidebar-load"
api=6790 proxy=6791

if ((build)); then
  MISE_OFFLINE=1 bash apps/apple/scripts/fetch-ghostty.sh > "$runtime-ghostty.log" 2>&1 \
    || { echo "Ghostty build failed ($runtime-ghostty.log)" >&2; exit 1; }
  core_profile=debug
  ((release)) && core_profile=release
  bash apps/apple/scripts/build-core.sh "$core_profile" --sim-only > "$runtime-core.log" 2>&1 \
    || { tail -20 "$runtime-core.log"; exit 1; }
  if [[ -x ~/seed-derived-data.sh ]]; then ~/seed-derived-data.sh "$PWD"; fi
  (cd apps/apple && mise exec -- tuist generate --no-open) > "$runtime-generate.log" 2>&1 \
    || { tail -20 "$runtime-generate.log"; exit 1; }
  if ((release)); then
    xcodebuild build -workspace apps/apple/Omnigent.xcworkspace -scheme OmnigentMac \
      -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
      -derivedDataPath "$derived" \
      -clonedSourcePackagesDirPath apps/apple/build/DerivedData/SourcePackages \
      CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
      "ARCHS=$(uname -m)" > "$runtime-build.log" 2>&1 \
      || { grep -E "error:" "$runtime-build.log" | sort -u | head -20; exit 1; }
    codesign --force --deep --sign - "$app" > /dev/null 2>&1
  else
    xcodebuild build-for-testing -workspace apps/apple/Omnigent.xcworkspace -scheme OmnigentMac \
      -destination platform=macOS -derivedDataPath "$derived" > "$runtime-build.log" 2>&1 \
      || { grep -E "error:" "$runtime-build.log" | sort -u | head -20; exit 1; }
  fi
fi
[[ -d "$app" ]] || { echo "no app at $app" >&2; exit 1; }

pids=()
cleanup() {
  pkill -f "$app/Contents/MacOS/Omnigent" || true
  for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null || true; done
}
trap cleanup EXIT

rm -rf "$runtime"
mkdir -p "$runtime/config" "$runtime/data" "$runtime/artifacts"
(
  cd "$runtime"
  exec env -i HOME="$HOME" PATH="$repo/.venv/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    PYTHONPATH="$repo:$repo/sdks/python-client:$repo/sdks/ui" PYTHONUNBUFFERED=1 \
    OMNIGENT_CONFIG_HOME="$runtime/config" OMNIGENT_DATA_DIR="$runtime/data" \
    OMNIGENT_LOCAL_SINGLE_USER=1 OMNIGENT_SKIP_WEB_UI=true OMNIGENT_NO_UPDATE_CHECK=1 \
    DO_NOT_TRACK=1 OMNIGENT_APNS_ENABLED=0 \
    "$repo/.venv/bin/omnigent" server --host 127.0.0.1 --port "$api" \
    --database-uri "sqlite:///$runtime/data/chat.db" --artifact-location "$runtime/artifacts" \
    --no-open
) > "$runtime/server.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 120); do
  curl -fsS "http://127.0.0.1:$api/v1/info" > /dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$api/v1/info" > /dev/null || { tail -20 "$runtime/server.log"; exit 1; }
export PYTHONPATH="$repo:$repo/sdks/python-client:$repo/sdks/ui"
.venv/bin/python apps/apple/Tools/mock-model.py install-agent --api "http://127.0.0.1:$api" > /dev/null
.venv/bin/python apps/apple/Tools/seed-large-fixtures.py --runtime "$runtime" \
  --server "http://127.0.0.1:$api" --sessions 400 --long 0 --pinned 12 --archived 160 \
  --families 15 --shared 40
# Three folders open, as a user who keeps their current projects expanded.
# A quoted property-list string, which the launch argument is read as.
expanded=$(curl -fsS "http://127.0.0.1:$api/v1/projects" | python3 -c 'import json, sys
ids = [project["id"] for project in json.load(sys.stdin)["data"][:3]]
print(chr(34) + "\\n".join(ids) + chr(34))')

# What a first page carries with and without archived sessions, read straight from the server.
python3 - "http://127.0.0.1:$api" << 'EOF'
import json, sys, time, urllib.request
base = sys.argv[1] + "/v1/sessions?limit=50&sort_by=updated_at&expand_families=true&visibility=all"
for label, query in (("with archived", base + "&include_archived=true"), ("without", base)):
    began = time.monotonic()
    body = urllib.request.urlopen(query, timeout=30).read()
    rows = json.loads(body)["data"]
    shown = sum(not row.get("archived") for row in rows)
    print(f"first page {label}: {len(rows)} rows, {shown} unarchived, {len(body)} bytes, "
          f"{(time.monotonic() - began) * 1000:.0f} ms")
EOF

pkill -f "Omnigent.app/Contents/MacOS/Omnigent" || true
# The first launch starts without a saved list; the later ones have the one it saved.
bundle=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$app/Contents/Info.plist")
rm -rf "$HOME/Library/Caches/$bundle/MessageCache"

start_proxy() { # log, out
  python3 apps/apple/Tools/perf/latency-proxy.py serve --listen "$proxy" --upstream "$api" \
    --rtt-ms "$rtt" --log "$1" > "$2" 2>&1 &
  proxy_pid=$!
  sleep 1
}

report() { # title, log, launched epoch, signposts
  echo "== $1, $rtt ms round trip"
  if [[ -s "$2" ]]; then
    python3 apps/apple/Tools/perf/latency-proxy.py report "$2" --launched "$3" --signposts "$4"
  else
    echo "no requests reached the proxy"
  fi
}

for run in $(seq 1 "$runs"); do
  log="$runtime/proxy-$run.jsonl" signposts="$runtime/signposts-$run.ndjson"
  start_proxy "$log" "$runtime/proxy-$run.out"
  # The app's sidebar signposts, streamed live (unrecorded signposts are not kept).
  /usr/bin/log stream --signpost --style ndjson \
    --predicate 'subsystem == "ai.omnigent.performance" AND category == "sidebar"' \
    > "$signposts" 2> "$runtime/signposts-$run.err" &
  stream_pid=$!
  sleep 1
  launched=$(python3 -c 'import time; print(time.time())')
  open -n "$app" --args -desktop.defaultServerURL "http://127.0.0.1:$proxy" \
    -OmnigentTabsDirectory "$runtime/tabs-$run" -ApplePersistenceIgnoreState YES \
    -OmnigentNoNotificationPrompt YES -omnigent:default-workspace-panel collapsed \
    -omnigent:sidebar-view "<7b7d>" -omnigent:sidebar-expanded-projects "$expanded" \
    -desktop.localServer.cliPath /var/empty/no-cli -desktop.localServer.dataDirectory /var/empty/no-data
  if ((sample)); then
    # The main thread's stacks through the load; sampling pauses the app, so times stretch.
    for _ in $(seq 1 50); do
      pid=$(pgrep -f "$app/Contents/MacOS/Omnigent" | head -1 || true)
      [[ -n "$pid" ]] && break
      sleep 0.05
    done
    sample "$pid" 4 1 -mayDie -file "$runtime/sample-$run.txt" > /dev/null 2>&1 &
  fi
  sleep "$seconds"
  if ((run == runs)); then
    # A dropped network on the last launch: the proxy goes for three seconds, then comes back.
    kill "$proxy_pid" 2> /dev/null || true
    sleep 3
    back_log="$runtime/proxy-$run-back.jsonl"
    start_proxy "$back_log" "$runtime/proxy-$run-back.out"
    back=$(python3 -c 'import time; print(time.time() - 1)')
    sleep "$seconds"
  fi
  pkill -f "$app/Contents/MacOS/Omnigent" || true
  sleep 1
  kill "$proxy_pid" "$stream_pid" 2> /dev/null || true
  report "launch $run" "$log" "$launched" "$signposts"
  if ((sample)) && [[ -s "$runtime/sample-$run.txt" ]]; then
    # A test VM's shared results folder, where the host can read the whole call tree.
    shared="/Volumes/My Shared Files/results"
    if [[ -d "$shared" ]]; then cp "$runtime/sample-$run.txt" "$shared/sidebar-load-sample-$run.txt"; fi
    python3 apps/apple/Tools/perf/sample-breakdown.py "$runtime/sample-$run.txt" --top 40 \
      --frames 'SidebarView|SidebarAdapter|SessionListStore|ConnectionStore|SessionIndex|ProjectFolder|SessionRow'
  fi
  if ((run == runs)); then
    report "launch $run, the network back after three seconds" "$back_log" "$back" "$signposts"
  fi
done
