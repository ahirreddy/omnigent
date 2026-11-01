#!/usr/bin/env bash
# Guarded SwiftLint wrapper for the apps-apple-swiftlint pre-commit hook.
#
# Lints the Swift files pre-commit passes (repo-relative paths) with apps/apple/.swiftlint.yml,
# strictly. Uses the swiftlint pinned in apps/apple/.mise.toml when mise can run it, otherwise
# a swiftlint on PATH, and exits 0 when neither exists (for example the Ubuntu CI pre-commit
# job). CI lints the whole tree in .github/workflows/client.yml.
set -euo pipefail

apple_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$apple_dir"

if command -v mise >/dev/null 2>&1 && mise exec -- swiftlint version >/dev/null 2>&1; then
  swiftlint=(mise exec -- swiftlint)
elif command -v swiftlint >/dev/null 2>&1; then
  swiftlint=(swiftlint)
else
  exit 0
fi

files=()
for file in "$@"; do
  files+=("${file#apps/apple/}")
done
if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

# --force-exclude applies the config's `excluded` list to explicitly passed files too.
exec "${swiftlint[@]}" lint --strict --quiet --config .swiftlint.yml --force-exclude "${files[@]}"
