# Halliday build. Plain swiftc + cargo: no Xcode project or SwiftPM needed, so the
# Command Line Tools are enough.

BUILD      := build
APP        := $(BUILD)/Halliday.app
CORE_LIB   := core/target/release/libhalliday_core.a
SWIFT_SRCS := $(wildcard app/Sources/Halliday/*.swift)
SWIFTFLAGS ?= -O
TARGET     := arm64-apple-macos14.0
# Sign with the local "Halliday Dev" identity when it exists (tools/create-signing-identity.sh), so
# macOS keeps Screen Recording/Accessibility permissions across builds; ad-hoc otherwise.
SIGN_ID    := $(shell security find-certificate -c "Halliday Dev" >/dev/null 2>&1 && echo "Halliday Dev" || echo "-")
# Paths under the builder's home folder (the Rust toolchain's and crates' sources, in panic
# messages) are written as ~ in what is built, so a release carries no one's user name. Not for
# the Windows DLL, whose own rustflags an environment RUSTFLAGS would replace (it has no paths).
REMAP      := RUSTFLAGS="--remap-path-prefix=$(HOME)=~" CFLAGS="-ffile-prefix-map=$(HOME)=~"
# C code built by Rust crates (vendored libusb) must target the same macOS as the app.
export MACOSX_DEPLOYMENT_TARGET := 14.0

.PHONY: all core app run open smoke test lint fmt clean openxr openxr-check openxr-metal-check klepton quest-libs unzl vrclient vrtest release dmg notarize appcast publish

all: app

core:
	$(REMAP) cargo build --release --manifest-path core/Cargo.toml

$(CORE_LIB): core

# Halliday's OpenVR runtime for Windows games under Wine (ROADMAP W14): a Windows DLL built here
# with Rust's own linker (needs: rustup target add x86_64-pc-windows-msvc). Bundled in the app,
# which installs it in Application Support/Halliday/OpenVR.
VRCLIENT      := $(BUILD)/vrclient_x64.dll
VRCLIENT_SRCS := $(wildcard core/halliday-vrclient/src/*.rs core/halliday-vrclient/src/iface/*.rs core/halliday-bridge/src/*.rs) core/halliday-vrclient/Cargo.toml core/halliday-vrclient/.cargo/config.toml

$(VRCLIENT): $(VRCLIENT_SRCS)
	@mkdir -p $(BUILD)
	@# A fresh Rust install lacks the Windows target: rustup adds it (once).
	@if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx x86_64-pc-windows-msvc; then \
		echo "adding Rust's Windows target (once), for the OpenVR runtime"; rustup target add x86_64-pc-windows-msvc; fi
	cd core/halliday-vrclient && cargo build --release
	cp core/halliday-vrclient/target/x86_64-pc-windows-msvc/release/halliday_vrclient.dll $@

vrclient: $(VRCLIENT)

# A stand-in Direct3D 11 VR game for testing the runtime under Wine (core/halliday-vrclient/vrtest).
vrtest:
	@mkdir -p $(BUILD)
	cd core/halliday-vrclient && cargo build --release -p halliday-vrtest
	cp core/halliday-vrclient/target/x86_64-pc-windows-msvc/release/vrtest.exe $(BUILD)/vrtest.exe

# Sparkle, the updater (opt-in update checks; Updates.swift), fetched pinned by tools/fetch-sparkle.sh.
SPARKLE := reference/sparkle/Sparkle.framework
$(SPARKLE): tools/fetch-sparkle.sh
	tools/fetch-sparkle.sh
	@touch $@

# The app finds Sparkle in its bundle's Frameworks; build/halliday run alone (make smoke, make run)
# in reference/sparkle.
$(BUILD)/halliday: $(SWIFT_SRCS) $(CORE_LIB) $(SPARKLE) core/halliday-core/include/halliday_core.h app/Sources/CHallidayCore/module.modulemap app/Sources/CVirtualDisplay/CGVirtualDisplay.h
	@mkdir -p $(BUILD)
	swiftc $(SWIFTFLAGS) -swift-version 6 -target $(TARGET) \
		-I app/Sources/CHallidayCore -I app/Sources/CVirtualDisplay -L core/target/release \
		-F reference/sparkle -framework Sparkle \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks -Xlinker -rpath -Xlinker @executable_path/../reference/sparkle \
		-framework AppKit -framework Metal -framework QuartzCore -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework ApplicationServices -framework WebKit -framework AVFoundation -framework CoreGraphics -framework IOKit -framework CoreFoundation -framework Security \
		$(SWIFT_SRCS) -o $@

$(APP): $(BUILD)/halliday $(VRCLIENT) LICENSE THIRD-PARTY.md tools/collect-licenses.sh app/Info.plist app/Resources/webxr-bridge.js app/Resources/video-finder.js app/Resources/AppIcon.icns app/Halliday-dev.entitlements docs/extensions.md $(wildcard extensions/example/*) $(wildcard app/Resources/fsr1/*) $(wildcard app/Resources/amd-optical-flow/*) $(wildcard app/Resources/spacewarp/*)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp app/Info.plist $(APP)/Contents/Info.plist
	cp app/Resources/webxr-bridge.js app/Resources/video-finder.js app/Resources/AppIcon.icns $(APP)/Contents/Resources/
	rm -rf $(APP)/Contents/Resources/fsr1 && cp -R app/Resources/fsr1 $(APP)/Contents/Resources/fsr1
	rm -rf $(APP)/Contents/Resources/amd-optical-flow $(APP)/Contents/Resources/spacewarp
	cp -R app/Resources/amd-optical-flow app/Resources/spacewarp $(APP)/Contents/Resources/
	@# The extensions guide and example, for the companion (docs/extensions.md).
	cp docs/extensions.md $(APP)/Contents/Resources/extensions.md
	rm -rf $(APP)/Contents/Resources/extension-example && cp -R extensions/example $(APP)/Contents/Resources/extension-example
	cp $(VRCLIENT) $(APP)/Contents/Resources/vrclient_x64.dll
	@# Quest apps' runtime (Klepton's runner, the OpenXR runtime, MoltenVK), when `make klepton` built it.
	if [ -d $(BUILD)/quest ]; then mkdir -p $(APP)/Contents/Resources/quest && cp -f $(BUILD)/quest/* $(APP)/Contents/Resources/quest/; fi
	@# The licences of everything the bundle carries (THIRD-PARTY.md says what each is).
	tools/collect-licenses.sh $(APP)/Contents/Resources/Licenses
	@# Sparkle, without its XPC services (only sandboxed apps need them), each part signed inside out.
	rm -rf $(APP)/Contents/Frameworks && mkdir -p $(APP)/Contents/Frameworks
	ditto --norsrc --noextattr $(SPARKLE) $(APP)/Contents/Frameworks/Sparkle.framework
	rm -rf $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices $(APP)/Contents/Frameworks/Sparkle.framework/XPCServices
	xattr -cr $(APP)/Contents/Frameworks/Sparkle.framework
	codesign --force --options runtime --sign "$(SIGN_ID)" $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
	codesign --force --options runtime --sign "$(SIGN_ID)" $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
	codesign --force --options runtime --sign "$(SIGN_ID)" $(APP)/Contents/Frameworks/Sparkle.framework
	cp $(BUILD)/halliday $(APP)/Contents/MacOS/halliday
	xattr -cr $(APP)
	codesign --force --options runtime --entitlements app/Halliday-dev.entitlements --sign "$(SIGN_ID)" $(APP)

app: $(APP)

run: $(BUILD)/halliday
	$(BUILD)/halliday $(ARGS)

# Launch the .app bundle so macOS attaches permissions (Screen Recording, Accessibility) to
# Halliday rather than to the terminal; the log is tailed until the app quits.
# With the PS VR2 connected Halliday opens on it, full screen, tracked, with the controllers'
# hand tracking on (ARGS="--no-hands" for without); with no headset, in a preview window on the
# Mac's screen. The Quest apps' runtime is in the bundle once `make klepton` has built it.
open: $(APP)
	@: > ~/Library/Logs/Halliday.log
	open -W -a "$(CURDIR)/$(APP)" --args $(ARGS) & OPEN=$$!; \
	tail -F ~/Library/Logs/Halliday.log & TAIL=$$!; \
	wait $$OPEN; kill $$TAIL

# Headless check of the built app: core through the C ABI, then one offscreen frame.
smoke: $(BUILD)/halliday
	$(BUILD)/halliday --probe
	$(BUILD)/halliday --snapshot $(BUILD)/snapshot.png
	test -s $(BUILD)/snapshot.png

# The OpenXR runtime (spike, ROADMAP W8): the library and its manifest side by side in
# build/openxr/. An OpenXR application finds it with XR_RUNTIME_JSON=build/openxr/halliday_openxr.json.
openxr:
	$(REMAP) cargo build --release --manifest-path core/Cargo.toml -p halliday-openxr
	mkdir -p $(BUILD)/openxr
	cp core/target/release/libhalliday_openxr.dylib $(BUILD)/openxr/
	printf '{\n    "file_format_version": "1.0.0",\n    "runtime": {\n        "name": "Halliday",\n        "library_path": "./libhalliday_openxr.dylib"\n    }\n}\n' > $(BUILD)/openxr/halliday_openxr.json

# The runtime through the real Khronos loader (reference/openxr-sdk, from tools/fetch-reference.sh).
XRSDK = reference/openxr-sdk
openxr-check: openxr
	@test -f $(XRSDK)/build/src/loader/libopenxr_loader.dylib || { echo "build the loader first: tools/fetch-reference.sh (needs cmake)"; exit 1; }
	clang -o $(BUILD)/openxr/openxr-check tools/openxr-check.c -I$(XRSDK)/include -I$(XRSDK)/build/include \
		-L$(XRSDK)/build/src/loader -lopenxr_loader -Wl,-rpath,$(CURDIR)/$(XRSDK)/build/src/loader
	XR_RUNTIME_JSON=$(CURDIR)/$(BUILD)/openxr/halliday_openxr.json $(BUILD)/openxr/openxr-check

# Quest apps (ROADMAP W15.3): Klepton's runner (reference/klepton-moltenvr, with Halliday's patch),
# Halliday's OpenXR runtime and MoltenVK, side by side in build/quest/, which the app bundle then
# carries. Needs tools/fetch-reference.sh and `brew install pkgconf sdl3 vulkan-headers molten-vk`.
KLEPTON = reference/klepton-moltenvr
klepton: openxr
	@test -d $(KLEPTON)/source || { echo "clone Klepton first: tools/fetch-reference.sh"; exit 1; }
	@cd $(KLEPTON) && if git apply --check $(CURDIR)/tools/klepton-halliday.patch 2>/dev/null; then git apply $(CURDIR)/tools/klepton-halliday.patch; fi
	@grep -q KL_OPENXR_RUNTIME $(KLEPTON)/source/runtime/gfx/kl_moltenvr.mm || { echo "tools/klepton-halliday.patch doesn't apply to this Klepton"; exit 1; }
	$(MAKE) -C $(KLEPTON)/source -f Makefile.moltenvr CC='xcrun clang' MVK_INC=-I$$(brew --prefix)/include build/openbrush-moltenvr-shared
	mkdir -p $(BUILD)/quest
	cp -f $(KLEPTON)/source/build/openbrush-moltenvr-shared $(BUILD)/quest/klepton-runner
	cp -f $(BUILD)/openxr/libhalliday_openxr.dylib $(BUILD)/quest/
	cp -fL $$(brew --prefix)/lib/libMoltenVK.dylib $(BUILD)/quest/
	$(MAKE) quest-libs

# The runner's libraries made to travel with it (a Mac without Homebrew): SDL3 copied beside it and
# found there, and no library named by a build or Homebrew folder.
SDL3_LIB = $$(brew --prefix)/opt/sdl3/lib/libSDL3.0.dylib
quest-libs:
	cp -fL $(SDL3_LIB) $(BUILD)/quest/libSDL3.0.dylib
	chmod u+w $(BUILD)/quest/libSDL3.0.dylib $(BUILD)/quest/libMoltenVK.dylib $(BUILD)/quest/libhalliday_openxr.dylib
	install_name_tool -id @executable_path/libSDL3.0.dylib $(BUILD)/quest/libSDL3.0.dylib
	install_name_tool -change $(SDL3_LIB) @executable_path/libSDL3.0.dylib $(BUILD)/quest/klepton-runner
	install_name_tool -id @rpath/libMoltenVK.dylib $(BUILD)/quest/libMoltenVK.dylib
	install_name_tool -id @rpath/libhalliday_openxr.dylib $(BUILD)/quest/libhalliday_openxr.dylib
	tools/check-bundled-libs.sh $(BUILD)/quest
	codesign --force --options runtime --sign "$(SIGN_ID)" $(BUILD)/quest/libSDL3.0.dylib $(BUILD)/quest/libMoltenVK.dylib $(BUILD)/quest/libhalliday_openxr.dylib
	codesign --force --options runtime --entitlements app/QuestRunner-dev.entitlements --sign "$(SIGN_ID)" $(BUILD)/quest/klepton-runner

# The unpacker for content a Quest app downloads packed (tools/unzl.c: OpenZL, Zstandard, xz): OpenZL
# (reference/openzl, from tools/fetch-reference.sh; its own Makefile fetches zstd and lz4) linked into
# one small tool in build/quest/, which the app bundle then carries.
OPENZL = reference/openzl
unzl:
	@test -f $(OPENZL)/Makefile || { echo "clone OpenZL first: tools/fetch-reference.sh"; exit 1; }
	$(MAKE) -C $(OPENZL) libopenzl.a
	mkdir -p $(BUILD)/quest
	clang -O2 -fblocks -o $(BUILD)/quest/unzl tools/unzl.c -I$(OPENZL)/include -I$(OPENZL)/deps/zstd/lib -lcompression \
		$(OPENZL)/libopenzl.a $(OPENZL)/deps/zstd/lib/libzstd.a $(OPENZL)/deps/lz4/lib/liblz4.a
	codesign --force --options runtime --sign "$(SIGN_ID)" $(BUILD)/quest/unzl

# A release (ROADMAP W18.6), from the app `make` built with the Quest runtime in it (`make klepton
# unzl` first): everything signed again with this Mac's "Developer ID Application" identity, hardened
# and timestamped, into build/release/Halliday.app (tools/release.sh). Then `make dmg`, then
# `make notarize` (with a notarytool keychain profile the person stored themselves: see the script).
release: app
	tools/release.sh

dmg:
	tools/make-dmg.sh

notarize:
	tools/notarize.sh

# Sparkle's update feed for the notarized DMG, signed with the releaser's key (tools/make-appcast.sh).
appcast:
	tools/make-appcast.sh

# The GitHub release with the DMG and the feed (tools/publish.sh): NOTES=FILE, the release's notes.
publish:
	@test -n "$(NOTES)" || { echo "make publish NOTES=FILE"; exit 1; }
	tools/publish.sh "$(NOTES)"

# A Metal session against the runtime: a pattern fixed to the room, both eyes, into Halliday (or
# `halliday-probe game-host`), which must be running. FRAMES=n for how long (120).
openxr-metal-check: openxr
	clang -fobjc-arc -o $(BUILD)/openxr/openxr-metal-check tools/openxr-metal-check.m -I$(XRSDK)/include -I$(XRSDK)/build/include \
		-I$(XRSDK)/src/loader -framework Metal -framework Foundation
	$(BUILD)/openxr/openxr-metal-check $(CURDIR)/$(BUILD)/openxr/libhalliday_openxr.dylib $(or $(FRAMES),120)

test:
	$(REMAP) cargo test --manifest-path core/Cargo.toml

# CrossOver integration and the separate Windows OpenXR preview. All fixture tests are
# hardware-independent; Wine smoke tests use disposable bottles and are invoked separately.
.PHONY: crossover-check windows-openxr windows-openxr-check windows-openxr-router independent-native-openxr native-alyx native-alyx-frame-bridge vr-modules vr-package crossover-preview
crossover-check:
	tools/test-crossover-library.sh
	tools/check-openvr-registration.sh
	tools/check-windows-openxr-registration.sh
	tools/test-crossover-launcher.sh

windows-openxr:
	python3 windows-openxr/build.py windows --jobs $(VR_JOBS)
	tools/build-windows-openxr-registry.sh

windows-openxr-check:
	python3 windows-openxr/build.py native --jobs $(VR_JOBS)

windows-openxr-router:
	python3 windows-openxr/router/build.py
	python3 windows-openxr/router/build_openvr.py

independent-native-openxr:
	tools/build-independent-native-openxr.sh

native-alyx:
	python3 native-alyx/build.py

# The coherent native reader is optional and only needs a public Vulkan SDK/library.
# Example: make native-alyx-frame-bridge MOLTENVK_LIBRARY=/path/libMoltenVK.dylib VULKAN_INCLUDE=/path/include
native-alyx-frame-bridge:
	@test -n "$(MOLTENVK_LIBRARY)" || { echo "Set MOLTENVK_LIBRARY to a public SDK libMoltenVK.dylib"; exit 2; }
	native-alyx/build-frame-bridge.sh --moltenvk-library "$(MOLTENVK_LIBRARY)" $(if $(VULKAN_INCLUDE),--vulkan-include "$(VULKAN_INCLUDE)")

# Optional source-built desktop game modules. Ordinary make app does not need these
# Windows/Rust targets or any game, headset, installed runtime or private cache.
vr-modules: windows-openxr windows-openxr-router independent-native-openxr native-alyx

vr-package: app vr-modules
	HALLIDAY_PACKAGE_WINDOWS=yes HALLIDAY_PACKAGE_ROUTER=yes HALLIDAY_PACKAGE_NATIVE=yes tools/package-crossover-preview.sh

# Explicit local development identity, isolated from the ordinary app and its updater.
crossover-preview: app vr-modules
	HALLIDAY_PACKAGE_DEVELOPMENT=1 HALLIDAY_PACKAGE_WINDOWS=yes HALLIDAY_PACKAGE_ROUTER=yes HALLIDAY_PACKAGE_NATIVE=yes tools/package-crossover-preview.sh

lint:
	tools/check-privacy.sh
	cargo fmt --all --manifest-path core/Cargo.toml --check
	$(REMAP) cargo clippy --manifest-path core/Cargo.toml --all-targets -- -D warnings
	cargo fmt --all --manifest-path core/halliday-vrclient/Cargo.toml --check
	cd core/halliday-vrclient && cargo clippy --release --workspace -- -D warnings
	if [ -d reference/openvr ]; then tools/gen-openvr-tables.py --check; fi

fmt:
	cargo fmt --all --manifest-path core/Cargo.toml
	cargo fmt --all --manifest-path core/halliday-vrclient/Cargo.toml

clean:
	cargo clean --manifest-path core/Cargo.toml
	cargo clean --manifest-path core/halliday-vrclient/Cargo.toml
	rm -rf $(BUILD)

VR_JOBS ?= 2
.PHONY: windows-bridge-check windows-haptic-feed-check
windows-bridge-check:
	cargo test --manifest-path core/Cargo.toml --jobs $(VR_JOBS) -p halliday-bridge
	cargo test --manifest-path core/Cargo.toml --jobs $(VR_JOBS) -p halliday-core --no-default-features --lib game_bridge
	cargo test --manifest-path core/Cargo.toml --jobs $(VR_JOBS) -p halliday-core --no-default-features --lib bridge_haptics
	cargo test --manifest-path core/Cargo.toml --jobs $(VR_JOBS) -p halliday-core --no-default-features --lib game_haptics
	cargo test --manifest-path core/Cargo.toml --jobs $(VR_JOBS) -p halliday-core --no-default-features --lib tracking::head
	cargo test --manifest-path core/Cargo.toml --jobs $(VR_JOBS) -p halliday-core --no-default-features --lib ffi::tests
	bash tools/test-game-bridge-lease.sh
	bash tools/test-game-producer-state.sh
	bash tools/test-game-producer-watchdog.sh

# CPU-only end-to-end fixture: C++ producer -> Rust bridge -> Swift callbacks.
windows-haptic-feed-check:
	cargo build --manifest-path core/Cargo.toml --jobs $(VR_JOBS) -p halliday-core --no-default-features --release
	bash tools/test-independent-haptic-feed.sh

# Synthetic PCM and settings only: no capture, output device, TCC, or app launch.
.PHONY: system-game-audio-check
system-game-audio-check:
	bash tools/test-system-game-audio.sh
	bash tools/test-system-game-audio-settings.sh

# CPU-only feature checks. GPU fixtures are explicit separate tools.
.PHONY: spacewarp-check
spacewarp-check:
	bash tools/test-game-spacewarp-cadence.sh
	bash tools/test-game-spacewarp-settings.sh
	python3 tools/test-amd-optical-flow-provenance.py

# Pure ownership/clock-policy checks; no app, GPU, display or headset is started.
.PHONY: compositor-check
compositor-check:
	bash tools/test-independent-compositor.sh
