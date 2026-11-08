#!/usr/bin/env bash
# Runs the Mac app's chaos driver (Apps/Omnigent-macOS/Sources/ChaosDriver.swift, Debug builds
# only) once per seed and sorts each run into done, crash or stall, keeping the evidence.
#
# It opens real windows and activates the app, so run it in a VM or on an idle Mac, not on a Mac
# in use. It needs no Accessibility or automation mode: the driver's input stays in the process.
#
# Usage: chaos-mac.sh --app PATH [--seeds FIRST-LAST or A,B,C] [--steps N] [--interval S]
#                     [--server URL --sessions id,id [--outages]] [--out DIR]
# Without --server it runs on the app's offline demo server (-OmnigentDemo). --outages pauses the
# server (SIGSTOP) for a few seconds now and then, so requests hang and streams stall.
set -euo pipefail

app=""
seeds="1-5"
steps=400
interval=0.2
server=""
sessions=""
outages=0
out="${TMPDIR:-/tmp}/omnigent-chaos-$(date +%Y%m%d-%H%M%S)"
while (($#)); do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --seeds) seeds="$2"; shift 2 ;;
    --steps) steps="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --server) server="$2"; shift 2 ;;
    --sessions) sessions="$2"; shift 2 ;;
    --outages) outages=1; shift ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
done
[[ -d "$app" ]] || { echo "error: --app must be the built Omnigent.app" >&2; exit 64; }
binary="$app/Contents/MacOS/$(defaults read "$app/Contents/Info" CFBundleExecutable)"
[[ -x "$binary" ]] || { echo "error: no executable at $binary" >&2; exit 64; }
# A sandboxed edition (the Mac App Store one) writes its log and tabs in its container.
container=""
if codesign -d --entitlements - "$app" 2>/dev/null | grep -q app-sandbox; then
  container="$HOME/Library/Containers/$(defaults read "$app/Contents/Info" CFBundleIdentifier)/Data"
fi
if [[ "$seeds" == *-* ]]; then
  seed_list=$(seq "${seeds%-*}" "${seeds#*-}")
