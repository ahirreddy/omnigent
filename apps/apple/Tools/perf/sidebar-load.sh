#!/usr/bin/env bash
# Times how the Mac app's sidebar loads from a server one round trip away. Run it in a test VM,
# never on a Mac in use: it builds the app as the UI flows do, starts a second API server with its
# own data on 6790 (the shared one on 6767 is left alone), seeds it with several hundred sessions
# in projects, pinned, archived, in families and shared, puts latency-proxy.py on 6791 in front of
# it, then launches the app on the proxy a few times and prints each launch's requests from the
# first, with times.
#   sidebar-load.sh [--rtt-ms 150] [--seconds 20] [--runs 2] [--no-build]
set -euo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/../../../.."
# The app's processes carry the physical path (a VM's ~/w links elsewhere).
repo=$(pwd -P)
rtt=150 seconds=20 runs=2 build=1
while (($#)); do
  case "$1" in
    --rtt-ms) rtt=$2; shift 2 ;;
    --seconds) seconds=$2; shift 2 ;;
    --runs) runs=$2; shift 2 ;;
    --no-build) build=0; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
derived=apps/apple/build/DerivedData
app="$repo/$derived/Build/Products/Debug/Omnigent.app"
runtime="${TMPDIR:-/tmp}/omnigent-sidebar-load"
api=6790 proxy=6791

if ((build)); then
  MISE_OFFLINE=1 bash apps/apple/scripts/fetch-ghostty.sh > "$runtime-ghostty.log" 2>&1 \
    || { echo "Ghostty build failed ($runtime-ghostty.log)" >&2; exit 1; }
  bash apps/apple/scripts/build-core.sh debug > "$runtime-core.log" 2>&1 \
    || { tail -20 "$runtime-core.log"; exit 1; }
  if [[ -x ~/seed-derived-data.sh ]]; then ~/seed-derived-data.sh "$PWD"; fi
  (cd apps/apple && mise exec -- tuist generate --no-open) > "$runtime-generate.log" 2>&1 \
    || { tail -20 "$runtime-generate.log"; exit 1; }
  xcodebuild build-for-testing -workspace apps/apple/Omnigent.xcworkspace -scheme OmnigentMac \
    -destination platform=macOS -derivedDataPath "$derived" > "$runtime-build.log" 2>&1 \
    || { grep -E "error:" "$runtime-build.log" | sort -u | head -20; exit 1; }
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
for run in $(seq 1 "$runs"); do
  log="$runtime/proxy-$run.jsonl"
  python3 apps/apple/Tools/perf/latency-proxy.py serve --listen "$proxy" --upstream "$api" \
    --rtt-ms "$rtt" --log "$log" > "$runtime/proxy-$run.out" 2>&1 &
  proxy_pid=$!
  sleep 1
  open -n "$app" --args -desktop.defaultServerURL "http://127.0.0.1:$proxy" \
    -OmnigentTabsDirectory "$runtime/tabs-$run" -ApplePersistenceIgnoreState YES \
    -OmnigentNoNotificationPrompt YES -omnigent:default-workspace-panel collapsed \
    -omnigent:sidebar-view "<7b7d>" -omnigent:sidebar-expanded-projects "$expanded" \
    -desktop.localServer.cliPath /var/empty/no-cli -desktop.localServer.dataDirectory /var/empty/no-data
  sleep "$seconds"
  pkill -f "$app/Contents/MacOS/Omnigent" || true
  sleep 1
  kill "$proxy_pid" 2> /dev/null || true
  echo "== launch $run, $rtt ms round trip"
  if [[ -s "$log" ]]; then
    python3 apps/apple/Tools/perf/latency-proxy.py report "$log"
  else
    echo "no requests reached the proxy"; cat "$runtime/proxy-$run.out"
  fi
done
