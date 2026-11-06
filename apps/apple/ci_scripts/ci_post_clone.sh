#!/usr/bin/env bash
# Xcode Cloud: prepares a fresh clone the way .github/workflows/client.yml does (pinned Rust,
# mise tools, the Rust core, libghostty, CEF on macOS), then generates the Tuist workspace.
# Building under a personal team: set TUIST_OMNIGENT_BUNDLE_ID_PREFIX in the workflow; the team
# defaults to the workflow's own (CI_TEAM_ID). See apps/apple/docs/xcode-cloud.md.
set -euo pipefail

die() {
  echo "ci_post_clone: $*" >&2
  exit 1
}

repo="${CI_PRIMARY_REPOSITORY_PATH:?CI_PRIMARY_REPOSITORY_PATH is not set; run under Xcode Cloud}"
apple="$repo/apps/apple"
platform="${CI_PRODUCT_PLATFORM:-}"
echo "ci_post_clone: platform=${platform:-unknown} workflow=${CI_WORKFLOW:-?} commit=${CI_COMMIT:-?}"

if [[ -n "${CI_TEAM_ID:-}" && -z "${TUIST_OMNIGENT_TEAM_ID:-}" ]]; then
  export TUIST_OMNIGENT_TEAM_ID="$CI_TEAM_ID"
fi

# Rust, at the toolchain and targets client-core/rust-toolchain.toml pins.
if ! command -v rustup >/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain none --no-modify-path \
    || die "rustup install failed"
fi
export PATH="$HOME/.cargo/bin:$PATH"
(cd "$repo/client-core" && rustup toolchain install) || die "rust toolchain install failed"

# mise installs the pinned tuist, swiftlint and zig from apps/apple/.mise.toml.
if ! command -v mise >/dev/null; then
  curl -fsSL https://mise.run | sh || die "mise install failed"
fi
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export MISE_TRUSTED_CONFIG_PATHS="$apple"
export MISE_YES=1
(cd "$apple" && mise install) || die "mise install of the pinned tools failed"

bash "$apple/scripts/build-core.sh" debug || die "Rust core build failed"

# libghostty (terminals, both platforms) needs the Metal toolchain, and msgfmt (gettext) for
# its translations.
xcodebuild -downloadComponent MetalToolchain || die "Metal toolchain download failed"
command -v msgfmt >/dev/null || brew install gettext || die "gettext install failed"
bash "$apple/scripts/fetch-ghostty.sh" || die "libghostty fetch failed"

# CEF (the Mac's Chromium engine) builds its wrapper with cmake.
if [[ "$platform" == "macOS" ]]; then
  command -v cmake >/dev/null || brew install cmake || die "cmake install failed"
  bash "$apple/scripts/fetch-cef.sh" --arch arm64 || die "CEF fetch failed"
fi

cd "$apple"
mise exec -- tuist install || die "tuist install failed"
mise exec -- tuist generate --no-open || die "tuist generate failed"
