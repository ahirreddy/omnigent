#!/usr/bin/env bash
# The transcript scroll benchmark from scratch, for a Mac with a GUI login session nobody is using
# (a test VM: it launches the app and scrolls it). Builds a Release app, starts the local server,
# mock model and host, seeds the long transcript, then runs `perf.py scroll` for each transcript
# style and prints medians (see apps/apple/docs/performance.md). From the repository root:
#
#   bash apps/apple/Tools/perf/scroll-bench.sh [--runs N] [--styles "chat cli"]
#        [--scenarios a,b] [--scrollers overlay|legacy] [--lists "stack table"] [--sample]
#        [--skip-build]
#
# Scrollers are overlay ones, as on a Mac with a trackpad, unless --scrollers legacy (a mouse's,
# a VM's default). --lists compares transcript lists in one job: each run launches once per list
# (`-omnigent:transcript-list <list>`), and the medians are per list. --sample also samples both
# passes of each scenario once more and prints where the main thread's time went
# (sample-breakdown.py). In the shared test VMs, as one job:
#   ~/src/omnigent-vm/vmq submit --priority high --only laptop-w1 --tree "$PWD" \
#     --label "scroll bench" -- bash apps/apple/Tools/perf/scroll-bench.sh
set -uo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
die() {
  echo "scroll-bench: $*" >&2
  exit 1
}

runs=3 styles="chat cli" scenarios="" sample=0 build=1 scrollers=overlay lists=""
while (($#)); do
  case "$1" in
    --runs) runs=$2; shift 2 ;;
    --styles) styles=$2; shift 2 ;;
    --scenarios) scenarios=$2; shift 2 ;;
    --scrollers) scrollers=$2; shift 2 ;;
    --lists) lists=$2; shift 2 ;;
    --sample) sample=1; shift ;;
    --skip-build) build=0; shift ;;
    *) die "unknown argument $1" ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || die "no repository root"
# The helper scripts import this tree's code, not the shared venv's checkout; output streams.
export PYTHONPATH="$PWD:$PWD/sdks/python-client:$PWD/sdks/ui" PYTHONUNBUFFERED=1
logs="$root/apps/apple/build/PerfRelease/logs"
derived="$root/apps/apple/build/PerfRelease"
app="$derived/Build/Products/Release/Omnigent.app"
mkdir -p "$logs"

if ((build)); then
  core=apps/apple/Packages/OmnigentCoreFFI/omnigent_ffiFFI.xcframework
  # The debug core the Debug builds share: rebuilt only when missing or older than its sources.
  if [[ ! -d "$core" ]] || [[ -n "$(find client-core -name '*.rs' -newer "$core" -print -quit)" ]]; then
    echo "== core"
    bash apps/apple/scripts/build-core.sh debug > "$logs/core.log" 2>&1 \
      || die "core build failed ($logs/core.log)"
  fi
  echo "== generate"
  (cd apps/apple && mise exec -- tuist generate --no-open) > "$logs/generate.log" 2>&1 \
    || die "tuist generate failed ($logs/generate.log)"
  # Its own build folder, with the Debug build's package checkouts copied in (no fetch).
  if [[ ! -d "$derived/SourcePackages" && -d apps/apple/build/DerivedData/SourcePackages ]]; then
    cp -cR apps/apple/build/DerivedData/SourcePackages "$derived/SourcePackages"
  fi
  echo "== build Release"
  started=$(date +%s)
  # As install-local.sh --release: this Mac's architecture, unsigned, then signed ad hoc without
  # hardened runtime, which also lets perf.py inject its monitor and `sample` attach.
  xcodebuild build -workspace apps/apple/Omnigent.xcworkspace -scheme OmnigentMac \
    -configuration Release -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES "ARCHS=$(uname -m)" \
    > "$logs/build.log" 2>&1 \
    || { grep -E "error:" "$logs/build.log" | sort -u | head -20; die "build failed ($logs/build.log)"; }
  bash apps/apple/scripts/release/sign-mac-developer-id.sh --app "$app" --identity - \
    --app-entitlements apps/apple/Apps/Omnigent-macOS/OmnigentMac-Debug.entitlements \
    --no-hardened-runtime > "$logs/sign.log" 2>&1 || die "signing failed ($logs/sign.log)"
  echo "built in $(($(date +%s) - started))s: $app"
fi
[[ -x "$app/Contents/MacOS/Omnigent" ]] || die "no Release app at $app"

# The services, as the flow worker starts them: a previous run's run older code.
service() {
  local name=$1
  shift
  pgrep -f "$2" > /dev/null && return 0
  ("$@" > "$logs/$name.log" 2>&1 < /dev/null &)
}
pkill -f "omnigent server --host 127.0.0.1 --port 6767"
pkill -f "omnigent host --server http://127.0.0.1:6767"
pkill -f "Omnigent.app/Contents/MacOS/Omnigent"
for _ in $(seq 1 20); do
  pgrep -f "Omnigent.app/Contents/MacOS/Omnigent|omnigent (server --host 127.0.0.1 --port 6767|host --server http://127.0.0.1:6767)" \
    > /dev/null || break
  sleep 0.5
done
echo "== services"
service server bash apps/apple/Tools/local-server.sh
service mock .venv/bin/python apps/apple/Tools/mock-model.py serve
.venv/bin/python apps/apple/Tools/local-services.py wait-api --timeout 120 > /dev/null \
  || die "the server did not start ($logs/server.log)"
.venv/bin/python apps/apple/Tools/mock-model.py install-agent > /dev/null || die "mock agent install failed"
service host bash apps/apple/Tools/local-host.sh
for _ in $(seq 1 60); do
  curl -fsS http://127.0.0.1:6767/v1/hosts | grep -q '"online"' && break
  sleep 2
done
.venv/bin/python apps/apple/Tools/seed-large-fixtures.py --sessions 30 --long 1 --long-turns 300 \
  > "$logs/seed-large.log" 2>&1 || die "seeding failed ($logs/seed-large.log)"

status=0
for style in $styles; do
  echo "== scroll, $style style"
  options=(--app "$app" --fresh-state --scrollers "$scrollers" --style "$style" --runs "$runs")
  [[ -n "$scenarios" ]] && options+=(--scenarios "$scenarios")
  [[ -n "$lists" ]] && options+=(--lists "${lists// /,}")
  ((sample)) && options+=(--sample 1)
  .venv/bin/python apps/apple/Tools/perf/perf.py scroll "${options[@]}" || status=1
  # What the last run left built: the AppKit views in the transcript, by class.
  .venv/bin/python apps/apple/Tools/perf/perf.py drive --app "$app" count-views || status=1
  if ((sample)); then
    for report in "${TMPDIR:-/tmp}"/omnigent-perf/*sampled*.sample.txt; do
      [[ -e "$report" ]] || continue
      kept="$logs/$style-$(basename "$report")"
      mv "$report" "$kept"
      echo "-- $kept"
      .venv/bin/python apps/apple/Tools/perf/sample-breakdown.py "$kept" || status=1
    done
  fi
done

# No app outlives the run, and LaunchServices keeps only the copies it had.
pkill -f "$app/Contents/MacOS/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$(cd "$app" && pwd -P)" 2> /dev/null
exit $status
