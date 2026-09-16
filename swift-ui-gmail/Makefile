APP        := Gmail
BUILD_DIR  := build
APP_BUNDLE := $(BUILD_DIR)/$(APP).app
BIN        := .build/release/$(APP)
ICONSET    := $(BUILD_DIR)/AppIcon.iconset
ICNS       := $(BUILD_DIR)/AppIcon.icns
INSTALL_TO := /Applications/$(APP).app

.PHONY: all build app run install clean

all: app

build:
	swift build -c release

$(ICNS): Scripts/make-icon.swift
	@mkdir -p $(BUILD_DIR)
	swift Scripts/make-icon.swift $(ICONSET)
	iconutil -c icns $(ICONSET) -o $(ICNS)

app: build $(ICNS)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(BIN) $(APP_BUNDLE)/Contents/MacOS/$(APP)
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp $(ICNS) $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	printf 'APPL????' > $(APP_BUNDLE)/Contents/PkgInfo
	codesign --force --deep --sign - $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

install: app
	rm -rf "$(INSTALL_TO)"
	ditto $(APP_BUNDLE) "$(INSTALL_TO)"
	@echo "Installed to $(INSTALL_TO)"

clean:
	rm -rf $(BUILD_DIR) .build
