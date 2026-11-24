#!/bin/bash
# Build the ordinary VeRantyx frame bridge. No game files are read or installed.
set -euo pipefail

repository="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repository/native-alyx/frame-bridge"
output_dir="$repository/build/native-alyx/bin"
vulkan_include="${VULKAN_SDK:+${VULKAN_SDK}/include}"
moltenvk_library=""

usage() {
    echo "Usage: $0 --moltenvk-library PATH/libMoltenVK.dylib [--vulkan-include SDK/include] [--output-dir DIR]" >&2
    echo 'VULKAN_SDK/include may supply the public Vulkan headers instead.' >&2
}
while (($#)); do
    case "$1" in
        --moltenvk-library|--vulkan-include|--output-dir)
            (($# >= 2)) || { usage; exit 2; }
            case "$1" in
                --moltenvk-library) moltenvk_library="$2" ;;
                --vulkan-include) vulkan_include="$2" ;;
                --output-dir) output_dir="$2" ;;
            esac
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
[[ -n "$moltenvk_library" && -r "$moltenvk_library" && "${moltenvk_library##*/}" = libMoltenVK.dylib ]] || {
    echo 'An explicit readable libMoltenVK.dylib is required.' >&2; exit 2;
}
[[ -n "$vulkan_include" && -r "$vulkan_include/vulkan/vulkan.h" && -r "$vulkan_include/vulkan/vulkan_core.h" ]] || {
    echo 'Public Vulkan SDK headers are required; set VULKAN_SDK or --vulkan-include.' >&2; exit 2;
}

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
temporary="$(mktemp "$output_dir/.frame-bridge.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
xcrun clang++ -arch arm64 -std=c++17 -O2 -g0 -mmacosx-version-min=14.0 \
    "-ffile-prefix-map=$repository=." \
    -I "$repository/windows-openxr/include" -I "$vulkan_include" \
    "$source_dir/bridge.cpp" "$moltenvk_library" \
    -Wl,-rpath,@executable_path -o "$temporary"

# The input library can have a developer-local install name. Only the portable
# name is retained; the launcher supplies the selected port's Vulkan library.
dependency="$(/usr/bin/otool -L "$temporary" | /usr/bin/awk '/libMoltenVK\.dylib/ {print $1}')"
[[ -n "$dependency" && "$dependency" != *$'\n'* ]] || {
    echo 'The frame bridge must link exactly one MoltenVK library.' >&2; exit 1;
}
if [[ "$dependency" != '@rpath/libMoltenVK.dylib' ]]; then
    /usr/bin/install_name_tool -change "$dependency" '@rpath/libMoltenVK.dylib' "$temporary"
fi
/usr/bin/codesign --force --sign - "$temporary"
chmod 755 "$temporary"
mv -f "$temporary" "$output_dir/halliday-native-frame-bridge"
cp "$source_dir/Native-Alyx-Bridge-MIT.txt" "$output_dir/Native-Alyx-Bridge-MIT.txt"
cp "$source_dir/OpenVR-BSD.txt" "$output_dir/OpenVR-BSD.txt"
echo "$output_dir/halliday-native-frame-bridge"
