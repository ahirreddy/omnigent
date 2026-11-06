#!/usr/bin/env bash
# Xcode Cloud: before the UI tests run, start the loopback test stack they talk to (API on
# 127.0.0.1:6767, mock model on 6796, a registered host, seeded fixtures). Test machines get only
# ci_scripts, so this fetches the commit's source from GitHub first.
set -euo pipefail

die() {
  echo "ci_pre_xcodebuild: $*" >&2
  exit 1
}

action="${CI_XCODEBUILD_ACTION:-}"
echo "ci_pre_xcodebuild: action=${action:-unknown} platform=${CI_PRODUCT_PLATFORM:-?}"
[[ "$action" == "test-without-building" ]] || exit 0
[[ "${OMNIGENT_CI_SKIP_TEST_STACK:-0}" == "1" ]] && { echo "test stack skipped"; exit 0; }

commit="${CI_COMMIT:?CI_COMMIT is not set}"
source_repo="${OMNIGENT_SOURCE_REPO:-ahirreddy/omnigent}"
stack="${TMPDIR:-/tmp}/omnigent-test-stack"
logs="$stack/logs"
mkdir -p "$stack/src" "$logs"

curl -fsSL "https://codeload.github.com/$source_repo/tar.gz/$commit" \
  | tar -xz -C "$stack/src" --strip-components 1 \
  || die "could not download $source_repo@$commit"
repo="$stack/src"

if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh || die "uv install failed"
fi
export PATH="$HOME/.local/bin:$PATH"
(cd "$repo" && OMNIGENT_SKIP_WEB_UI=true uv sync --frozen --no-dev) \
  || die "Python dependencies failed to install"

# Each service outlives this script; its log lands in the Xcode Cloud artifacts' TMPDIR.
start() {
  local name="$1"
  shift
  nohup "$@" >"$logs/$name.log" 2>&1 &
  disown
  echo "started $name (pid $!)"
}
start server bash "$repo/apps/apple/Tools/local-server.sh"
start mock-model "$repo/.venv/bin/python" "$repo/apps/apple/Tools/mock-model.py" serve
"$repo/.venv/bin/python" "$repo/apps/apple/Tools/local-services.py" wait-api \
  || { cat "$logs/server.log" >&2; die "the API did not become healthy"; }
start host bash "$repo/apps/apple/Tools/local-host.sh"
"$repo/.venv/bin/python" "$repo/apps/apple/Tools/mock-model.py" install-agent \
  || die "installing the mock-model agent failed"
"$repo/.venv/bin/python" "$repo/apps/apple/Tools/seed-local-fixtures.py" \
  || die "seeding UI fixtures failed"
echo "ci_pre_xcodebuild: test stack is up at http://127.0.0.1:6767"
