#!/bin/bash
# Builds against caller-supplied public Khronos SDK sources; never starts Wine/downloads.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
sdk_dir="${HALLIDAY_OPENXR_SDK:-$repository/reference/openxr-sdk}"
build_dir="$repository/build/openxr-loader-smoke"
jobs="${VR_JOBS:-2}"
usage() { echo "Usage: $0 [--sdk OpenXR-SDK-1.1.65] [--jobs N]"; }
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --sdk|--jobs)
            (($# >= 2)) || { usage >&2; exit 2; }
            if [[ "$1" = --sdk ]]; then sdk_dir="$2"; else jobs="$2"; fi
            shift 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] && ((jobs <= 32)) || { echo 'Use 1–32 build jobs.' >&2; exit 2; }
[[ -f "$sdk_dir/CMakeLists.txt" && -f "$sdk_dir/include/openxr/openxr.h" ]] || {
    echo 'Supply public OpenXR-SDK 1.1.65 sources with --sdk or HALLIDAY_OPENXR_SDK; nothing is downloaded.' >&2; exit 2;
}
grep -Eq 'XR_CURRENT_API_VERSION XR_MAKE_VERSION\(1, 1, 65\)' "$sdk_dir/include/openxr/openxr.h" || {
    echo 'Expected the public OpenXR SDK 1.1.65.' >&2; exit 2;
}
mingw_dir="${HALLIDAY_MINGW_BIN:-}"
if [[ -z "$mingw_dir" ]]; then
    compiler="$(command -v x86_64-w64-mingw32-clang++ || true)"
    [[ -n "$compiler" ]] || { echo 'Set HALLIDAY_MINGW_BIN to an LLVM-MinGW bin directory.' >&2; exit 2; }
    mingw_dir="$(dirname "$compiler")"
fi
cmake -S "$repository/tools/tests/openxr-loader" -B "$build_dir" \
    -DHALLIDAY_OPENXR_SDK="$sdk_dir" \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 \
    -DCMAKE_C_COMPILER="$mingw_dir/x86_64-w64-mingw32-clang" \
    -DCMAKE_CXX_COMPILER="$mingw_dir/x86_64-w64-mingw32-clang++" \
    -DCMAKE_RC_COMPILER="$mingw_dir/x86_64-w64-mingw32-windres" \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "$build_dir" --target openxr-loader-smoke --parallel "$jobs"
printf 'Built actual Khronos loader smoke: %s/bin/openxr-loader-smoke.exe\n' "$build_dir"
