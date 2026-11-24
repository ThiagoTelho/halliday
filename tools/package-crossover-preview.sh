#!/bin/bash
# Package the ordinary app plus available, source-built VR modules. Never install it.
# Development identity/version/update overrides are opt-in; ordinary metadata is preserved.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    echo "Usage: $0 [OUTPUT_ZIP]"
    echo 'Base app: HALLIDAY_PACKAGE_APP (default build/Halliday.app).'
    echo 'Optional groups: HALLIDAY_PACKAGE_WINDOWS / ROUTER / NATIVE = auto, yes or no.'
    echo 'Use HALLIDAY_PACKAGE_DEVELOPMENT=1 for a separate local Preview identity.'
    echo 'Development-only overrides: HALLIDAY_DEV_NAME, HALLIDAY_DEV_BUNDLE_ID, HALLIDAY_DEV_VERSION.'
    echo 'Signing: HALLIDAY_PACKAGE_SIGN_ID and HALLIDAY_PACKAGE_ENTITLEMENTS.'
    exit 0
fi
[[ $# -le 1 ]] || { echo "Usage: $0 [OUTPUT_ZIP]" >&2; exit 2; }
base_app="${HALLIDAY_PACKAGE_APP:-build/Halliday.app}"
[[ -d "$base_app" && -f "$base_app/Contents/Info.plist" ]] || { echo "Missing base app: $base_app (make app)" >&2; exit 1; }
development="${HALLIDAY_PACKAGE_DEVELOPMENT:-0}"
case "$development" in 0|1) ;; *) echo 'HALLIDAY_PACKAGE_DEVELOPMENT must be 0 or 1.' >&2; exit 2 ;; esac
# Refuse stale private payloads instead of silently carrying them from an old local bundle.
package_name="$(python3 - "$base_app" "$development" <<'PY'
import os, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
for path in (app / 'Contents/Resources').rglob('*'):
    if path.name in {'WindowsMoltenOpenXR', 'NativeMoltenOpenXR', 'moltenvr_stock.dll', 'libmoltenvr_stock.dylib'} or path.name.startswith(('halliday_molten_', 'libhalliday_molten_')):
        raise SystemExit('Refusing an old private runtime payload: ' + str(path))
p = plistlib.loads((app/'Contents/Info.plist').read_bytes())
name = os.environ.get('HALLIDAY_DEV_NAME', 'Halliday Preview') if sys.argv[2] == '1' else p['CFBundleName']
if not name or '/' in name or name in {'.', '..'} or '\n' in name:
    raise SystemExit('Invalid app bundle name')
print(name)
PY
)"
archive="${1:-${HALLIDAY_PACKAGE_ARCHIVE:-output/$package_name.zip}}"
# Assemble on local temporary storage so synced-folder metadata cannot alter the signature.
package_stage="$(mktemp -d "${TMPDIR:-/private/tmp}/halliday-package.XXXXXX")"
trap 'rm -rf "$package_stage"' EXIT
package_app="$package_stage/$package_name.app"
ditto --norsrc --noextattr "$base_app" "$package_app"
resources="$package_app/Contents/Resources"
mkdir -p "$resources/Licenses"
# Rebuild optional groups from explicit source build products, never merge stale modules.
for group in WindowsOpenXR AutomaticOpenXR NativeOpenXR NativeAlyx; do
    rm -rf "$resources/$group"
done

# auto includes a complete available module, yes requires it, no leaves it out.
# An incomplete build is an error rather than a partially functional bundle.
include_group() {
    local mode="$1"; shift
    local present=0 item
    case "$mode" in auto|yes|no) ;; *) echo 'Package group mode must be auto, yes or no.' >&2; exit 2 ;; esac
    [[ "$mode" != no ]] || return 1
    for item in "$@"; do [[ ! -e "$item" ]] || present=$((present + 1)); done
    if [[ "$mode" == auto && "$present" == 0 ]]; then return 1; fi
    for item in "$@"; do
        [[ -f "$item" && ! -L "$item" ]] || { echo "Missing or invalid module file: $item" >&2; exit 2; }
    done
    return 0
}

windows_bin=windows-openxr/build/windows/bin
if include_group "${HALLIDAY_PACKAGE_WINDOWS:-auto}" \
        "$windows_bin/halliday_openxr.dll" "$windows_bin/halliday_openxr.json" build/halliday-xr-registry.exe; then
    mkdir -p "$resources/WindowsOpenXR"
    cp "$windows_bin/halliday_openxr.dll" "$windows_bin/halliday_openxr.json" build/halliday-xr-registry.exe "$resources/WindowsOpenXR/"
    cp windows-openxr/LICENSE-BasaltVR "$resources/Licenses/BasaltVR-MIT.txt"
    cp windows-openxr/LICENSE-Khronos-MIT "$resources/Licenses/OpenXR-Headers-MIT.txt"
    cp windows-openxr/LICENSE-Khronos-Vulkan-MIT "$resources/Licenses/Vulkan-Headers-MIT.txt"
    cp windows-openxr/LICENSE-LLVM-MinGW "$resources/Licenses/LLVM-MinGW-runtime.txt"
