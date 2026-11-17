#!/usr/bin/env bash
# The iPhone and iPad transcript benchmark from scratch, for a test VM with Xcode's simulators:
# builds the Debug app for the simulator (its frame monitor and perf driver are Debug-only),
# starts the local server, mock model and host, seeds the long transcripts, then runs
# ios_perf.py's scenarios on each simulator, once per transcript list in each run, and prints
# medians (see apps/apple/docs/performance.md). From the repository root:
#
#   bash apps/apple/Tools/perf/ios-scroll-bench.sh [--runs N] [--lists "stack table text"]
#        [--devices "iPhone 18 Pro;iPad Pro 11-inch (M5)"] [--scenarios "open scroll stream"]
#        [--style chat|cli] [--sample] [--skip-build]
#
# The lists are ios_perf.py's: `text` is the table with settled messages drawn as text rows.
# Each device also runs a width change: the iPhone turns, the iPad hides and shows its sidebar.
# --sample samples the main thread during each scenario; a run that fails prints the app's
# newest crash report.
#
# Package checkouts come from the Debug workspace build's (vmq seeds them), so nothing is
# fetched. In the shared test VMs, as one job:
#   ~/src/omnigent-vm/vmq submit --priority high --tree "$PWD" --label "iOS scroll bench" -- \
#     bash apps/apple/Tools/perf/ios-scroll-bench.sh
set -uo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
die() {
  echo "ios-scroll-bench: $*" >&2
  exit 1
}

runs=3 lists="stack table" style=chat build=1 sample=0
devices="iPhone 18 Pro;iPad Pro 11-inch (M5)"
scenarios="open scroll stream keyboard"
while (($#)); do
  case "$1" in
    --runs) runs=$2; shift 2 ;;
    --lists) lists=$2; shift 2 ;;
    --devices) devices=$2; shift 2 ;;
    --scenarios) scenarios=$2; shift 2 ;;
    --style) style=$2; shift 2 ;;
    --sample) sample=1; shift ;;
    --skip-build) build=0; shift ;;
    *) die "unknown argument $1" ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || die "no repository root"
export PYTHONPATH="$PWD:$PWD/sdks/python-client:$PWD/sdks/ui" PYTHONUNBUFFERED=1
derived="$root/apps/apple/build/IOSPerf"
logs="$derived/logs"
app="$derived/Build/Products/Debug-iphonesimulator/Omnigent.app"
mkdir -p "$logs"

if ((build)); then
  core=apps/apple/Packages/OmnigentCoreFFI/omnigent_ffiFFI.xcframework
  if [[ ! -d "$core" ]] || [[ -n "$(find client-core -name '*.rs' -newer "$core" -print -quit)" ]]; then
    echo "== core"
    bash apps/apple/scripts/build-core.sh debug > "$logs/core.log" 2>&1 \
      || die "core build failed ($logs/core.log)"
  fi
  echo "== generate"
  (cd apps/apple && mise exec -- tuist generate --no-open) > "$logs/generate.log" 2>&1 \
    || die "tuist generate failed ($logs/generate.log)"
  # Its own build folder, with the Debug build's package checkouts copied in.
  if [[ ! -d "$derived/SourcePackages/checkouts" ]]; then
    seed=apps/apple/build/DerivedData/SourcePackages
    [[ -d "$seed/checkouts" ]] || die "no package checkouts at $seed to copy"
    rm -rf "$derived/SourcePackages"
    cp -cR "$seed" "$derived/SourcePackages" || die "could not copy $seed"
  fi
  echo "== build Debug for the simulator"
  started=$(date +%s)
  xcodebuild build -workspace apps/apple/Omnigent.xcworkspace -scheme Omnigent \
    -configuration Debug -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived" -clonedSourcePackagesDirPath "$derived/SourcePackages" \
    -disableAutomaticPackageResolution -skipPackageUpdates -skipPackagePluginValidation \
    -skipMacroValidation > "$logs/build.log" 2>&1 \
    || { grep -E "error:" "$logs/build.log" | sort -u | head -20; die "build failed ($logs/build.log)"; }
  echo "built in $(($(date +%s) - started))s: $app"
