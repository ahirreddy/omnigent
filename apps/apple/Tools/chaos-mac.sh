#!/usr/bin/env bash
# Runs the Mac app's chaos driver (Apps/Omnigent-macOS/Sources/ChaosDriver.swift, Debug builds
# only) once per seed and sorts each run into done, crash or stall, keeping the evidence.
#
# It opens real windows and activates the app, so run it in a VM or on an idle Mac, not on a Mac
# in use. It needs no Accessibility or automation mode: the driver's input stays in the process.
#
# Usage: chaos-mac.sh --app PATH [--seeds FIRST-LAST] [--steps N] [--interval S]
#                     [--server URL --sessions id,id] [--out DIR]
# Without --server it runs on the app's offline demo server (-OmnigentDemo).
set -euo pipefail

app=""
seeds="1-5"
steps=400
interval=0.2
server=""
sessions=""
out="${TMPDIR:-/tmp}/omnigent-chaos-$(date +%Y%m%d-%H%M%S)"
while (($#)); do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --seeds) seeds="$2"; shift 2 ;;
    --steps) steps="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --server) server="$2"; shift 2 ;;
    --sessions) sessions="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
done
[[ -d "$app" ]] || { echo "error: --app must be the built Omnigent.app" >&2; exit 64; }
binary="$app/Contents/MacOS/Omnigent"
[[ -x "$binary" ]] || { echo "error: no executable at $binary" >&2; exit 64; }
first="${seeds%-*}"
last="${seeds#*-}"
mkdir -p "$out"
reports="$HOME/Library/Logs/DiagnosticReports"

# A run stalls when its log has not grown for this many seconds.
stall_after=60

running_pid() { pgrep -n -f "^$binary" || true; }

# One seed: launch, wait for DONE, a crash or a stall, and keep what explains it.
run_seed() {
  local seed="$1" dir="$out/seed-$seed" pid="" size=0 last_size=-1 still=0
  mkdir -p "$dir"
  local log="$dir/chaos.log" marker="$dir/.started"
  touch "$marker"
  local args=(-OmnigentChaos "$seed" -OmnigentChaosSteps "$steps" -OmnigentChaosInterval "$interval"
    -OmnigentChaosLog "$log" -ApplePersistenceIgnoreState YES -OmnigentNoNotificationPrompt YES
    -OmnigentTabsDirectory "$dir/tabs" -NSQuitAlwaysKeepsWindows NO)
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
  # The crash report lands a few seconds after the process ends.
  local report=""
  for _ in $(seq 1 20); do
    report="$(find "$reports" -maxdepth 1 -name 'Omnigent*.ips' -newer "$marker" | head -1)"
    [[ -z "$report" ]] || break
    sleep 1
  done
  [[ -z "$report" ]] || cp "$report" "$dir/"
  log show --last 3m --style compact \
    --predicate 'process == "Omnigent" AND (messageType == error OR messageType == fault)' \
    >"$dir/app-errors.log" 2>/dev/null || true
  echo "seed $seed: CRASH after $(tail -1 "$log")${report:+ ($(basename "$report"))}" \
    | tee "$dir/result"
}

for seed in $(seq "$first" "$last"); do
  run_seed "$seed"
  pid="$(running_pid)"
  [[ -z "$pid" ]] || kill -9 "$pid" 2>/dev/null || true
  sleep 1
done
cat "$out"/seed-*/result >"$out/summary.txt"
echo "results: $out"
