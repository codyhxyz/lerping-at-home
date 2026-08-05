# Lerping@Home — Metal shader screensaver for macOS.
# Plain swiftc build, no Xcode project. `make install` puts it in
# ~/Library/Screen Savers; select "Lerping@Home" in System Settings > Screen Saver.

BUILD      := build
TARGET     := arm64-apple-macos14.0
SDK        := $(shell xcrun --show-sdk-path --sdk macosx)
CORE       := $(wildcard Sources/LerpCore/*.swift)
SAVER_SRC  := Sources/Saver/LerpSaverView.swift
PREVIEW    := $(wildcard Sources/Preview/*.swift)
SHADERS    := $(wildcard Sources/Shaders/*.metal)
FRAMEWORKS := -framework AppKit -framework Metal -framework QuartzCore \
              -framework CoreGraphics -framework ImageIO
SAVER_DIR  := $(BUILD)/Lerping@Home.saver
CUSTOM_DIR := $(HOME)/Library/Application Support/Lerping/Shaders
INSTALLED  := $(HOME)/Library/Screen Savers/Lerping@Home.saver

.PHONY: all preview saver snapshots test-load install install-example clean

all: saver preview

preview: $(BUILD)/LerpPreview

$(BUILD)/LerpPreview: $(CORE) $(PREVIEW)
	@mkdir -p $(BUILD)
	swiftc -O -parse-as-library -target $(TARGET) \
		-o $@ $(CORE) $(PREVIEW) $(FRAMEWORKS)

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
	rm -rf $(BUILD)
