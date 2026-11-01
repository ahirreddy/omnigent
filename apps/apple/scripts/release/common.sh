#!/usr/bin/env bash
# Shared helpers for the release scripts in this directory. Source it; do not run it.
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# The caller sets `set -euo pipefail` before sourcing.

if [[ -n "${OMNIGENT_RELEASE_COMMON_SOURCED:-}" ]]; then
  return 0
fi
OMNIGENT_RELEASE_COMMON_SOURCED=1

release_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apple_root="$(cd "$release_dir/../.." && pwd)"
repo_root="$(cd "$apple_root/../.." && pwd)"
export release_dir apple_root repo_root

# Names fixed by Project.swift and Tuist/ProjectDescriptionHelpers/BrowserTargets.swift.
readonly team_id_default="8RMX4WU6F8"
readonly web_host_name="Omnigent Web Host"
readonly cef_framework_name="Chromium Embedded Framework.framework"
# CEF's helper variants, in BrowserTargets.helperVariants order. The Tuist target (and its
# generated Derived/Entitlements file) is "OmnigentMacWebHostHelper<identifier>".
# shellcheck disable=SC2034 # used by the scripts that source this file
readonly helper_suffixes=("" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)")
# shellcheck disable=SC2034
readonly helper_identifiers=("" "GPU" "Renderer" "Plugin" "Alerts")
export team_id_default web_host_name cef_framework_name

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found on PATH"
  done
}

# Prints the value of a top-level string constant in OmnigentSettings.swift, for example
# `settings_constant marketingVersion`.
settings_constant() {
  local name="$1" file="$apple_root/Tuist/ProjectDescriptionHelpers/OmnigentSettings.swift" value
  [[ -f "$file" ]] || die "missing $file"
  value="$(sed -n "s/^ *public static let $name = \"\\([^\"]*\\)\"$/\\1/p" "$file")"
  [[ -n "$value" ]] || die "could not read '$name' from $file"
  printf '%s\n' "$value"
}

# True when the file is a Mach-O binary (thin or fat).
is_macho() {
  file -b "$1" | grep -q 'Mach-O'
}
