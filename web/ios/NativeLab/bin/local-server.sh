#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
runtime_dir="$repo_dir/.native-lab-server"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: bash web/ios/NativeLab/bin/local-server.sh"
  echo "Starts an API-only development server at http://127.0.0.1:6767."
  echo "State: $runtime_dir. Stop with Ctrl-C; state is preserved."
  echo "For automatic startup at login: bin/local-services.sh install, then start."
  echo "Optional push: set OMNIGENT_APNS_ENABLED=1 plus TEAM_ID, KEY_ID and KEY_PATH prefixed OMNIGENT_APNS_."
  exit 0
fi
if [[ $# -ne 0 ]]; then
  echo "This launcher takes no arguments; use --help for details." >&2
  exit 2
fi
if [[ ! -x "$repo_dir/.venv/bin/omnigent" ]]; then
  echo "Install dependencies first: cd \"$repo_dir\" && OMNIGENT_SKIP_WEB_UI=true uv sync --frozen --no-dev" >&2
  exit 1
fi

umask 077
mkdir -p "$runtime_dir/config" "$runtime_dir/data" "$runtime_dir/artifacts"
cd "$runtime_dir"
"$repo_dir/.venv/bin/python" "$repo_dir/web/ios/NativeLab/bin/local-services.py" check-port

push_env=(OMNIGENT_APNS_ENABLED=0)
if [[ "${OMNIGENT_APNS_ENABLED:-0}" == "1" ]]; then
  push_env=(
    OMNIGENT_APNS_ENABLED=1
    OMNIGENT_APNS_LOCAL_DEVELOPMENT=1
    OMNIGENT_APNS_SINGLE_PROCESS=1
    OMNIGENT_APNS_SERVER_URL=http://127.0.0.1:6767
    "OMNIGENT_APNS_TEAM_ID=${OMNIGENT_APNS_TEAM_ID:-}"
    "OMNIGENT_APNS_KEY_ID=${OMNIGENT_APNS_KEY_ID:-}"
    "OMNIGENT_APNS_KEY_PATH=${OMNIGENT_APNS_KEY_PATH:-}"
    "OMNIGENT_APNS_TOPIC=${OMNIGENT_APNS_TOPIC:-ai.omnigent.ios.lab}"
    "OMNIGENT_APNS_ENVIRONMENT=${OMNIGENT_APNS_ENVIRONMENT:-sandbox}"
    "OMNIGENT_APNS_STORE_PATH=$runtime_dir/data/notifications.sqlite"
  )
fi

# Keep deployment credentials/config out of this loopback-only test server.
# Explicit store paths also avoid the machine-global server lifecycle record.
exec env -i \
  HOME="${HOME:?HOME must be set}" \
  PATH="$repo_dir/.venv/bin:${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}" \
  PYTHONUNBUFFERED=1 \
  OMNIGENT_CONFIG_HOME="$runtime_dir/config" \
  OMNIGENT_DATA_DIR="$runtime_dir/data" \
  OMNIGENT_LOCAL_SINGLE_USER=1 \
  OMNIGENT_SKIP_WEB_UI=true \
  OMNIGENT_NO_UPDATE_CHECK=1 \
  DO_NOT_TRACK=1 \
  "${push_env[@]}" \
  "$repo_dir/.venv/bin/omnigent" server \
    --host 127.0.0.1 \
    --port 6767 \
    --database-uri "sqlite:///$runtime_dir/data/chat.db" \
    --artifact-location "$runtime_dir/artifacts" \
    --no-open
