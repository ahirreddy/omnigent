#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
runtime_dir="$repo_dir/.native-lab-server"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: bash web/ios/NativeLab/bin/local-host.sh"
  echo "Registers this Mac with the dedicated API at http://127.0.0.1:6767."
  echo "Foreground process; Ctrl-C stops this host. Other hosts are untouched."
  echo "For automatic startup at login: bin/local-services.sh install, then start."
  exit 0
fi
if [[ $# -ne 0 || ! -x "$repo_dir/.venv/bin/omnigent" ]]; then
  echo "Install dependencies and start bin/local-server.sh first; this command takes no arguments." >&2
  exit 2
fi

umask 077
mkdir -p "$runtime_dir/host-config" "$runtime_dir/host-data" "$runtime_dir/chat-workspace"
cd "$runtime_dir/chat-workspace"
"$repo_dir/.venv/bin/python" "$repo_dir/web/ios/NativeLab/bin/local-services.py" wait-api
host_id="$(env -i HOME="${HOME:?HOME must be set}" PATH="$PATH" \
  "$repo_dir/.venv/bin/python" "$repo_dir/web/ios/NativeLab/bin/local-services.py" host-id)"

# Keep local host lifecycle records separate from any hosted Omnigent connection.
exec env -i \
  HOME="${HOME:?HOME must be set so the provider CLI can find the local login}" \
  PATH="$repo_dir/.venv/bin:${PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}" \
  PYTHONUNBUFFERED=1 \
  OMNIGENT_HOST_ID="$host_id" \
  OMNIGENT_HOST_NAME="NativeLab $(hostname -s)" \
  OMNIGENT_CONFIG_HOME="$runtime_dir/host-config" \
  OMNIGENT_DATA_DIR="$runtime_dir/host-data" \
  OMNIGENT_NO_UPDATE_CHECK=1 \
  DO_NOT_TRACK=1 \
  "$repo_dir/.venv/bin/omnigent" host --server http://127.0.0.1:6767 --non-interactive
