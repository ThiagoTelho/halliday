#!/bin/sh
# Clone the projects Halliday learns from into reference/ (git-ignored), for reading and for
# running GAV's player as a known-good baseline. Re-running updates them.
set -eu
cd "$(dirname "$0")/.."
mkdir -p reference

fetch() { # name url [branch]
	if [ -d "reference/$1/.git" ]; then
		git -C "reference/$1" pull --ff-only
	else
		git clone --depth 1 ${3:+-b "$3"} "$2" "reference/$1"
	fi
}

fetch gav-psvr2-player-mac https://github.com/GAVProject/gav-psvr2-player-mac.git
fetch monado https://gitlab.freedesktop.org/monado/monado.git
fetch openxr-sdk https://github.com/KhronosGroup/OpenXR-SDK.git
# Quest games on Apple Silicon (ROADMAP W15): Klepton, and the fork that sends it to a headset
# through an OpenXR runtime on the Mac (its client is source/runtime/gfx/kl_moltenvr.mm).
fetch klepton https://github.com/shinyquagsire23/Klepton.git
fetch klepton-moltenvr https://github.com/armax9/Klepton-MoltenVR.git moltenvr-macos
# OpenZL, for content a Quest app downloads packed with it (`make unzl`, tools/unzl.c).
fetch openzl https://github.com/facebook/openzl.git

# OpenVR's headers by version, for the games' runtime (core/halliday-vrclient follows v1.0.10):
# history without file contents; read one with `git -C reference/openvr show v1.0.10:headers/openvr.h`.
if [ -d reference/openvr/.git ]; then
	git -C reference/openvr fetch --tags
else
	git clone --filter=blob:none --no-checkout https://github.com/ValveSoftware/openvr.git reference/openvr
fi

# The Khronos OpenXR loader, for `make openxr-check` (needs cmake: brew install cmake).
if command -v cmake >/dev/null 2>&1; then
	cmake -S reference/openxr-sdk -B reference/openxr-sdk/build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF
	cmake --build reference/openxr-sdk/build -j 8
else
	echo "cmake not found: skipping the OpenXR loader build" >&2
fi
