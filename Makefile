# Lerping@Home — Metal shader screensaver for macOS.
# Plain swiftc build, no Xcode project. `make saver` puts it in
# ~/Library/Screen Savers; select "Lerping@Home" in System Settings > Screen Saver.

BUILD      := build
TARGET     := arm64-apple-macos14.0
SDK        := $(shell xcrun --show-sdk-path --sdk macosx)
CORE       := $(wildcard Sources/LerpCore/*.swift)
SAVER_SRC  := Sources/Saver/LerpSaverView.swift
PREVIEW    := $(wildcard Sources/Preview/*.swift)
PLAYGROUND := $(wildcard Sources/Playground/*.swift)
SHADERS    := $(wildcard Sources/Shaders/*.metal)
FRAMEWORKS := -framework AppKit -framework Metal -framework QuartzCore \
              -framework CoreGraphics -framework ImageIO
# The playground alone also links ScreenSaver, for one class: the rotation
# gallery writes the screensaver's ByHost domain through ScreenSaverDefaults.
# The sandboxed saver reads that same file directly when Apple's host redirects
# ScreenSaverDefaults into its own container. Not added to FRAMEWORKS: the
# preview app and the snapshot renderer still link nothing they do not use.
PLAYGROUND_FW := $(FRAMEWORKS) -framework ScreenSaver
SAVER_DIR  := $(BUILD)/Lerping@Home.saver
CUSTOM_DIR := $(HOME)/Library/Application Support/Lerping/Shaders
INSTALLED  := $(HOME)/Library/Screen Savers/Lerping@Home.saver

# The playground is a real .app, assembled the same way as the .saver above.
# A bundle is not decoration: the identifier in its Info.plist is what macOS
# deduplicates launches against, what `open -a` resolves, and what gives it a
# Dock tile and a ⌘-Tab entry. As a bare executable it had none of that, so
# every run started another copy with another window.
PLAYGROUND_APP       := $(BUILD)/LerpPlayground.staging.app
PLAYGROUND_BIN       := $(PLAYGROUND_APP)/Contents/MacOS/LerpPlayground
PLAYGROUND_ICNS      := $(BUILD)/LerpPlayground.icns
PLAYGROUND_BUILD_ID         := com.hergenroeder.lerping.playground.build
PLAYGROUND_LEGACY_BUILD_ID  := com.hergenroeder.lerping.playground
LEGACY_PLAYGROUND_APP       := $(BUILD)/LerpPlayground.app
BUNDLE_VERSION      := $(shell date +%Y%m%d%H%M%S)

# Shortcuts / Spotlight actions (Sources/Playground/RotationIntents.swift).
#
# App Intents are declared in Swift but discovered from a build product:
# `Contents/Resources/Metadata.appintents`, which Xcode makes by running
# `appintentsmetadataprocessor` over the compiler's constant-value dump. There
# is no Xcode project here, so the playground rule does those steps itself:
#
# - `-emit-const-values-path`, with the protocol list below, makes swiftc write
#   the literal titles, phrases and parameters of every conforming type. It is
#   only emitted for a whole-module build, hence `-wmo`.
# - `-dependency_info` is the linker's record of what it linked. The processor
#   reads it to confirm AppIntents.framework is a dependency and does nothing
#   without it.
# - The processor then writes Metadata.appintents into the bundle, before the
#   bundle is signed. The metadata holds no bundle identifier, so the staging,
#   installed and release identifiers all share it.
#
# The protocol list is Xcode's own `SWIFT_EMIT_CONST_VALUE_PROTOCOLS` default.
# The processor ships with Xcode, not the command line tools; without it the
# app still builds and runs, it just has no Shortcuts actions, and the rule
# says so.
INTENTS_DIR          := $(BUILD)/playground-intents
APPINTENTS_PROTOCOLS := AppIntent EntityQuery AppEntity TransientEntity AppEnum \
                        AppShortcutProviding AppShortcutsProvider AnyResolverProviding \
                        AppIntentsPackage DynamicOptionsProvider _IntentValueRepresentable \
                        _AssistantIntentsProvider _GenerativeFunctionExtractable \
                        IntentValueQuery Resolver
define EXTRACT_APPINTENTS
	@set -e; \
	if ! processor="$$(xcrun --find appintentsmetadataprocessor 2>/dev/null)"; then \
		echo "playground: appintentsmetadataprocessor not found (it ships with Xcode, not the"; \
		echo "  command line tools). Built without Shortcuts actions."; \
		exit 0; \
	fi; \
	swiftc="$$(xcrun --find swiftc)"; \
	toolchain="$${swiftc%/usr/bin/swiftc}"; \
	xcode="$$(/usr/libexec/PlistBuddy -c 'Print ProductBuildVersion' \
		"$$(xcode-select -p)/../version.plist" 2>/dev/null || echo unknown)"; \
	printf '%s\n' $(abspath $(CORE) $(PLAYGROUND)) > $(INTENTS_DIR)/sources.txt; \
	printf '%s\n' $(abspath $(INTENTS_DIR)/LerpPlayground.swiftconstvalues) > $(INTENTS_DIR)/constvalues.txt; \
	rm -rf $(PLAYGROUND_APP)/Contents/Resources/Metadata.appintents; \
	"$$processor" --toolchain-dir "$$toolchain" --module-name LerpPlayground \
		--sdk-root $(SDK) --xcode-version "$$xcode" --platform-family macOS \
		--deployment-target $(patsubst arm64-apple-macos%,%,$(TARGET)) --target-triple $(TARGET) \
		--bundle-identifier $(PLAYGROUND_BUILD_ID) \
		--output $(PLAYGROUND_APP)/Contents/Resources \
		--binary-file $(PLAYGROUND_BIN) \
		--dependency-file $(INTENTS_DIR)/LerpPlayground_dependency_info.dat \
		--stringsdata-file $(INTENTS_DIR)/ExtractedAppShortcutsMetadata.stringsdata \
		--source-file-list $(INTENTS_DIR)/sources.txt \
		--swift-const-vals-list $(INTENTS_DIR)/constvalues.txt \
		--compile-time-extraction --deployment-aware-processing \
		--no-app-shortcuts-localization \
		2>&1 | grep -v -e 'Starting App Intents metadata extraction' -e 'Metadata root:' || true; \
	test -f $(PLAYGROUND_APP)/Contents/Resources/Metadata.appintents/extract.actionsdata || { \
		echo "playground: appintentsmetadataprocessor produced no Metadata.appintents"; exit 1; }
endef

# Which commit each bundle was built from, stamped into its Info.plist as
# `LerpBuild` and logged by the running saver on every init.
#
# This replaces a SHA-256 of every source file, which existed to feed `make
# doctor` — a target that compared the digest in the installed bundle against
# the working tree and printed "up to date". It printed exactly that while the
# bug it was built to catch was reproducing, because "these bytes match those
# bytes" was never the question in doubt. It made staleness *look* answered, so
# the actual question — which look did the saver put on screen, and was it in
# the rotation — went unasked for three rounds.
#
# What is left is a label, and it does not pretend to be a verdict. `--dirty`
# is what makes it honest about uncommitted edits; the answer to "is the
# installed bundle current?" is now `make saver`, which takes about eight
# seconds and is a shorter path than asking.
LERP_BUILD := $(shell git describe --always --dirty --abbrev=8 2>/dev/null || echo unknown)
LS_SUPPORT      := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support
LSREGISTER      := $(LS_SUPPORT)/lsregister

# `make install-playground` — the copy Spotlight will actually offer.
#
# Spotlight indexes the bundle in build/ and types it correctly, and `open -a
# LerpPlayground` finds it, but its Applications category only ever surfaces
# /Applications, /System/Applications and ~/Applications. Typing "lerp" into
# Spotlight therefore returned nothing. A symlink does not help — Spotlight
# resolves it and indexes the app at its real path — so the bundle is copied.
PLAYGROUND_INSTALL_DIR ?= $(HOME)/Applications
INSTALLED_PLAYGROUND   := $(PLAYGROUND_INSTALL_DIR)/LerpPlayground.app
# The checkout the installed copy edits, recorded in its Info.plist at install
# time.
#
# Deliberately NOT $(CURDIR). In a git worktree that is the worktree — a
# directory that exists for the length of one branch — so recording it installs
# an app that breaks the moment the worktree is removed, which is precisely the
# failure the recorded path exists to avoid. `--git-common-dir` belongs to the
# *main* working tree whatever tree you are standing in, so its parent is the
# checkout that outlives this one. Outside a git repo there is nothing to derive
# and $(CURDIR) is the only answer left.
#
# Derived rather than refused-on-worktree because building on a branch and
# installing for daily use is a reasonable thing to do, and the right target is
# never ambiguous. Anything this gets wrong — a $GIT_DIR somewhere unusual, a
# checkout that is not one — is caught before a single file is copied, by the
# guard at the top of `install-playground`, which says so and stops rather than
# baking a path that does not work.
PLAYGROUND_GIT_DIR     := $(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
PLAYGROUND_REPO        ?= $(if $(PLAYGROUND_GIT_DIR),$(patsubst %/.git,%,$(PLAYGROUND_GIT_DIR)),$(CURDIR))
# The canonical installed app's identifier. The staging bundle keeps a separate
# one solely so it can never be mistaken for the app normal commands launch.
# Overridable for an intentionally separate installed copy.
INSTALLED_PLAYGROUND_ID ?= com.hergenroeder.lerping.playground.installed

# The playground's MIDI support, and the only third-party code in the project.
# `Sources/MIDIDeps` is a SwiftPM shim around orchetect/swift-midi's I/O module
# that emits a static archive plus a directory of .swiftmodule files, which is
# all plain swiftc needs. `swift build` ships in the Xcode command line tools
# the README already requires, so this adds no toolchain.
#
# These flags are appended to the LerpPlayground rule ONLY. The screensaver, the
# preview app and the snapshot renderer link nothing but system frameworks, and
# `make all` never invokes swift build.
MIDI_PKG   := Sources/MIDIDeps
# SwiftPM 6.4 moved build products from .build/<config>/ to
# .build/out/Products/<config>/, and the .swiftmodule files now sit beside
# the archive instead of in a Modules/ subdirectory.
MIDI_BIN   := $(MIDI_PKG)/.build/out/Products/Release
MIDI_LIB   := $(MIDI_BIN)/libMIDIDeps.a
MIDI_SRC   := $(MIDI_PKG)/Package.swift $(wildcard $(MIDI_PKG)/Sources/MIDIDeps/*.swift)
# CoreMIDI.framework comes in through Swift autolink metadata; no -framework needed.
MIDI_FLAGS := -I $(MIDI_BIN) -L $(MIDI_BIN) -lMIDIDeps
# The toolchain stamp lives in build/, not in .build/: SwiftPM cleans unknown
# products dirs (it removed the legacy .build/release/ tree outright), which
# would otherwise read as "toolchain changed" on every invocation.
MIDI_SWIFT_STAMP := $(BUILD)/midi-swift-version.stamp

# Shader › MIDI › Control with Hands (Sources/Playground/HandControl.swift). The page
# and coding cube's tracking code are in Sources/Playground/Hands; MediaPipe's
# web runtime and its hand model are third-party and 18 MB, so like the splats
# they are downloaded once into build/, checked against a pinned sha256, and
# copied into the bundle — never stored in git. 0.10.35 is the version coding
# cube's hand control ran on. Only the SIMD module build of the wasm is kept:
# that is the one MediaPipe's loader picks in WebKit, which has had wasm SIMD
# since Safari 16.4.
HANDS_SRC          := $(shell find Sources/Playground/Hands -type f ! -name .DS_Store)
MEDIAPIPE          := $(BUILD)/mediapipe
MEDIAPIPE_STAMP    := $(MEDIAPIPE)/.stamp
MEDIAPIPE_VERSION  := 0.10.35
MEDIAPIPE_TGZ      := https://registry.npmjs.org/@mediapipe/tasks-vision/-/tasks-vision-$(MEDIAPIPE_VERSION).tgz
MEDIAPIPE_TGZ_SHA  := 84597a25e13d123b5f4cbe768bb72e97a2c28c7a465f0ace287d8cbe5246bff0
HAND_MODEL         := https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task
HAND_MODEL_SHA     := fbc2a30080c3c557093b5ddfc334698132eb341044ccee322ccf8bcf3607cde1
# $(call FETCH,url,sha256,dest): download, refuse anything but the pinned bytes.
define FETCH
	curl -fsSL --retry 3 -o "$(3).part" "$(1)"
	@echo "$(2)  $(3).part" | shasum -a 256 -c --status || { \
		echo "$(1): sha256 is not the pinned $(2)"; rm -f "$(3).part"; exit 1; }
	mv "$(3).part" "$(3)"
endef

# Public installer. The PKG supplies Installer's optional Playground checkbox;
# the DMG is the downloadable release container. `release` signs and notarizes
# both so the nested installer also works when its ticket must be checked offline.
RELEASE_VERSION            ?= 0.1.0
RELEASE_BUILD              ?= $(shell git rev-list --count HEAD)
APP_SIGN_IDENTITY          ?= -
INSTALLER_SIGN_IDENTITY    ?=
NOTARY_PROFILE             ?=
RELEASE_DIR                 = $(BUILD)/release
RELEASE_PACKAGE             = $(RELEASE_DIR)/LerpingAtHome-$(RELEASE_VERSION)-arm64.pkg
RELEASE_DMG                 = $(RELEASE_DIR)/LerpingAtHome-$(RELEASE_VERSION)-arm64.dmg
RELEASE_DMG_ROOT            = $(RELEASE_DIR)/dmg-root
RELEASE_SAVER_ROOT          = $(RELEASE_DIR)/saver-root
RELEASE_PLAYGROUND_ROOT     = $(RELEASE_DIR)/playground-root
RELEASE_SAVER               = $(RELEASE_SAVER_ROOT)/Library/Screen Savers/Lerping@Home.saver
RELEASE_PLAYGROUND          = $(RELEASE_PLAYGROUND_ROOT)/Applications/LerpPlayground.app
RELEASE_COMPONENTS          = $(RELEASE_DIR)/components
RELEASE_RESOURCES           = $(RELEASE_DIR)/resources

define STAGE_DMG
	rm -rf "$(RELEASE_DMG_ROOT)" "$(RELEASE_DMG)"
	mkdir -p "$(RELEASE_DMG_ROOT)"
	cp "$(RELEASE_PACKAGE)" "$(RELEASE_DMG_ROOT)/Install Lerping@Home.pkg"
	hdiutil create -quiet -ov -format UDZO -volname "Lerping@Home $(RELEASE_VERSION)" \
		-srcfolder "$(RELEASE_DMG_ROOT)" "$(RELEASE_DMG)"
endef

.PHONY: splats all preview playground playground-build saver saver-build midi-deps \
        verify-rotation pulse uninstall-pulse \
        install install-example install-playground uninstall-playground package dmg release clean \
        FORCE

# Did the screensaver put a switched-off look on screen? Asked of the unified
# log of real sessions, not of a fixture. See the header of the script for why
# this replaced `make doctor`.
verify-rotation:
	@scripts/verify-rotation.py $(if $(DAYS),--days $(DAYS))

# Normal targets deploy. The explicitly named *-build targets are the only
# compile-only escape hatch, so "it built" cannot be mistaken for "it runs".
all: saver preview

preview: $(BUILD)/LerpPreview

$(BUILD)/LerpPreview: $(CORE) $(PREVIEW)
	@mkdir -p $(BUILD)
	swiftc -O -parse-as-library -target $(TARGET) \
		-o $@ $(CORE) $(PREVIEW) $(FRAMEWORKS)

# Live shader playground: source editor + hot-reloading Metal view.
# The build-tree bundle is staging only. The normal target installs it, asks any
# older copy to quit through the app's Save / Discard / Cancel path, and opens
# the one canonical copy in ~/Applications.
playground: install-playground
	open -a "$(INSTALLED_PLAYGROUND)"

playground-build: $(PLAYGROUND_BIN)

$(PLAYGROUND_BIN): $(CORE) $(PLAYGROUND) $(MIDI_LIB) $(PLAYGROUND_ICNS) Sources/Playground/Info.plist LICENSE NOTICE.txt \
                   $(HANDS_SRC) $(MEDIAPIPE_STAMP)
	@$(LSREGISTER) -u $(LEGACY_PLAYGROUND_APP) 2>/dev/null || true
	rm -rf $(LEGACY_PLAYGROUND_APP)
	@mkdir -p $(PLAYGROUND_APP)/Contents/MacOS $(PLAYGROUND_APP)/Contents/Resources $(INTENTS_DIR)
	@printf '%s\n' $(APPINTENTS_PROTOCOLS) | sed 's/.*/"&"/' | paste -sd, - | sed 's/.*/[&]/' \
		> $(INTENTS_DIR)/protocols.json
	swiftc -O -wmo -parse-as-library -target $(TARGET) -module-name LerpPlayground \
		-emit-const-values-path $(INTENTS_DIR)/LerpPlayground.swiftconstvalues \
		-Xfrontend -const-gather-protocols-file -Xfrontend $(INTENTS_DIR)/protocols.json \
		-Xlinker -dependency_info -Xlinker $(INTENTS_DIR)/LerpPlayground_dependency_info.dat \
		-o $@ $(CORE) $(PLAYGROUND) $(PLAYGROUND_FW) $(MIDI_FLAGS)
	$(EXTRACT_APPINTENTS)
	cp Sources/Playground/Info.plist $(PLAYGROUND_APP)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string $(PLAYGROUND_BUILD_ID) $(PLAYGROUND_APP)/Contents/Info.plist
	plutil -replace CFBundleName -string LerpPlaygroundStaging $(PLAYGROUND_APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $(BUNDLE_VERSION) $(PLAYGROUND_APP)/Contents/Info.plist
	plutil -replace LerpBuild -string $(LERP_BUILD) $(PLAYGROUND_APP)/Contents/Info.plist
	cp $(PLAYGROUND_ICNS) $(PLAYGROUND_APP)/Contents/Resources/LerpPlayground.icns
	cp LICENSE NOTICE.txt $(PLAYGROUND_APP)/Contents/Resources/
	rm -rf $(PLAYGROUND_APP)/Contents/Resources/Hands
	cp -R Sources/Playground/Hands $(PLAYGROUND_APP)/Contents/Resources/Hands
	cp -R $(MEDIAPIPE)/vendor $(MEDIAPIPE)/models $(PLAYGROUND_APP)/Contents/Resources/Hands/
	codesign --force -s - $(PLAYGROUND_APP)

# Rebuilt when the pins change, which is the only time the bytes can.
MEDIAPIPE_PINS := $(MEDIAPIPE_TGZ_SHA)$(HAND_MODEL_SHA)
$(MEDIAPIPE_STAMP): $(if $(filter $(MEDIAPIPE_PINS),$(shell cat $(MEDIAPIPE_STAMP) 2>/dev/null)),,FORCE)
	rm -rf $(MEDIAPIPE)
	@mkdir -p $(MEDIAPIPE)/vendor/mediapipe/wasm $(MEDIAPIPE)/models $(MEDIAPIPE)/npm
	$(call FETCH,$(MEDIAPIPE_TGZ),$(MEDIAPIPE_TGZ_SHA),$(MEDIAPIPE)/tasks-vision.tgz)
	$(call FETCH,$(HAND_MODEL),$(HAND_MODEL_SHA),$(MEDIAPIPE)/models/hand_landmarker.task)
	tar -xzf $(MEDIAPIPE)/tasks-vision.tgz -C $(MEDIAPIPE)/npm \
		package/vision_bundle.mjs \
		package/wasm/vision_wasm_module_internal.js package/wasm/vision_wasm_module_internal.wasm
	mv $(MEDIAPIPE)/npm/package/vision_bundle.mjs $(MEDIAPIPE)/vendor/mediapipe/
	mv $(MEDIAPIPE)/npm/package/wasm/* $(MEDIAPIPE)/vendor/mediapipe/wasm/
	rm -rf $(MEDIAPIPE)/npm $(MEDIAPIPE)/tasks-vision.tgz
	@echo '$(MEDIAPIPE_PINS)' > $@

# The app icon, rendered from the same mesh-gradient shader that makes the
# saver's System Settings thumbnail. No binary art in the repo, and `make
# clean && make playground-build` reproduces it exactly.
ICON_SIZES := 16 32 64 128 256 512 1024

$(PLAYGROUND_ICNS): $(BUILD)/LerpPreview Sources/Shaders/mesh-gradient.metal
	@rm -rf $(BUILD)/icon.iconset $(BUILD)/icon-src
	@mkdir -p $(BUILD)/icon.iconset
	@for size in $(ICON_SIZES); do \
		$(BUILD)/LerpPreview --snapshot $(BUILD)/icon-src/$$size --size $${size}x$${size} \
			--time 4 --shader mesh-gradient >/dev/null || exit 1; \
	done
	@set -e; for pair in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 \
	                     256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do \
		cp $(BUILD)/icon-src/$${pair%%:*}/mesh-gradient.png \
		   $(BUILD)/icon.iconset/icon_$${pair##*:}.png; \
	done
	iconutil -c icns -o $@ $(BUILD)/icon.iconset

# Photoreal Gaussian splat captures (Sources/Splats/captures.json). The source
# files are third-party and large, so they are not in git: `splats` downloads
# each one's SOG files once into build/splats-src and converts them to the
# compact .lsplat that SplatData.swift reads, plus a .path.json for each scene
# whose author drew a camera path. Re-running is a no-op unless
# captures.json or the converter changed. Needs network the first time.
SPLAT_OUT := $(BUILD)/splats
SPLAT_STAMP := $(SPLAT_OUT)/.stamp

splats: $(SPLAT_STAMP)

$(SPLAT_STAMP): Sources/Splats/captures.json scripts/splat-convert.py
	python3 -I scripts/splat-convert.py all
	@touch $@

# `saver` means the saver the machine will actually run. Use `saver-build` only
# when a staging bundle is explicitly wanted.
saver: install pulse

# LerpPulse: the LaunchAgent that keeps the `critter` look's ledger — once a
# minute, is anyone at the keyboard and what kind of app is in front, folded
# into per-day totals (Sources/LerpCore/CritterLedger.swift). Part of `saver`
# because the critter has nothing to live on without it. It needs no privacy
# permission and writes one file:
#   ~/Library/Application Support/Lerping/Critter/ledger.json
PULSE_SRC   := Sources/LerpCore/CritterLedger.swift $(wildcard Sources/Pulse/*.swift)
PULSE_LABEL := com.hergenroeder.lerping.pulse
PULSE_DIR   := $(HOME)/Library/Application Support/Lerping/Pulse
PULSE_BIN   := $(PULSE_DIR)/LerpPulse
PULSE_PLIST := $(HOME)/Library/LaunchAgents/$(PULSE_LABEL).plist

$(BUILD)/LerpPulse: $(PULSE_SRC)
	@mkdir -p $(BUILD)
	swiftc -O -parse-as-library -target $(TARGET) -o $@ $(PULSE_SRC) \
		-framework AppKit -framework IOKit -framework CoreAudio

# The new binary is copied and signed beside the old one and renamed over it:
# `bootout` returns before the old job has exited, and rewriting the running
# file in place under KeepAlive can get the relaunch killed for an invalid code
# signature. A rename swaps the whole file at once.
pulse: $(BUILD)/LerpPulse
	@mkdir -p "$(PULSE_DIR)" "$(HOME)/Library/LaunchAgents"
	cp $(BUILD)/LerpPulse "$(PULSE_BIN).new"
	codesign --force -s - --identifier $(PULSE_LABEL) "$(PULSE_BIN).new"
	@launchctl bootout gui/$$(id -u)/$(PULSE_LABEL) 2>/dev/null || true
	mv -f "$(PULSE_BIN).new" "$(PULSE_BIN)"
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'<key>Label</key><string>$(PULSE_LABEL)</string>' \
		'<key>ProgramArguments</key><array><string>$(PULSE_BIN)</string></array>' \
		'<key>RunAtLoad</key><true/>' \
		'<key>KeepAlive</key><true/>' \
		'<key>ProcessType</key><string>Background</string>' \
		'<key>LimitLoadToSessionType</key><string>Aqua</string>' \
		'</dict></plist>' > "$(PULSE_PLIST)"
	@plutil -lint -s "$(PULSE_PLIST)"
	@# bootout returns before the old job is gone; bootstrap until it takes.
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		launchctl bootstrap gui/$$(id -u) "$(PULSE_PLIST)" 2>/dev/null && break; sleep 0.5; done
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		launchctl print gui/$$(id -u)/$(PULSE_LABEL) 2>/dev/null | grep -q 'state = running' && break; sleep 0.5; done
	@launchctl print gui/$$(id -u)/$(PULSE_LABEL) | grep -q 'state = running' \
		|| { echo "pulse: $(PULSE_LABEL) is not running"; exit 1; }
	@codesign --verify --strict "$(PULSE_BIN)"
	@sleep 1; "$(PULSE_BIN)" --report

# Stops the sampler. The ledger stays, so the critter is where you left it.
uninstall-pulse:
	@launchctl bootout gui/$$(id -u)/$(PULSE_LABEL) 2>/dev/null || true
	rm -f "$(PULSE_PLIST)" "$(PULSE_BIN)" "$(PULSE_BIN).new"

saver-build: $(BUILD)/LerpPreview $(CORE) $(SAVER_SRC) $(SHADERS) Sources/Saver/Info.plist LICENSE NOTICE.txt splats
	@mkdir -p $(SAVER_DIR)/Contents/MacOS $(SAVER_DIR)/Contents/Resources/Shaders $(SAVER_DIR)/Contents/Resources/Splats
	swiftc -O -whole-module-optimization -parse-as-library -emit-object \
		-target $(TARGET) -module-name LerpSaver \
		-o $(BUILD)/LerpSaver.o $(CORE) $(SAVER_SRC)
	clang -bundle -target $(TARGET) -isysroot $(SDK) \
		-o $(SAVER_DIR)/Contents/MacOS/LerpSaver $(BUILD)/LerpSaver.o \
		-framework ScreenSaver $(FRAMEWORKS) \
		-L$(SDK)/usr/lib/swift -L/usr/lib/swift \
		-Xlinker -rpath -Xlinker /usr/lib/swift
	cp Sources/Saver/Info.plist $(SAVER_DIR)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $(BUNDLE_VERSION) $(SAVER_DIR)/Contents/Info.plist
	plutil -replace LerpBuild -string $(LERP_BUILD) $(SAVER_DIR)/Contents/Info.plist
	# Cleared first, like Splats below: `cp` only adds, so a shader deleted or
	# merged away in the source kept shipping from build/ and kept playing.
	# The topologica-*/multiverse-* families were merged into one shader each,
	# and their old files went on reaching the screen as 27 extra looks.
	rm -f $(SAVER_DIR)/Contents/Resources/Shaders/*.metal
	cp $(SHADERS) $(SAVER_DIR)/Contents/Resources/Shaders/
	rm -f $(SAVER_DIR)/Contents/Resources/Splats/*.lsplat $(SAVER_DIR)/Contents/Resources/Splats/*.path.json
	cp $(SPLAT_OUT)/*.lsplat $(SPLAT_OUT)/*.path.json $(SAVER_DIR)/Contents/Resources/Splats/
	cp LICENSE NOTICE.txt $(SAVER_DIR)/Contents/Resources/
	$(BUILD)/LerpPreview --snapshot $(BUILD)/thumb --size 180x116 --time 4 \
		--shader mesh-gradient >/dev/null
	cp $(BUILD)/thumb/mesh-gradient.png $(SAVER_DIR)/Contents/Resources/thumbnail@2x.png
	$(BUILD)/LerpPreview --snapshot $(BUILD)/thumb1x --size 90x58 --time 4 \
		--shader mesh-gradient >/dev/null
	cp $(BUILD)/thumb1x/mesh-gradient.png $(SAVER_DIR)/Contents/Resources/thumbnail.png
	$(BUILD)/LerpPreview --thumbnails $(SAVER_DIR)
	codesign --force -s - $(SAVER_DIR)

install: saver-build
	mkdir -p "$(HOME)/Library/Screen Savers" "$(CUSTOM_DIR)"
	# A loaded bundle stays mapped after its files are replaced. Kill the disposable
	# Apple host before and after the swap so no old code survives deployment.
	@pkill -9 -x legacyScreenSaver 2>/dev/null || true
	rm -rf "$(INSTALLED)"
	cp -R $(SAVER_DIR) "$(INSTALLED)"
	# Bake custom shaders into the local bundle too. The host can read the
	# Application Support folder, but bundling gives each custom look a prepared
	# gallery still and makes this installed copy self-contained.
	@sh -c 'ls "$(CUSTOM_DIR)"/*.metal >/dev/null 2>&1 && cp "$(CUSTOM_DIR)"/*.metal "$(INSTALLED)/Contents/Resources/Shaders/" && echo "Baked in: $$(ls "$(CUSTOM_DIR)" | tr "\\n" " ")" || true'
	# …and now the Options… gallery's stills, over the installed bundle rather
	# than over build/, so a custom shader that was just baked in gets a tile
	# like every other look. Reads that bundle's own Shaders directory, so this
	# is the one place the two can never disagree.
	$(BUILD)/LerpPreview --thumbnails "$(INSTALLED)"
	# Stamp the revision here, not in the build rule. That rule is a file
	# target, so make skips it whenever the binary is already newer than its
	# prerequisites — and then this target cheerfully installs a bundle
	# labelled with whatever commit last happened to recompile Swift.
	plutil -replace LerpBuild -string $(LERP_BUILD) "$(INSTALLED)/Contents/Info.plist"
	codesign --force -s - "$(INSTALLED)"
	@pkill -9 -x legacyScreenSaver 2>/dev/null || true
	@! pgrep -x legacyScreenSaver >/dev/null
	# Against the tree, not against staging. Staging and installed are a copy of
	# each other and agree however wrong they both are — that is the same shape
	# of check as the deleted doctor, and it passed for the same reason.
	@test "$$(plutil -extract LerpBuild raw "$(INSTALLED)/Contents/Info.plist")" = "$(LERP_BUILD)" \
		|| { echo "install: installed bundle says $$(plutil -extract LerpBuild raw "$(INSTALLED)/Contents/Info.plist"), tree is $(LERP_BUILD)"; exit 1; }
	@codesign --verify --deep --strict "$(INSTALLED)"
	@echo ""
	@echo "Installed. Select 'Lerping@Home' in System Settings > Screen Saver."
	@echo "Custom shaders: put .metal files in"
	@echo "  $(CUSTOM_DIR)"
	@echo "The saver reads that folder. Re-run 'make saver' to bake in gallery stills."

# Puts the playground where Spotlight will offer it. A copy, not a symlink:
# Spotlight resolves symlinks and indexes the app at its real path, so a link in
# ~/Applications leaves `mdfind -onlyin ~/Applications` empty and the app just as
# unfindable as before.
#
# The copy cannot walk up to a checkout the way the in-repo build does — nothing
# above ~/Applications is one — so the checkout it was installed from goes into
# its Info.plist, and `RepoLocation` reads that first. Re-run this target to
# re-point it. If that folder ever goes missing the app says so by name and
# offers a folder picker; it does not open onto an empty shader list.
#
# Info.plist is edited after the copy, so the signature has to be made again
# afterwards, and LaunchServices told about the new identifier.
install-playground: $(PLAYGROUND_BIN)
	# Before anything is copied: the path about to be baked in has to be a
	# checkout that will still be there tomorrow. Refusing here costs a line;
	# getting it wrong installs an app that opens onto an error.
	@test -d "$(PLAYGROUND_REPO)/Sources/Shaders" || { \
		echo "install-playground: '$(PLAYGROUND_REPO)' is not a Lerping@Home checkout"; \
		echo "  (no Sources/Shaders in it). That is the folder the installed copy"; \
		echo "  would edit, so nothing was installed. Pass the right one:"; \
		echo "    make install-playground PLAYGROUND_REPO=/path/to/lerping-at-home"; \
		exit 1; }
	# A staging app should never be running. The canonical app gets a graceful
	# quit and deployment waits for a real exit; Cancel leaves everything intact.
	@$(PLAYGROUND_BIN) --fail-if-running-bundle-id $(PLAYGROUND_BUILD_ID)
	@$(PLAYGROUND_BIN) --fail-if-running-bundle-id $(PLAYGROUND_LEGACY_BUILD_ID)
	@$(PLAYGROUND_BIN) --quit-bundle-id $(INSTALLED_PLAYGROUND_ID)
	mkdir -p "$(PLAYGROUND_INSTALL_DIR)"
	rm -rf "$(INSTALLED_PLAYGROUND)"
	cp -R $(PLAYGROUND_APP) "$(INSTALLED_PLAYGROUND)"
	plutil -replace CFBundleIdentifier -string $(INSTALLED_PLAYGROUND_ID) \
		"$(INSTALLED_PLAYGROUND)/Contents/Info.plist"
	plutil -replace CFBundleName -string LerpPlayground \
		"$(INSTALLED_PLAYGROUND)/Contents/Info.plist"
	plutil -replace LerpRepoRoot -string "$(PLAYGROUND_REPO)" \
		"$(INSTALLED_PLAYGROUND)/Contents/Info.plist"
	# See the note in `install`: staging carries the stamp of whatever commit
	# last recompiled Swift, which is not necessarily this one.
	plutil -replace LerpBuild -string $(LERP_BUILD) \
		"$(INSTALLED_PLAYGROUND)/Contents/Info.plist"
	codesign --force -s - "$(INSTALLED_PLAYGROUND)"
	@test "$$(plutil -extract LerpBuild raw "$(INSTALLED_PLAYGROUND)/Contents/Info.plist")" = "$(LERP_BUILD)" \
		|| { echo "install-playground: installed bundle says $$(plutil -extract LerpBuild raw "$(INSTALLED_PLAYGROUND)/Contents/Info.plist"), tree is $(LERP_BUILD)"; exit 1; }
	@codesign --verify --deep --strict "$(INSTALLED_PLAYGROUND)"
	# Register it now rather than waiting for Spotlight to notice.
	@$(LSREGISTER) -f "$(INSTALLED_PLAYGROUND)" 2>/dev/null || true
	# Not "it launched" — that it found the shaders. Unpiped, so a copy that
	# cannot see them fails the target instead of printing and carrying on.
	@"$(INSTALLED_PLAYGROUND)/Contents/MacOS/LerpPlayground" --shaders
	@echo ""
	@echo "Installed the canonical playground to $(INSTALLED_PLAYGROUND)."
	@echo "It edits $(PLAYGROUND_REPO). 'make playground' opens this copy only."

# Separate from `clean` on purpose: the copy in ~/Applications is the user's, and
# cleaning a build tree is not a reason to uninstall someone's app.
uninstall-playground: $(PLAYGROUND_BIN)
	@$(PLAYGROUND_BIN) --quit-bundle-id $(INSTALLED_PLAYGROUND_ID)
	@$(LSREGISTER) -u "$(INSTALLED_PLAYGROUND)" 2>/dev/null || true
	rm -rf "$(INSTALLED_PLAYGROUND)"
	@echo "Removed $(INSTALLED_PLAYGROUND)."

# Builds the MIDI shim once per Swift toolchain; after that it is a no-op
# until the shim sources or the compiler change.
midi-deps: $(MIDI_LIB)

$(MIDI_LIB): $(MIDI_SRC) $(MIDI_SWIFT_STAMP)
	swift build -c release --package-path $(MIDI_PKG)

# Swift modules do not survive a compiler upgrade: a .swiftmodule built with
# 6.3 cannot be imported by 6.4. The stamp records the toolchain that produced
# the archive; when it differs, the package build dir is wiped so the rule
# above rebuilds with the current compiler instead of failing the import.
$(MIDI_SWIFT_STAMP): FORCE
	@mkdir -p $(dir $(MIDI_SWIFT_STAMP))
	@if [ ! -f $@ ] || [ "$$(cat $@)" != "$$(swiftc --version 2>/dev/null | head -1)" ]; then \
		echo "midi-deps: Swift toolchain changed; rebuilding."; \
		rm -rf $(MIDI_PKG)/.build; \
		swiftc --version 2>/dev/null | head -1 > $@; \
	fi

FORCE:

# Builds the native Installer package without touching /Applications or
# /Library. The screen saver is required; the standalone Playground is selected
# by default and can be unchecked on Installer's Customize screen.
package: saver-build playground-build Packaging/Distribution.xml Packaging/InstallerReadMe.txt \
         Packaging/saver-scripts/preinstall Packaging/saver-scripts/postinstall \
         Packaging/playground-scripts/preinstall Packaging/LerpPlayground.entitlements LICENSE NOTICE.txt
	@printf '%s' '$(RELEASE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$$' || { \
		echo "package: RELEASE_VERSION must look like 1.2.3"; exit 1; }
	rm -rf "$(RELEASE_DIR)"
	mkdir -p "$(RELEASE_SAVER_ROOT)/Library/Screen Savers" \
		"$(RELEASE_PLAYGROUND_ROOT)/Applications" \
		"$(RELEASE_COMPONENTS)" "$(RELEASE_RESOURCES)"
	cp -R "$(SAVER_DIR)" "$(RELEASE_SAVER)"
	cp -R "$(PLAYGROUND_APP)" "$(RELEASE_PLAYGROUND)"
	plutil -replace CFBundleShortVersionString -string "$(RELEASE_VERSION)" \
		"$(RELEASE_SAVER)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(RELEASE_BUILD)" \
		"$(RELEASE_SAVER)/Contents/Info.plist"
	plutil -replace CFBundleIdentifier -string com.hergenroeder.lerping.playground \
		"$(RELEASE_PLAYGROUND)/Contents/Info.plist"
	plutil -replace CFBundleName -string LerpPlayground \
		"$(RELEASE_PLAYGROUND)/Contents/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(RELEASE_VERSION)" \
		"$(RELEASE_PLAYGROUND)/Contents/Info.plist"
	plutil -replace CFBundleVersion -string "$(RELEASE_BUILD)" \
		"$(RELEASE_PLAYGROUND)/Contents/Info.plist"
	@plutil -remove LerpRepoRoot "$(RELEASE_PLAYGROUND)/Contents/Info.plist" 2>/dev/null || true
	plutil -replace LerpStandalone -bool YES "$(RELEASE_PLAYGROUND)/Contents/Info.plist" 2>/dev/null || \
		plutil -insert LerpStandalone -bool YES "$(RELEASE_PLAYGROUND)/Contents/Info.plist"
	mkdir -p "$(RELEASE_PLAYGROUND)/Contents/Resources/Shaders" \
		"$(RELEASE_PLAYGROUND)/Contents/Resources/Thumbnails"
	cp $(SHADERS) "$(RELEASE_PLAYGROUND)/Contents/Resources/Shaders/"
	cp "$(RELEASE_SAVER)/Contents/Resources/Thumbnails/"*.heic \
		"$(RELEASE_PLAYGROUND)/Contents/Resources/Thumbnails/"
	cp -R "$(RELEASE_SAVER)/Contents/Resources/Splats" "$(RELEASE_PLAYGROUND)/Contents/Resources/"
	cp LICENSE NOTICE.txt PORTING.md "$(RELEASE_SAVER)/Contents/Resources/"
	cp LICENSE NOTICE.txt PORTING.md "$(RELEASE_PLAYGROUND)/Contents/Resources/"
	# Splat captures published with no licence play on this machine only:
	# drop them, the looks that draw them, and those looks' stills.
	@python3 -I scripts/splat-convert.py unlicensed | while read -r look capture; do \
		for app in "$(RELEASE_SAVER)" "$(RELEASE_PLAYGROUND)"; do \
			rm -f "$$app/Contents/Resources/Shaders/$$look.metal" \
				"$$app/Contents/Resources/Splats/$$capture.lsplat" \
				"$$app/Contents/Resources/Splats/$$capture.path.json" \
				"$$app/Contents/Resources/Thumbnails/$$look"-*.heic; \
		done; \
		echo "package: left out $$look (capture $$capture has no licence)"; \
	done
	@if [ "$(APP_SIGN_IDENTITY)" = "-" ]; then \
		codesign --force -s - "$(RELEASE_SAVER)"; \
		codesign --force -s - "$(RELEASE_PLAYGROUND)"; \
	else \
		codesign --force --options runtime --timestamp -s "$(APP_SIGN_IDENTITY)" "$(RELEASE_SAVER)"; \
		codesign --force --options runtime --timestamp --entitlements Packaging/LerpPlayground.entitlements \
			-s "$(APP_SIGN_IDENTITY)" "$(RELEASE_PLAYGROUND)"; \
	fi
	codesign --verify --deep --strict "$(RELEASE_SAVER)"
	codesign --verify --deep --strict "$(RELEASE_PLAYGROUND)"
	@src_count="$$(find "$(RELEASE_PLAYGROUND)/Contents/Resources/Shaders" -name '*.metal' | wc -l | tr -d ' ')"; \
		test "$$src_count" = "$$(( $$(find Sources/Shaders -name '*.metal' | wc -l) - $$(python3 -I scripts/splat-convert.py unlicensed | wc -l) ))"
	"$(RELEASE_PLAYGROUND)/Contents/MacOS/LerpPlayground" --shaders
	pkgbuild --analyze --root "$(RELEASE_SAVER_ROOT)" "$(RELEASE_DIR)/saver-components.plist"
	plutil -replace 0.BundleIsRelocatable -bool NO "$(RELEASE_DIR)/saver-components.plist"
	pkgbuild --root "$(RELEASE_SAVER_ROOT)" \
		--component-plist "$(RELEASE_DIR)/saver-components.plist" \
		--scripts Packaging/saver-scripts \
		--identifier com.hergenroeder.lerping.installer.saver \
		--version "$(RELEASE_VERSION)" --install-location / \
		"$(RELEASE_COMPONENTS)/LerpingAtHomeSaver.pkg"
	pkgbuild --analyze --root "$(RELEASE_PLAYGROUND_ROOT)" "$(RELEASE_DIR)/playground-components.plist"
	plutil -replace 0.BundleIsRelocatable -bool NO "$(RELEASE_DIR)/playground-components.plist"
	pkgbuild --root "$(RELEASE_PLAYGROUND_ROOT)" \
		--component-plist "$(RELEASE_DIR)/playground-components.plist" \
		--scripts Packaging/playground-scripts \
		--identifier com.hergenroeder.lerping.installer.playground \
		--version "$(RELEASE_VERSION)" --install-location / \
		"$(RELEASE_COMPONENTS)/LerpPlayground.pkg"
	cp LICENSE Packaging/InstallerReadMe.txt "$(RELEASE_RESOURCES)/"
	@if [ -n "$(INSTALLER_SIGN_IDENTITY)" ]; then \
		productbuild --distribution Packaging/Distribution.xml \
			--package-path "$(RELEASE_COMPONENTS)" --resources "$(RELEASE_RESOURCES)" \
			--identifier com.hergenroeder.lerping.installer --version "$(RELEASE_VERSION)" \
			--sign "$(INSTALLER_SIGN_IDENTITY)" "$(RELEASE_PACKAGE)"; \
	else \
		productbuild --distribution Packaging/Distribution.xml \
			--package-path "$(RELEASE_COMPONENTS)" --resources "$(RELEASE_RESOURCES)" \
			--identifier com.hergenroeder.lerping.installer --version "$(RELEASE_VERSION)" \
			"$(RELEASE_PACKAGE)"; \
	fi
	installer -showChoicesXML -pkg "$(RELEASE_PACKAGE)" -target / > "$(RELEASE_DIR)/choices.plist"
	@test "$$(plutil -extract 0.childItems.0.choiceIdentifier raw "$(RELEASE_DIR)/choices.plist")" = screensaver
	@test "$$(plutil -extract 0.childItems.0.choiceIsEnabled raw "$(RELEASE_DIR)/choices.plist")" = false
	@test "$$(plutil -extract 0.childItems.1.choiceIdentifier raw "$(RELEASE_DIR)/choices.plist")" = playground
	@test "$$(plutil -extract 0.childItems.1.choiceIsSelected raw "$(RELEASE_DIR)/choices.plist")" = 1
	@test "$$(plutil -extract 0.childItems.1.choiceIsEnabled raw "$(RELEASE_DIR)/choices.plist")" = true
	@echo "Built $(RELEASE_PACKAGE)"

# The release download is a DMG; the PKG inside it retains Installer's Customize
# screen, where the Playground can be unchecked.
dmg: package
	$(STAGE_DMG)
	hdiutil verify "$(RELEASE_DMG)"
	@echo "Built $(RELEASE_DMG)"

# Requires credentials created once with:
#   xcrun notarytool store-credentials PROFILE --apple-id ... --team-id ...
#                                                --password ...
release:
	@test "$(APP_SIGN_IDENTITY)" != "-" || { echo "release: set APP_SIGN_IDENTITY to a Developer ID Application certificate"; exit 1; }
	@test -n "$(INSTALLER_SIGN_IDENTITY)" || { echo "release: set INSTALLER_SIGN_IDENTITY to a Developer ID Installer certificate"; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "release: set NOTARY_PROFILE to a notarytool keychain profile"; exit 1; }
	$(MAKE) package RELEASE_VERSION="$(RELEASE_VERSION)" RELEASE_BUILD="$(RELEASE_BUILD)" \
		APP_SIGN_IDENTITY="$(APP_SIGN_IDENTITY)" \
		INSTALLER_SIGN_IDENTITY="$(INSTALLER_SIGN_IDENTITY)"
	xcrun notarytool submit "$(RELEASE_PACKAGE)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(RELEASE_PACKAGE)"
	xcrun stapler validate "$(RELEASE_PACKAGE)"
	pkgutil --check-signature "$(RELEASE_PACKAGE)"
	spctl --assess --verbose=2 --type install "$(RELEASE_PACKAGE)"
	$(STAGE_DMG)
	codesign --force --timestamp --sign "$(APP_SIGN_IDENTITY)" "$(RELEASE_DMG)"
	xcrun notarytool submit "$(RELEASE_DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(RELEASE_DMG)"
	xcrun stapler validate "$(RELEASE_DMG)"
	codesign --verify --verbose=2 "$(RELEASE_DMG)"
	spctl --assess --verbose=2 --type open --context context:primary-signature "$(RELEASE_DMG)"
	hdiutil verify "$(RELEASE_DMG)"
	shasum -a 256 "$(RELEASE_DMG)" > "$(RELEASE_DMG).sha256"
	@echo "Release image: $(RELEASE_DMG)"
	@echo "Checksum:      $(RELEASE_DMG).sha256"

install-example:
	mkdir -p "$(CUSTOM_DIR)"
	cp Templates/plasma.metal "$(CUSTOM_DIR)/"
	@echo "Copied Templates/plasma.metal to $(CUSTOM_DIR)."
	@echo "Run 'make saver' to bake it into the screensaver."

clean:
	# Take the app bundles out of the LaunchServices database on the way, so a
	# cleaned tree does not leave `open -a LerpPlayground` pointing at nothing.
	# Only the ones in build/: the copy `install-playground` put in
	# ~/Applications is the user's, and `uninstall-playground` is how it goes.
	@$(LSREGISTER) -u $(PLAYGROUND_APP) 2>/dev/null || true
	@$(LSREGISTER) -u $(LEGACY_PLAYGROUND_APP) 2>/dev/null || true
	rm -rf $(BUILD) $(MIDI_PKG)/.build
