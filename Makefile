# Lerping@Home — Metal shader screensaver for macOS.
# Plain swiftc build, no Xcode project. `make install` puts it in
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
# gallery writes the screensaver's rotation through the very same
# `ScreenSaverDefaults(forModuleWithName:)` the saver reads it with, rather than
# reimplementing where a ByHost domain lives. Not added to FRAMEWORKS: the
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
PLAYGROUND_APP  := $(BUILD)/LerpPlayground.app
PLAYGROUND_BIN  := $(PLAYGROUND_APP)/Contents/MacOS/LerpPlayground
PLAYGROUND_ICNS := $(BUILD)/LerpPlayground.icns
# A second bundle, holding the same executable under a bundle identifier of its
# own, is how `--selftest` stays out of the way: it cannot be mistaken for the
# app by the single-instance check, cannot activate it, and writes its window
# and split-view preferences into a domain of its own.
SELFTEST_APP    := $(BUILD)/LerpPlaygroundSelfTest.app
SELFTEST_BIN    := $(SELFTEST_APP)/Contents/MacOS/LerpPlaygroundSelfTest
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
# An identifier of its own, for the same reason the self-test bundle has one:
# the single-instance check keys on it. Sharing the app's identifier would mean
# `make playground` silently raising the installed copy — which edits whatever
# checkout it was installed from, not the one you are standing in. Overridable
# so a throwaway copy installed somewhere else cannot be confused with this one
# either, by LaunchServices or by the running app.
INSTALLED_PLAYGROUND_ID ?= com.hergenroeder.lerping.playground.installed

