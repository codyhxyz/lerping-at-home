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

.PHONY: all preview playground playground-build playground-test saver snapshots \
        test-load midi-deps install install-example clean

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
		-o $@ $(CORE) $(PLAYGROUND) $(FRAMEWORKS) $(MIDI_FLAGS)
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
	codesign --force -s - $(SAVER_DIR)

snapshots: $(BUILD)/LerpPreview
	$(BUILD)/LerpPreview --snapshot $(BUILD)/snapshots

test-load: saver scripts/loadtest.swift
	swiftc -target $(TARGET) -o $(BUILD)/loadtest scripts/loadtest.swift \
		-framework ScreenSaver -framework AppKit
	$(BUILD)/loadtest $(SAVER_DIR)

install: saver
	mkdir -p "$(HOME)/Library/Screen Savers" "$(CUSTOM_DIR)"
	rm -rf "$(INSTALLED)"
	cp -R $(SAVER_DIR) "$(INSTALLED)"
	# Bake custom shaders into the bundle. The screensaver host runs sandboxed
	# and cannot read ~/Library/Application Support at runtime, so the bundle
	# is the only location it can reliably load from. Re-run `make install`
	# after adding or editing a custom shader.
	@sh -c 'ls "$(CUSTOM_DIR)"/*.metal >/dev/null 2>&1 && cp "$(CUSTOM_DIR)"/*.metal "$(INSTALLED)/Contents/Resources/Shaders/" && echo "Baked in: $$(ls "$(CUSTOM_DIR)" | tr "\\n" " ")" || true'
	codesign --force -s - "$(INSTALLED)"
	@echo ""
	@echo "Installed. Select 'Lerping@Home' in System Settings > Screen Saver."
	@echo "Custom shaders: put .metal files in"
	@echo "  $(CUSTOM_DIR)"
	@echo "then re-run 'make install' to bake them into the saver."

install-example:
	mkdir -p "$(CUSTOM_DIR)"
	cp Templates/plasma.metal "$(CUSTOM_DIR)/"
	@echo "Copied Templates/plasma.metal to $(CUSTOM_DIR)."
	@echo "Run 'make install' to bake it into the screensaver."

clean:
	# Take the app bundles out of the LaunchServices database on the way, so a
	# cleaned tree does not leave `open -a LerpPlayground` pointing at nothing.
	@$(LSREGISTER) -u $(PLAYGROUND_APP) 2>/dev/null || true
	@$(LSREGISTER) -u $(SELFTEST_APP) 2>/dev/null || true
	rm -rf $(BUILD) $(MIDI_PKG)/.build
