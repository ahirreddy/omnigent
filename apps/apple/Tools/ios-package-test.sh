#!/usr/bin/env bash
# Runs one Swift package's tests on an iOS simulator without fetching anything. Xcode keeps a
# package build's checkouts under its DerivedData; this one starts from a copy of the Debug
# workspace build's (apps/apple/build/DerivedData/SourcePackages, which vmq seeds in every test
# VM) and resolves offline, since the VMs' network blocks github.com. From the repository root:
#
#   bash apps/apple/Tools/ios-package-test.sh PACKAGE [--simulator NAME] [--build-only]
#        [xcodebuild arguments, such as -only-testing:OmnigentUITranscriptTests/SomeSuite]
#
# In the shared test VMs, as one job:
#   ~/src/omnigent-vm/vmq submit --priority high --tree "$PWD" --label "iOS tests" -- \
#     bash apps/apple/Tools/ios-package-test.sh OmnigentUI -only-testing:OmnigentUITranscriptTests
set -uo pipefail
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
die() {
  echo "ios-package-test: $*" >&2
  exit 1
}

(($#)) || die "usage: ios-package-test.sh PACKAGE [--simulator NAME] [--build-only] [xcodebuild args]"
package=$1
shift
simulator="iPhone 18 Pro" action=test
passed=()
while (($#)); do
  case "$1" in
    --simulator) simulator=$2; shift 2 ;;
    --build-only) action=build-for-testing; shift ;;
    *) passed+=("$1"); shift ;;
  esac
done

root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$root" || die "no repository root"
package_dir="$root/apps/apple/Packages/$package"
[[ -f "$package_dir/Package.swift" ]] || die "no package at $package_dir"
derived="$root/apps/apple/build/IOSPackageTests/$package"
logs="$root/apps/apple/build/IOSPackageTests/logs"
mkdir -p "$derived" "$logs"
log="$logs/$package-$(date +%s).log"

core=apps/apple/Packages/OmnigentCoreFFI/omnigent_ffiFFI.xcframework
# The debug core has the simulator slice; rebuilt only when missing or older than its sources.
if [[ ! -d "$core" ]] || [[ -n "$(find client-core -name '*.rs' -newer "$core" -print -quit)" ]]; then
  echo "== core"
  bash apps/apple/scripts/build-core.sh debug > "$logs/core.log" 2>&1 \
    || die "core build failed ($logs/core.log)"
fi

packages="$derived/SourcePackages"
if [[ ! -d "$packages/checkouts" ]]; then
  seed="$root/apps/apple/build/DerivedData/SourcePackages"
  [[ -d "$seed/checkouts" ]] \
    || die "no package checkouts at $seed to copy (in a VM, ~/seed-derived-data.sh \"$root\" makes them)"
  rm -rf "$packages"
  cp -cR "$seed" "$packages" || die "could not copy $seed"
fi
offline=(-clonedSourcePackagesDirPath "$packages" -disableAutomaticPackageResolution
  -skipPackageUpdates -skipPackagePluginValidation -skipMacroValidation)

xcrun simctl list devices available | grep -qF "    $simulator (" \
  || die "no simulator named $simulator; available: $(xcrun simctl list devices available | grep -E '^    i' | sed 's/ (.*//' | sort -u | tr '\n' ',')"

# A package with several products has a `-Package` scheme that builds all of them.
schemes=$(cd "$package_dir" && xcodebuild -list -json "${offline[@]}" 2> "$logs/list.log") \
  || die "could not list $package's schemes ($logs/list.log)"
scheme=$(/usr/bin/python3 -c '
import json, sys
names = json.loads(sys.stdin.read())["workspace"]["schemes"]
package = sys.argv[1]
print(next((name for name in (package + "-Package", package) if name in names), ""))
' "$package" <<< "$schemes")
[[ -n "$scheme" ]] || die "no test scheme for $package"

echo "== $action $scheme on $simulator (log: $log)"
started=$(date +%s)
(cd "$package_dir" && xcodebuild "$action" -scheme "$scheme" \
  -destination "platform=iOS Simulator,name=$simulator" -derivedDataPath "$derived" \
  "${offline[@]}" ${passed[@]+"${passed[@]}"}) > "$log" 2>&1
status=$?
grep -E "error:|^✘|^↳   |Test run with|Executed [0-9]+ test|Fatal error|\*\* .* (SUCCEEDED|FAILED) \*\*" "$log" \
  | cut -c1-240 | awk '!seen[$0]++' | head -80
echo "ios-package-test: exit $status in $(($(date +%s) - started))s"
exit $status