fi
[[ -d "$app" ]] || die "no simulator app at $app"

service() {
  local name=$1
  shift
  pgrep -f "$2" > /dev/null && return 0
  ("$@" > "$logs/$name.log" 2>&1 < /dev/null &)
}
pkill -f "omnigent server --host 127.0.0.1 --port 6767"
pkill -f "omnigent host --server http://127.0.0.1:6767"
for _ in $(seq 1 20); do
  pgrep -f "omnigent (server --host 127.0.0.1 --port 6767|host --server http://127.0.0.1:6767)" \
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
# ios_perf.py opens long transcripts 1 to 3 (iPad's second one is 3).
.venv/bin/python apps/apple/Tools/seed-large-fixtures.py --sessions 30 --long 4 --long-turns 300 \
  > "$logs/seed-large.log" 2>&1 || die "seeding failed ($logs/seed-large.log)"

status=0
IFS=';' read -r -a names <<< "$devices"
for name in "${names[@]}"; do
  udid=$(xcrun simctl list devices available | grep -F "    $name (" | head -1 \
    | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  [[ -n "$udid" ]] || { echo "ios-scroll-bench: no simulator named $name" >&2; status=1; continue; }
  echo "== $name ($udid), $style style"
  xcrun simctl boot "$udid" 2> /dev/null
  xcrun simctl bootstatus "$udid" -b > /dev/null || { echo "could not boot $name" >&2; status=1; continue; }
  xcrun simctl install "$udid" "$app" || { echo "could not install on $name" >&2; status=1; continue; }
  # A simulator compiles its Metal shaders the first time SwiftUI draws an effect, on the main
  # thread and for tens of seconds in a VM; one unmeasured open per list leaves that out.
  echo "-- warm-up open, not measured ($logs/warm-up.log)"
  warm=(run open --udid "$udid" --style "$style" --runs 1 --lists "${lists// /,}")
  [[ "$name" == iPad* ]] && warm+=(--ipad)
  .venv/bin/python apps/apple/Tools/perf/ios_perf.py "${warm[@]}" > "$logs/warm-up.log" 2>&1 \
    || echo "warm-up failed ($logs/warm-up.log)" >&2
  read -r -a options <<< "$scenarios"
  # A width change too: the iPad's sidebar hides and shows, the iPhone turns.
  if [[ "$name" == iPad* ]]; then options+=(sidebar --ipad); else options+=(rotate); fi
  options=(run "${options[@]}" --udid "$udid" --style "$style" --runs "$runs" --lists "${lists// /,}")
  ((sample)) && options+=(--sample)
  touch "$logs/run-started"
  if ! .venv/bin/python apps/apple/Tools/perf/ios_perf.py "${options[@]}"; then
    status=1
    report=$(find ~/Library/Logs/DiagnosticReports -name 'Omnigent*' -newer "$logs/run-started" \
      2> /dev/null | head -1)
    if [[ -n "$report" ]]; then
      echo "-- crash report $report"
      head -c 6000 "$report"
    else
      echo "-- no crash report since the run started"
    fi
  fi
  if ((sample)); then
    for file in /tmp/omnigent-ios-*.txt; do
      [[ -e "$file" ]] || continue
      echo "-- $file"
      .venv/bin/python apps/apple/Tools/perf/sample-breakdown.py "$file" | head -40
      # Where the main thread waits, which the on-CPU breakdown leaves out: its heaviest path.
      echo "-- main thread call graph"
      awk '/^Call graph:/ { on = 1; next } on && /^    [0-9]+ Thread_/ && seen++ { exit } on' "$file" \
        | cut -c1-200 | head -70
      rm -f "$file"
    done
  fi
  xcrun simctl terminate "$udid" ai.omnigent.ios.lab 2> /dev/null
  xcrun simctl shutdown "$udid" || echo "could not shut $name down" >&2
done
exit $status
