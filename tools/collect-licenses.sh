#!/bin/bash
# The licences of what the app carries, into OUT (the bundle's Contents/Resources/Licenses, from
# the Makefile's app rule): Halliday's own and THIRD-PARTY.md, the libraries compiled into
# Halliday (libusb, rusb, libc, thiserror, openxr-sys), and, when `make klepton` / `make unzl`
# put them in the bundle, the Quest runtime's (Klepton, SDL3, MoltenVK) and the unpacker's
# (OpenZL, Zstandard, LZ4). THIRD-PARTY.md says what each one is.
#
#     tools/collect-licenses.sh OUT
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?usage: collect-licenses.sh OUT}

# Resolve the dependency graph once. Use Cargo's normal resolution behavior:
# metadata needs package sources even when their build artifacts already exist.
CARGO_METADATA_JSON=$(cargo metadata \
  --manifest-path core/Cargo.toml \
  --format-version 1 \
  --locked)

rm -rf "$OUT"
mkdir -p "$OUT"

cp LICENSE "$OUT/Halliday.txt"
cp THIRD-PARTY.md "$OUT/THIRD-PARTY.md"

# Rust crates compiled in: found through cargo, which knows where each one's source is.
crate_dir() {
  /usr/bin/python3 -c '
import json, sys, os

name = sys.argv[1]
packages = json.load(sys.stdin)["packages"]

for package in packages:
    if package["name"] == name:
        print(os.path.dirname(package["manifest_path"]))
        break
else:
    sys.exit(f"collect-licenses: crate {name!r} not found in Cargo metadata")
' "$1" <<<"$CARGO_METADATA_JSON"
}

copy_crate() {  # crate, files…
    local dir; dir=$(crate_dir "$1")
    local name=$1; shift
    for f in "$@"; do cp "$dir/$f" "$OUT/$name-$f.txt"; done
}
copy_crate libusb1-sys LICENSE
cp "$(crate_dir libusb1-sys)/libusb/COPYING" "$OUT/libusb-COPYING.txt"
cp "$(crate_dir libusb1-sys)/libusb/AUTHORS" "$OUT/libusb-AUTHORS.txt"
copy_crate rusb LICENSE
copy_crate libc LICENSE-MIT LICENSE-APACHE
copy_crate thiserror LICENSE-MIT LICENSE-APACHE
# openxr-sys (MIT or Apache-2.0) carries no licence file: taken under Apache-2.0, whose text is libc's.
cp "$(crate_dir libc)/LICENSE-APACHE" "$OUT/openxr-sys-LICENSE-APACHE.txt"

# Sparkle, the updater the app always carries.
cp reference/sparkle/LICENSE "$OUT/Sparkle-LICENSE.txt"

# The Quest runtime, when the bundle has it.
if [ -x build/quest/klepton-runner ]; then
    cp reference/klepton-moltenvr/LICENSE "$OUT/Klepton-LICENSE.txt"
    for f in reference/klepton-moltenvr/third-party-licenses/*.txt; do cp "$f" "$OUT/Klepton-$(basename "$f")"; done
    brew=$(brew --prefix)
    cp "$brew/opt/sdl3/LICENSE.txt" "$OUT/SDL3-LICENSE.txt"
    cp "$brew/opt/molten-vk/LICENSE" "$OUT/MoltenVK-LICENSE.txt"
fi
# The unpacker, when the bundle has it.
if [ -x build/quest/unzl ]; then
    cp reference/openzl/LICENSE "$OUT/OpenZL-LICENSE.txt"
    cp reference/openzl/deps/zstd/LICENSE "$OUT/Zstandard-LICENSE.txt"
    cp reference/openzl/deps/lz4/lib/LICENSE "$OUT/LZ4-LICENSE.txt"
fi
