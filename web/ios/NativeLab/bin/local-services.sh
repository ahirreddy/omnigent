#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd)"
if [[ ! -x "$repo_dir/.venv/bin/python" ]]; then
  echo "Install dependencies first: OMNIGENT_SKIP_WEB_UI=true uv sync --frozen --no-dev" >&2
  exit 1
fi
exec "$repo_dir/.venv/bin/python" "$repo_dir/web/ios/NativeLab/bin/local-services.py" "$@"