# The playground's MIDI support, and the only third-party code in the project.
# `Sources/MIDIDeps` is a SwiftPM shim around orchetect/swift-midi's I/O module
# that emits a static archive plus a directory of .swiftmodule files, which is
# all plain swiftc needs. `swift build` ships in the Xcode command line tools
# the README already requires, so this adds no toolchain.
#
# These flags are appended to the LerpPlayground rule ONLY. The screensaver, the
# preview app and the snapshot renderer link nothing but system frameworks, and
# `make all`, `make snapshots` and `make test-load` never invoke swift build.
MIDI_PKG   := Sources/MIDIDeps
MIDI_BIN   := $(MIDI_PKG)/.build/release
MIDI_LIB   := $(MIDI_BIN)/libMIDIDeps.a
MIDI_SRC   := $(MIDI_PKG)/Package.swift $(wildcard $(MIDI_PKG)/Sources/MIDIDeps/*.swift)
# CoreMIDI.framework comes in through Swift autolink metadata; no -framework needed.
MIDI_FLAGS := -I $(MIDI_BIN)/Modules -L $(MIDI_BIN) -lMIDIDeps

PROBE_APP  := $(BUILD)/LerpSandboxProbe.app
PROBE_BIN  := $(PROBE_APP)/Contents/MacOS/LerpSandboxProbe
PROBE_ID   := com.hergenroeder.lerping.sandboxprobe

.PHONY: all preview playground playground-build playground-test saver snapshots \
        test-load test-host sandbox-probe midi-deps install install-example \
        install-playground uninstall-playground clean

all: saver preview

preview: $(BUILD)/LerpPreview

$(BUILD)/LerpPreview: $(CORE) $(PREVIEW)
	@mkdir -p $(BUILD)
	swiftc -O -parse-as-library -target $(TARGET) \
		-o $@ $(CORE) $(PREVIEW) $(FRAMEWORKS)

# Live shader playground: source editor + hot-reloading Metal view.
# `make playground` builds and opens it; `make playground-build` only builds.
#
# Through `open`, not by exec'ing the binary, so LaunchServices gets to do its
# job: run this twice and the second one raises the window the first one opened
# instead of starting a second app. (`open -a LerpPlayground` does the same
# from anywhere, once `playground-build` has registered the bundle.)
#
# It still reads shaders out of the repo: ShaderLocations walks up from the
# executable, which reaches the repo root from inside the bundle too, so the
# working directory `open` hands it does not matter.
playground: playground-build
	open -a "$(CURDIR)/$(PLAYGROUND_APP)"

playground-build: $(PLAYGROUND_BIN)

$(PLAYGROUND_BIN): $(CORE) $(PLAYGROUND) $(MIDI_LIB) $(PLAYGROUND_ICNS) Sources/Playground/Info.plist
	@mkdir -p $(PLAYGROUND_APP)/Contents/MacOS $(PLAYGROUND_APP)/Contents/Resources
	swiftc -O -parse-as-library -target $(TARGET) \
		-o $@ $(CORE) $(PLAYGROUND) $(PLAYGROUND_FW) $(MIDI_FLAGS)
	cp Sources/Playground/Info.plist $(PLAYGROUND_APP)/Contents/Info.plist
	cp $(PLAYGROUND_ICNS) $(PLAYGROUND_APP)/Contents/Resources/LerpPlayground.icns
	codesign --force -s - $(PLAYGROUND_APP)
	# Tell LaunchServices about it now rather than waiting for Spotlight, so
	# `open -a LerpPlayground` works the moment the build finishes.
	@$(LSREGISTER) -f $(PLAYGROUND_APP) 2>/dev/null || true

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

# Scripted UI test: drives the real window — real AppKit controls, a real
# Metal view, real Core MIDI — checks that it renders, edits the shader, breaks
# it, and fixes it. Exits non-zero on any failed check.
#
# It runs out of its own bundle so it can leave the user's screen alone: a
# separate identifier keeps it clear of the app's single-instance check, and
# LSUIElement plus an `.accessory` policy mean no Dock tile, no menu bar and no
# stolen focus. Run directly rather than through `open` so make sees the check
# output and the exit code. The window it opens is real and rendering but at
# zero opacity, and every path out of the run — including the watchdog — closes
# it and exits.
playground-test: $(SELFTEST_BIN)
	$(SELFTEST_BIN) --selftest

$(SELFTEST_BIN): $(PLAYGROUND_BIN) Sources/Playground/SelfTest-Info.plist
	@mkdir -p $(SELFTEST_APP)/Contents/MacOS
	cp $(PLAYGROUND_BIN) $@
	cp Sources/Playground/SelfTest-Info.plist $(SELFTEST_APP)/Contents/Info.plist
	codesign --force -s - $(SELFTEST_APP)

# Fetches and builds swift-midi-io once; after that it is a no-op.
midi-deps: $(MIDI_LIB)

$(MIDI_LIB): $(MIDI_SRC)
	swift build -c release --package-path $(MIDI_PKG)

saver: $(BUILD)/LerpPreview $(CORE) $(SAVER_SRC) $(SHADERS) Sources/Saver/Info.plist
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
	cp $(SHADERS) $(SAVER_DIR)/Contents/Resources/Shaders/
	# System Settings thumbnail, generated from the mesh-gradient shader.
	$(BUILD)/LerpPreview --snapshot $(BUILD)/thumb --size 180x116 --time 4 --shader mesh-gradient >/dev/null
	cp $(BUILD)/thumb/mesh-gradient.png $(SAVER_DIR)/Contents/Resources/thumbnail@2x.png
	$(BUILD)/LerpPreview --snapshot $(BUILD)/thumb1x --size 90x58 --time 4 --shader mesh-gradient >/dev/null
	cp $(BUILD)/thumb1x/mesh-gradient.png $(SAVER_DIR)/Contents/Resources/thumbnail.png
	# One still per look, for the gallery in the Options… sheet.
	#
	# Baked in rather than left to be rendered on demand because the sheet is
	# built inside legacyScreenSaver, which is App Sandboxed: it can read its
	# own bundle for free and can only write inside its container. A bundle full
	# of stills means opening Options… does no GPU work at all in the common
	# case. Stale ones are not a hazard — the filenames carry a hash of each
	# shader's source, so a still for a `.metal` that has since changed simply
	# does not match and is drawn at runtime instead.
	#
	# Incremental: after the first build this is 114 file-exists checks.
	$(BUILD)/LerpPreview --thumbnails $(SAVER_DIR)
	codesign --force -s - $(SAVER_DIR)

snapshots: $(BUILD)/LerpPreview
	$(BUILD)/LerpPreview --snapshot $(BUILD)/snapshots

# The ByHost domain the writing half of `test-load` uses. Not the saver's.
# See the guard on `mayWrite` in scripts/loadtest.swift: the sheet's OK button
# is worth testing, and testing it against the domain someone's screensaver
# actually reads is not a test, it is a rotation waiting to be overwritten.
LOADTEST_MODULE := com.hergenroeder.lerping.uitest

test-load: saver scripts/loadtest.swift
	swiftc -target $(TARGET) -o $(BUILD)/loadtest scripts/loadtest.swift \
		-framework ScreenSaver -framework AppKit
	# Read-only, against the real domain: what the user's own Options… sheet
	# comes up showing. Nothing in this run writes anything.
	$(BUILD)/loadtest $(SAVER_DIR)
	# …and again pointed somewhere disposable, where OK may be pressed.
	@defaults -currentHost delete $(LOADTEST_MODULE) 2>/dev/null || true
	LERP_DEFAULTS_MODULE=$(LOADTEST_MODULE) $(BUILD)/loadtest $(SAVER_DIR)
	@defaults -currentHost delete $(LOADTEST_MODULE) 2>/dev/null || true

# Does the saver render, and does it stop when nothing can see it?
#
# `test-load` and `sandbox-probe` both drive the Options… sheet and neither of
# them draws a frame. This one loads the same bundle as a *non-preview* host,
# in each of the two shapes legacyScreenSaver produces — one on screen, one
# full-screen at the wallpaper layer where nothing of it is ever scanned out —
# and reads back what the saver concluded about itself.
#
# It puts a small window on screen for the length of the first phase. That is
# the point of it: "the code path is taken" is not evidence that a screensaver
# renders, and the black screensaver this check exists to prevent shipped twice
# without anyone watching pixels.
#
# Not part of `all`, for the same reason: it wants the screen.
HOSTTEST_SECONDS ?= 20

test-host: saver scripts/hosttest.swift
	swiftc -target $(TARGET) -o $(BUILD)/hosttest scripts/hosttest.swift \
		-framework ScreenSaver -framework AppKit
	$(BUILD)/hosttest $(SAVER_DIR) $(HOSTTEST_SECONDS)

# What the Options… sheet can do inside an App Sandbox — the one thing
# `test-load` cannot tell you, because it runs with the run of the machine and
# the sheet the user gets is built inside legacyScreenSaver.appex.
#
# Wraps scripts/sandboxprobe.swift in an .app and ad-hoc signs it with
# legacyScreenSaver's own entitlements, so it is App Sandboxed for real:
# `NSHomeDirectory()` is redirected into a container of its own and a write
# outside it is denied by the kernel, not by a check in this repo. Then it loads
# the real `.saver` and builds the real sheet.
#
# scripts/SandboxProbe.entitlements is a transcription of
#
#   codesign -d --entitlements - \
#     /System/Library/Frameworks/ScreenSaver.framework/PlugIns/legacyScreenSaver.appex
#
# minus the entitlements no locally-signed binary may claim
# (com.apple.private.*, the mach-lookup and yasb temporary exceptions) and the
# network/pictures ones the probe has no use for. Everything dropped only makes
# this sandbox *tighter* than the real one, so a capability that holds here
# holds there. The two that matter are both kept: `app-sandbox`, which is what
# redirects NSHomeDirectory() and denies writes outside the container, and the
# read-only exception for `/`, which is why the screensaver can read the user's
# custom shader folder without being able to write a byte to it.
#
# The file carries no XML comments on purpose: AMFI's entitlement parser rejects
# them outright, and it says so in a way that is easy to mistake for a code
# signing problem ("AMFIUnserializeXML: syntax error").
#
# Separate from `test-load` because it creates a sandbox container in the user's
# Library. Everything the probe wrote goes on the way out; the empty stub
# containermanagerd keeps is not ours to delete and needs Full Disk Access even
# to look at, so the `rm` is best-effort and its failure is not the target's.
sandbox-probe: saver scripts/sandboxprobe.swift scripts/SandboxProbe-Info.plist \
               scripts/SandboxProbe.entitlements
	@mkdir -p $(PROBE_APP)/Contents/MacOS
	swiftc -target $(TARGET) -o $(PROBE_BIN) scripts/sandboxprobe.swift \
		-framework ScreenSaver -framework AppKit -framework Metal
	cp scripts/SandboxProbe-Info.plist $(PROBE_APP)/Contents/Info.plist
	codesign --force -s - --entitlements scripts/SandboxProbe.entitlements $(PROBE_APP)
	@echo ""
	# An absolute path: a sandboxed process starts in its own container, so a
	# relative one resolves inside it and finds nothing.
	$(PROBE_BIN) "$(CURDIR)/$(SAVER_DIR)"; status=$$?; \
	 rm -rf "$(HOME)/Library/Containers/$(PROBE_ID)"; \
	 exit $$status

install: saver
	mkdir -p "$(HOME)/Library/Screen Savers" "$(CUSTOM_DIR)"
	rm -rf "$(INSTALLED)"
	cp -R $(SAVER_DIR) "$(INSTALLED)"
	# Bake custom shaders into the bundle. The screensaver host runs sandboxed
	# and cannot read ~/Library/Application Support at runtime, so the bundle
	# is the only location it can reliably load from. Re-run `make install`
	# after adding or editing a custom shader.
	@sh -c 'ls "$(CUSTOM_DIR)"/*.metal >/dev/null 2>&1 && cp "$(CUSTOM_DIR)"/*.metal "$(INSTALLED)/Contents/Resources/Shaders/" && echo "Baked in: $$(ls "$(CUSTOM_DIR)" | tr "\\n" " ")" || true'
	# …and now the Options… gallery's stills, over the installed bundle rather
	# than over build/, so a custom shader that was just baked in gets a tile
	# like every other look. Reads that bundle's own Shaders directory, so this
	# is the one place the two can never disagree.
	$(BUILD)/LerpPreview --thumbnails "$(INSTALLED)"
	codesign --force -s - "$(INSTALLED)"
	@echo ""
	@echo "Installed. Select 'Lerping@Home' in System Settings > Screen Saver."
	@echo "Custom shaders: put .metal files in"
	@echo "  $(CUSTOM_DIR)"
	@echo "then re-run 'make install' to bake them into the saver."

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
	mkdir -p "$(PLAYGROUND_INSTALL_DIR)"
	rm -rf "$(INSTALLED_PLAYGROUND)"
	cp -R $(PLAYGROUND_APP) "$(INSTALLED_PLAYGROUND)"
	plutil -replace CFBundleIdentifier -string $(INSTALLED_PLAYGROUND_ID) \
		"$(INSTALLED_PLAYGROUND)/Contents/Info.plist"
	plutil -replace LerpRepoRoot -string "$(PLAYGROUND_REPO)" \
		"$(INSTALLED_PLAYGROUND)/Contents/Info.plist"
	codesign --force -s - "$(INSTALLED_PLAYGROUND)"
	# Register it now rather than waiting for Spotlight to notice.
	@$(LSREGISTER) -f "$(INSTALLED_PLAYGROUND)" 2>/dev/null || true
	# Not "it launched" — that it found the shaders. Unpiped, so a copy that
	# cannot see them fails the target instead of printing and carrying on.
	@"$(INSTALLED_PLAYGROUND)/Contents/MacOS/LerpPlayground" --shaders
	@echo ""
	@echo "Installed to $(INSTALLED_PLAYGROUND)."
	@echo "Spotlight it as 'LerpPlayground'. It edits $(PLAYGROUND_REPO)."
	@echo "'make playground' still builds and opens the in-repo copy for development;"
	@echo "the two have different bundle ids, so neither ever raises the other."
	@echo "'make uninstall-playground' removes this copy. 'make clean' leaves it alone."

# Separate from `clean` on purpose: the copy in ~/Applications is the user's, and
# cleaning a build tree is not a reason to uninstall someone's app.
uninstall-playground:
	@$(LSREGISTER) -u "$(INSTALLED_PLAYGROUND)" 2>/dev/null || true
	rm -rf "$(INSTALLED_PLAYGROUND)"
	@echo "Removed $(INSTALLED_PLAYGROUND)."

install-example:
	mkdir -p "$(CUSTOM_DIR)"
	cp Templates/plasma.metal "$(CUSTOM_DIR)/"
	@echo "Copied Templates/plasma.metal to $(CUSTOM_DIR)."
	@echo "Run 'make install' to bake it into the screensaver."

clean:
	# Take the app bundles out of the LaunchServices database on the way, so a
	# cleaned tree does not leave `open -a LerpPlayground` pointing at nothing.
	# Only the ones in build/: the copy `install-playground` put in
	# ~/Applications is the user's, and `uninstall-playground` is how it goes.
	@$(LSREGISTER) -u $(PLAYGROUND_APP) 2>/dev/null || true
	@$(LSREGISTER) -u $(SELFTEST_APP) 2>/dev/null || true
	rm -rf $(BUILD) $(MIDI_PKG)/.build
