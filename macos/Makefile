# make          format, then check: the everyday loop
# make check    what CI runs: fails on any lint error, warning or test failure
# make app      build Meter.app (needed for screenshots of the menu bar item)
# make install  copy Meter.app to /Applications, where it can open at login
NAME := Meter
SRC := Sources Tests Package.swift
APP := .build/$(NAME).app

# SwiftPM records the deployment target as the SDK version in the binary, and
# macOS picks the app's design from that field: without this, an app built
# with the macOS 26 SDK still gets the pre-Liquid Glass look. MIN must match
# `platforms` in Package.swift.
MIN := 15.0
SDK := $(shell xcrun --show-sdk-version)
SWIFTFLAGS := -Xlinker -platform_version -Xlinker macos -Xlinker $(MIN) -Xlinker $(SDK)

.PHONY: all fmt lint build test check app icon run install clean
all: fmt check

fmt:
	swift format --in-place --recursive --parallel $(SRC)

lint:
	swift format lint --strict --recursive --parallel $(SRC)

build:
	swift build $(SWIFTFLAGS)

test:
	swift test $(SWIFTFLAGS) --parallel --quiet

check: lint build test

icon:
	rm -rf .build/AppIcon.iconset
	swift scripts/make-icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns

app: icon
	swift build -c release $(SWIFTFLAGS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Support/Info.plist $(APP)/Contents/
	cp .build/AppIcon.icns $(APP)/Contents/Resources/
	cp .build/release/$(NAME) $(APP)/Contents/MacOS/
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	-pkill -x $(NAME)
	rm -rf /Applications/$(NAME).app
	cp -R $(APP) /Applications/
	open /Applications/$(NAME).app

clean:
	rm -rf .build
