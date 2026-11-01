#!/usr/bin/env bash
# Builds the Rust client core (client-core/) into the OmnigentCoreFFI Swift package:
#   Packages/OmnigentCoreFFI/omnigent_ffiFFI.xcframework   static libs + C header + module.modulemap
#   Packages/OmnigentCoreFFI/Sources/OmnigentCoreFFI/      UniFFI-generated Swift
#
# Usage: build-core.sh [debug|release] [--sim-only|--all-slices]
#   debug (default) builds the iOS simulator and host macOS slices only; pass --all-slices for
#   device + universal macOS. release builds every slice unless --sim-only is given.
# Set CARGO to use a different cargo binary or wrapper. CARGO_TARGET_DIR is honored, so a
# separate target directory can avoid contending with other cargo runs.
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") [debug|release] [--sim-only|--all-slices]" >&2
  exit 64
}

profile=debug
slices=""
for arg in "$@"; do
  case "$arg" in
    debug | release) profile="$arg" ;;
    --sim-only) slices=sim ;;
    --all-slices) slices=all ;;
    -h | --help) usage ;;
    *)
      echo "error: unknown argument '$arg'" >&2
      usage
      ;;
  esac
done
if [[ -z "$slices" ]]; then
  if [[ "$profile" == debug ]]; then slices=sim; else slices=all; fi
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
core_dir="$repo_root/client-core"
package_dir="$repo_root/apps/apple/Packages/OmnigentCoreFFI"
sources_dir="$package_dir/Sources/OmnigentCoreFFI"
xcframework="$package_dir/omnigent_ffiFFI.xcframework"
target_dir="${CARGO_TARGET_DIR:-$core_dir/target}"
cargo="${CARGO:-cargo}"

lib_name=libomnigent_ffi.a
ffi_module=omnigent_ffiFFI

export IPHONEOS_DEPLOYMENT_TARGET=26.0
export MACOSX_DEPLOYMENT_TARGET=26.0

for tool in xcodebuild lipo "$cargo"; do
  command -v "$tool" >/dev/null || {
    echo "error: '$tool' not found on PATH" >&2
    exit 1
  }
done

case "$(uname -m)" in
  arm64) host_mac=aarch64-apple-darwin ;;
  x86_64) host_mac=x86_64-apple-darwin ;;
  *)
    echo "error: unsupported host architecture $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$slices" == sim ]]; then
  ios_targets=(aarch64-apple-ios-sim)
  mac_targets=("$host_mac")
else
  ios_targets=(aarch64-apple-ios aarch64-apple-ios-sim)
  mac_targets=(aarch64-apple-darwin x86_64-apple-darwin)
fi

cargo_profile_flag=()
profile_dir=debug
if [[ "$profile" == release ]]; then
  cargo_profile_flag=(--release)
  profile_dir=release
fi

# rust-toolchain.toml is resolved from the working directory.
cd "$core_dir"

for target in "${ios_targets[@]}" "${mac_targets[@]}"; do
  echo "==> cargo build omnigent-ffi ($profile, $target)"
  "$cargo" build --locked -p omnigent-ffi --lib --target "$target" ${cargo_profile_flag[@]+"${cargo_profile_flag[@]}"}
done

staging="$(mktemp -d "${TMPDIR:-/tmp}/omnigent-core.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

echo "==> uniffi-bindgen generate (swift)"
"$cargo" run --locked -q -p uniffi-bindgen -- generate \
  --language swift \
  --metadata-no-deps \
  --out-dir "$staging/bindings" \
  "$target_dir/$host_mac/$profile_dir/$lib_name"

for generated in "$ffi_module.h" "$ffi_module.modulemap" omnigent_ffi.swift; do
  [[ -f "$staging/bindings/$generated" ]] || {
    echo "error: uniffi-bindgen did not produce $generated" >&2
    exit 1
  }
done

mkdir -p "$staging/headers"
cp "$staging/bindings/$ffi_module.h" "$staging/headers/"
cp "$staging/bindings/$ffi_module.modulemap" "$staging/headers/module.modulemap"

xcframework_args=()
for target in "${ios_targets[@]}"; do
  xcframework_args+=(-library "$target_dir/$target/$profile_dir/$lib_name" -headers "$staging/headers")
done

mac_lib="$staging/macos/$lib_name"
mkdir -p "$staging/macos"
mac_inputs=()
for target in "${mac_targets[@]}"; do
  mac_inputs+=("$target_dir/$target/$profile_dir/$lib_name")
done
echo "==> lipo macOS (${mac_targets[*]})"
lipo -create "${mac_inputs[@]}" -output "$mac_lib"
xcframework_args+=(-library "$mac_lib" -headers "$staging/headers")

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework "${xcframework_args[@]}" -output "$staging/$ffi_module.xcframework" >/dev/null

rm -rf "$xcframework"
mv "$staging/$ffi_module.xcframework" "$xcframework"
mkdir -p "$sources_dir"
cp "$staging/bindings/omnigent_ffi.swift" "$sources_dir/omnigent_ffi.swift"

echo "==> wrote $xcframework ($profile, slices: ${ios_targets[*]} + macOS ${mac_targets[*]})"
echo "==> wrote $sources_dir/omnigent_ffi.swift"
