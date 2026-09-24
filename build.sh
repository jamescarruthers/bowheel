#!/bin/sh
# Builds the `bowheel` command-line tool (diagnostics / headless). Universal, macOS 15+ (CoreHID).
set -e
cd "$(dirname "$0")"
MIN=15.0
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN" \
    -framework CoreHID -framework IOKit -framework CoreGraphics -framework Foundation \
    -o "bowheel-$arch" Sources/Engine.swift Sources/main.swift
done
lipo -create -output bowheel bowheel-arm64 bowheel-x86_64
rm -f bowheel-arm64 bowheel-x86_64
codesign --force --sign - --identifier org.bowheel.cli bowheel
echo "built: $(pwd)/bowheel ($(lipo -archs bowheel), macOS >= $MIN)"
