#!/bin/sh
# Universal (arm64 + x86_64) build with an explicit deployment target. Without -target,
# swiftc stamps the binary with the *host* OS version and it refuses to load on older
# macOS even when nothing in it needs the newer OS.
set -e
cd "$(dirname "$0")"
MIN=14.0
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN" \
    -framework IOKit -framework CoreGraphics -framework Foundation \
    -o "bowheel-$arch" bowheel.swift
done
lipo -create -output bowheel bowheel-arm64 bowheel-x86_64
rm -f bowheel-arm64 bowheel-x86_64
codesign --force --sign - --identifier org.bowheel.daemon bowheel
echo "built: $(pwd)/bowheel ($(lipo -archs bowheel), macOS >= $MIN)"
