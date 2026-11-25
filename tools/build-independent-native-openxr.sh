#!/bin/bash
# Build the source runtime with the caller's ordinary Rust/Xcode toolchains.
# No installed app, game, bottle, private cache or user setting is accessed.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: $0 [OUTPUT_DIRECTORY]"
    echo 'Needs the aarch64-apple-darwin and x86_64-apple-darwin Rust targets.'
    echo 'CARGO, CARGO_HOME, RUSTUP_HOME, CARGO_TARGET_DIR and DEVELOPER_DIR are respected.'
    echo 'Set HALLIDAY_CARGO_OFFLINE=1 only when dependencies are already cached.'
    exit 0
fi
[[ $# -le 1 ]] || { echo "Usage: $0 [OUTPUT_DIRECTORY]" >&2; exit 2; }
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
cargo_bin="${CARGO:-cargo}"
command -v "$cargo_bin" >/dev/null || { echo 'Install Rust, or set CARGO to the cargo executable.' >&2; exit 2; }
destination="${1:-$repo_dir/build/independent-native-openxr}"
cargo_target_root="${CARGO_TARGET_DIR:-$repo_dir/core/target}"
[[ "$cargo_target_root" = /* ]] || cargo_target_root="$repo_dir/$cargo_target_root"
cargo_options=(build)
case "${HALLIDAY_CARGO_OFFLINE:-0}" in
    1|true|yes) cargo_options+=(--offline) ;;
    0|false|no) ;;
    *) echo 'HALLIDAY_CARGO_OFFLINE must be 0 or 1.' >&2; exit 2 ;;
esac
for target in aarch64-apple-darwin x86_64-apple-darwin; do
    "$cargo_bin" "${cargo_options[@]}" --manifest-path "$repo_dir/core/Cargo.toml" \
        -p halliday-openxr --release --target "$target" --target-dir "$cargo_target_root"
done
mkdir -p "$destination"
xcrun lipo -create \
    "$cargo_target_root/aarch64-apple-darwin/release/libhalliday_openxr.dylib" \
    "$cargo_target_root/x86_64-apple-darwin/release/libhalliday_openxr.dylib" \
    -output "$destination/libhalliday_openxr.dylib"
xcrun install_name_tool -id @rpath/libhalliday_openxr.dylib "$destination/libhalliday_openxr.dylib"
codesign --force --sign - "$destination/libhalliday_openxr.dylib"
cat > "$destination/halliday_native_openxr.json" <<'JSON'
{
  "file_format_version": "1.0.0",
  "runtime": {
    "name": "Halliday",
    "library_path": "./libhalliday_openxr.dylib"
  }
}
JSON
xcrun lipo "$destination/libhalliday_openxr.dylib" -verify_arch arm64
xcrun lipo "$destination/libhalliday_openxr.dylib" -verify_arch x86_64
shasum -a 256 "$destination/libhalliday_openxr.dylib"