fi
router_bin=build/router-openxr/bin
if include_group "${HALLIDAY_PACKAGE_ROUTER:-auto}" \
        "$router_bin/halliday_openxr_router.dll" "$router_bin/halliday_openxr_router.json" \
        "$router_bin/vrclient_x64.dll" "$router_bin/LICENSE-nlohmann-json"; then
    [[ -f "$resources/WindowsOpenXR/halliday_openxr.dll" ]] || { echo 'The automatic router requires WindowsOpenXR.' >&2; exit 2; }
    mkdir -p "$resources/AutomaticOpenXR"
    cp "$router_bin/halliday_openxr_router.dll" "$router_bin/halliday_openxr_router.json" \
        "$router_bin/vrclient_x64.dll" "$router_bin/LICENSE-nlohmann-json" "$resources/AutomaticOpenXR/"
    cp "$router_bin/LICENSE-nlohmann-json" "$resources/Licenses/nlohmann-json-MIT.txt"
fi
native_bin=build/independent-native-openxr
alyx_bin=build/native-alyx/bin
if include_group "${HALLIDAY_PACKAGE_NATIVE:-auto}" \
        "$native_bin/libhalliday_openxr.dylib" "$native_bin/halliday_native_openxr.json" \
        "$alyx_bin/libhalliday_alyx_redirect.dylib" "$alyx_bin/halliday-alyx-bridge" "$alyx_bin/halliday-steam-ready"; then
    mkdir -p "$resources/NativeOpenXR" "$resources/NativeAlyx"
    cp "$native_bin/libhalliday_openxr.dylib" "$native_bin/halliday_native_openxr.json" \
        "$alyx_bin/libhalliday_alyx_redirect.dylib" "$alyx_bin/halliday-alyx-bridge" "$resources/NativeOpenXR/"
    cp "$alyx_bin/halliday-steam-ready" "$resources/NativeAlyx/"
    chmod +x "$resources/NativeOpenXR/halliday-alyx-bridge" "$resources/NativeAlyx/halliday-steam-ready"
    for name in libhalliday_openxr.dylib libhalliday_alyx_redirect.dylib; do
        xcrun lipo "$resources/NativeOpenXR/$name" -verify_arch arm64 x86_64
    done
    # Optional coherent VeRantyx reader, built only from the vendored MIT source.
    frame_bridge="$alyx_bin/halliday-native-frame-bridge"
    if [[ -e "$frame_bridge" ]]; then
        [[ -f "$frame_bridge" && -x "$frame_bridge" && ! -L "$frame_bridge" ]] || { echo 'Invalid native frame bridge.' >&2; exit 2; }
        [[ "$(xcrun lipo -archs "$frame_bridge")" == arm64 ]] || { echo 'Native frame bridge must be ARM64-only.' >&2; exit 2; }
        dependencies="$(xcrun otool -L "$frame_bridge")"
        [[ "$dependencies" == *'@rpath/libMoltenVK.dylib'* && "$dependencies" != *'/Users/'* && "$dependencies" != *'/Volumes/'* ]] || { echo 'Non-portable native frame bridge dependency.' >&2; exit 2; }
        if /usr/bin/strings "$frame_bridge" | /usr/bin/grep -F 'HALLIDAY_NATIVE_GUEST_TRACE_PATH' >/dev/null; then
            echo 'A diagnostic frame reader cannot be packaged.' >&2; exit 2
        fi
        cp "$frame_bridge" "$resources/NativeOpenXR/"
        for license in Native-Alyx-Bridge-MIT.txt OpenVR-BSD.txt; do
            cp "$alyx_bin/$license" "$resources/Licenses/"
        done
        cp native-alyx/frame-bridge/SOURCE.json "$resources/NativeOpenXR/frame-bridge-source.json"
    fi
fi

if [[ "$development" == 1 ]]; then
    python3 - "$package_app/Contents/Info.plist" "$package_name" <<'PY'
import os, plistlib, sys
path, name = sys.argv[1:]
with open(path, 'rb') as file:
    p = plistlib.load(file)
p.update(CFBundleIdentifier=os.environ.get('HALLIDAY_DEV_BUNDLE_ID', 'app.halliday.Halliday.preview'),
         CFBundleName=name, CFBundleDisplayName=name, HallidayRuntimeFolderName=name,
         SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False)
if 'HALLIDAY_DEV_VERSION' in os.environ:
    p['CFBundleVersion'] = os.environ['HALLIDAY_DEV_VERSION']
p.pop('SUFeedURL', None)
with open(path, 'wb') as file:
    plistlib.dump(p, file)
PY
fi
xattr -cr "$package_app"
codesign --force --options runtime --entitlements "${HALLIDAY_PACKAGE_ENTITLEMENTS:-app/Halliday-dev.entitlements}" \
    --sign "${HALLIDAY_PACKAGE_SIGN_ID:--}" "$package_app"
codesign --verify --deep --strict "$package_app"
ditto -c -k --norsrc --noextattr --keepParent "$package_app" "$package_stage/package.zip"
mkdir -p "$(dirname "$archive")"
mv -f "$package_stage/package.zip" "$archive"
echo "Built $archive"
