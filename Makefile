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
MIDI_BIN   := $(MIDI_PKG)/.build/release
MIDI_LIB   := $(MIDI_BIN)/libMIDIDeps.a
MIDI_SRC   := $(MIDI_PKG)/Package.swift $(wildcard $(MIDI_PKG)/Sources/MIDIDeps/*.swift)
# CoreMIDI.framework comes in through Swift autolink metadata; no -framework needed.
MIDI_FLAGS := -I $(MIDI_BIN)/Modules -L $(MIDI_BIN) -lMIDIDeps

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

.PHONY: all preview playground playground-build saver saver-build midi-deps \
        install install-example install-playground uninstall-playground package dmg release clean

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

$(PLAYGROUND_BIN): $(CORE) $(PLAYGROUND) $(MIDI_LIB) $(PLAYGROUND_ICNS) Sources/Playground/Info.plist LICENSE NOTICE.txt
	@$(LSREGISTER) -u $(LEGACY_PLAYGROUND_APP) 2>/dev/null || true
	rm -rf $(LEGACY_PLAYGROUND_APP)
	@mkdir -p $(PLAYGROUND_APP)/Contents/MacOS $(PLAYGROUND_APP)/Contents/Resources
	swiftc -O -parse-as-library -target $(TARGET) \
		-o $@ $(CORE) $(PLAYGROUND) $(PLAYGROUND_FW) $(MIDI_FLAGS)
	cp Sources/Playground/Info.plist $(PLAYGROUND_APP)/Contents/Info.plist
	plutil -replace CFBundleIdentifier -string $(PLAYGROUND_BUILD_ID) $(PLAYGROUND_APP)/Contents/Info.plist
	plutil -replace CFBundleName -string LerpPlaygroundStaging $(PLAYGROUND_APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $(BUNDLE_VERSION) $(PLAYGROUND_APP)/Contents/Info.plist
	cp $(PLAYGROUND_ICNS) $(PLAYGROUND_APP)/Contents/Resources/LerpPlayground.icns
	cp LICENSE NOTICE.txt $(PLAYGROUND_APP)/Contents/Resources/
	codesign --force -s - $(PLAYGROUND_APP)

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

# `saver` means the saver the machine will actually run. Use `saver-build` only
# when a staging bundle is explicitly wanted.
saver: install

saver-build: $(BUILD)/LerpPreview $(CORE) $(SAVER_SRC) $(SHADERS) Sources/Saver/Info.plist LICENSE NOTICE.txt
	@mkdir -p $(SAVER_DIR)/Contents/MacOS $(SAVER_DIR)/Contents/Resources/Shaders
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
	cp $(SHADERS) $(SAVER_DIR)/Contents/Resources/Shaders/
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
	codesign --force -s - "$(INSTALLED)"
	@pkill -9 -x legacyScreenSaver 2>/dev/null || true
	@! pgrep -x legacyScreenSaver >/dev/null
	@test "$$(plutil -extract CFBundleVersion raw $(SAVER_DIR)/Contents/Info.plist)" = \
	      "$$(plutil -extract CFBundleVersion raw "$(INSTALLED)/Contents/Info.plist")"
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
	codesign --force -s - "$(INSTALLED_PLAYGROUND)"
	@test "$$(plutil -extract CFBundleVersion raw $(PLAYGROUND_APP)/Contents/Info.plist)" = \
	      "$$(plutil -extract CFBundleVersion raw "$(INSTALLED_PLAYGROUND)/Contents/Info.plist")"
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

# Fetches and builds swift-midi-io once; after that it is a no-op.
midi-deps: $(MIDI_LIB)

$(MIDI_LIB): $(MIDI_SRC)
	swift build -c release --package-path $(MIDI_PKG)

# Builds the native Installer package without touching /Applications or
# /Library. The screen saver is required; the standalone Playground is selected
# by default and can be unchecked on Installer's Customize screen.
package: saver-build playground-build Packaging/Distribution.xml Packaging/InstallerReadMe.txt \
         Packaging/saver-scripts/preinstall Packaging/saver-scripts/postinstall \
         Packaging/playground-scripts/preinstall LICENSE NOTICE.txt
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
	cp "$(RELEASE_SAVER)/Contents/Resources/Thumbnails/"*.png \
		"$(RELEASE_PLAYGROUND)/Contents/Resources/Thumbnails/"
	cp LICENSE NOTICE.txt PORTING.md "$(RELEASE_SAVER)/Contents/Resources/"
	cp LICENSE NOTICE.txt PORTING.md "$(RELEASE_PLAYGROUND)/Contents/Resources/"
	@if [ "$(APP_SIGN_IDENTITY)" = "-" ]; then \
		codesign --force -s - "$(RELEASE_SAVER)"; \
		codesign --force -s - "$(RELEASE_PLAYGROUND)"; \
	else \
		codesign --force --options runtime --timestamp -s "$(APP_SIGN_IDENTITY)" "$(RELEASE_SAVER)"; \
		codesign --force --options runtime --timestamp -s "$(APP_SIGN_IDENTITY)" "$(RELEASE_PLAYGROUND)"; \
	fi
	codesign --verify --deep --strict "$(RELEASE_SAVER)"
	codesign --verify --deep --strict "$(RELEASE_PLAYGROUND)"
	@src_count="$$(find "$(RELEASE_PLAYGROUND)/Contents/Resources/Shaders" -name '*.metal' | wc -l | tr -d ' ')"; \
		test "$$src_count" = "$$(find Sources/Shaders -name '*.metal' | wc -l | tr -d ' ')"
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