else
  seed_list=${seeds//,/ }
fi
mkdir -p "$out"
reports="$HOME/Library/Logs/DiagnosticReports"

# A run stalls when its log has not grown for this many seconds.
stall_after=60

running_pid() { pgrep -n -f "^$binary" || true; }

server_pid() { lsof -nP -iTCP:"${server##*:}" -sTCP:LISTEN -t 2>/dev/null | head -1 || true; }

# Resumes the server if a pause left it stopped.
resume_server() {
  local pid
  pid="$(server_pid)"
  [[ -z "$pid" ]] || kill -CONT "$pid" 2>/dev/null || true
}

# Pauses the server every 10 to 40 seconds for 3 to 22 seconds, logging the step each followed.
pause_server_now_and_then() {
  local log="$1" chaos_log="$2" pid hold
  trap 'resume_server; exit 0' TERM
  while true; do
    sleep $((10 + RANDOM % 30)) & wait $!
    pid="$(server_pid)"
    if [[ -z "$pid" ]]; then
      echo "no server listening to pause" >> "$log"
      continue
    fi
    hold=$((3 + RANDOM % 20))
    echo "pause ${hold}s after: $(tail -1 "$chaos_log" 2>/dev/null)" >> "$log"
    kill -STOP "$pid"
    sleep "$hold" & wait $!
    kill -CONT "$pid"
  done
}

# One seed: launch, wait for DONE, a crash or a stall, and keep what explains it.
run_seed() {
  local seed="$1" dir="$out/seed-$seed" pid=""
  mkdir -p "$dir"
  local log="$dir/chaos.log" tabs="$dir/tabs" marker="$dir/.started"
  if [[ -n "$container" ]]; then
    log="$container/tmp/chaos-$seed.log"
    tabs="$container/tmp/chaos-tabs-$seed"
    rm -rf "$log" "$tabs"
  fi
  touch "$marker" "$log"
  local args=(-OmnigentChaos "$seed" -OmnigentChaosSteps "$steps" -OmnigentChaosInterval "$interval"
    -OmnigentChaosLog "$log" -ApplePersistenceIgnoreState YES -OmnigentNoNotificationPrompt YES
    -OmnigentTabsDirectory "$tabs" -NSQuitAlwaysKeepsWindows NO)
  if [[ -n "$server" ]]; then
    args+=(-desktop.defaultServerURL "$server")
    [[ -z "$sessions" ]] || args+=(-OmnigentChaosSessions "$sessions")
  else
    args+=(-OmnigentDemo YES)
  fi
  open -n -g "$app" --args "${args[@]}"
  for _ in $(seq 1 60); do
    pid="$(running_pid)"
    [[ -z "$pid" ]] || break
    sleep 1
  done
  [[ -n "$pid" ]] || { echo "seed $seed: the app never started" | tee "$dir/result"; return; }
  local pauser=""
  if ((outages)) && [[ -n "$server" ]]; then
    pause_server_now_and_then "$dir/outages.log" "$log" &
    pauser=$!
  fi
  watch_seed "$seed" "$dir" "$log" "$marker" "$pid"
  if [[ -n "$container" ]]; then
    cp "$log" "$dir/chaos.log"
    [[ ! -d "$tabs" ]] || cp -R "$tabs" "$dir/tabs"
  fi
  if [[ -n "$pauser" ]]; then
    kill -TERM "$pauser" 2>/dev/null || true
    wait "$pauser" 2>/dev/null || true
    resume_server
  fi
}

# Waits for one seed's run to finish, crash or stall, and writes its result.
watch_seed() {
  local seed="$1" dir="$2" log="$3" marker="$4" pid="$5" size=0 last_size=-1 still=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    size=$(stat -f %z "$log" 2>/dev/null || echo 0)
    if ((size == last_size)); then still=$((still + 2)); else still=0; fi
    last_size=$size
    if ((still >= stall_after)); then
      # Two samples ten seconds apart tell a slow main thread from one stuck in a loop.
      for attempt in 1 2; do
        if ! sample "$pid" 3 -file "$dir/stall-sample-$attempt.txt" >/dev/null 2>&1; then
          echo "sample $attempt of $pid failed" >> "$dir/notes"
        fi
        ((attempt == 2)) || sleep 10
      done
      kill -9 "$pid" 2>/dev/null || true
      echo "seed $seed: STALL after $(tail -1 "$log")" | tee "$dir/result"
      return
    fi
  done
  if grep -q '^DONE' "$log" 2>/dev/null; then
    echo "seed $seed: done ($(tail -1 "$log"))" | tee "$dir/result"
    return
  fi
  # The crash report can land up to half a minute after the process ends.
  local report=""
  for _ in $(seq 1 60); do
    report="$(find "$reports" -maxdepth 1 -name 'Omnigent*.ips' -newer "$marker" | head -1)"
    [[ -z "$report" ]] || break
    sleep 1
  done
  [[ -z "$report" ]] || cp "$report" "$dir/"
  log show --last 3m --style compact \
    --predicate 'process == "Omnigent" AND (messageType == error OR messageType == fault)' \
    >"$dir/app-errors.log" 2>>"$dir/notes" || echo "log show failed" >> "$dir/notes"
  echo "seed $seed: CRASH after $(tail -1 "$log")${report:+ ($(basename "$report"))}" \
    | tee "$dir/result"
}

if [[ -n "$container" && ! -d "$container/tmp" ]]; then
  # The system makes the container on the first launch.
  open -n -g "$app" --args -OmnigentDemo YES -ApplePersistenceIgnoreState YES
  for _ in $(seq 1 30); do
    [[ ! -d "$container/tmp" ]] || break
    sleep 1
  done
  pkill -9 -f "^$binary" || true
  [[ -d "$container/tmp" ]] || { echo "error: no container at $container" >&2; exit 1; }
fi
for seed in $seed_list; do
  run_seed "$seed"
  pid="$(running_pid)"
  [[ -z "$pid" ]] || kill -9 "$pid" 2>/dev/null || true
  sleep 1
done
cat "$out"/seed-*/result >"$out/summary.txt"
echo "results: $out"
