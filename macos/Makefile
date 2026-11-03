# make          format, then check: the everyday loop
# make check    what CI runs: fails on any lint error, warning or test failure
# make app      build Meter.app (needed for screenshots of the menu bar item)
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

.PHONY: all fmt lint build test check app run clean
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

app:
	swift build -c release $(SWIFTFLAGS)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp Support/Info.plist $(APP)/Contents/
	cp .build/release/$(NAME) $(APP)/Contents/MacOS/
	codesign --force --sign - $(APP)

run: app
	open $(APP)

clean:
	rm -rf .build
