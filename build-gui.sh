#!/bin/sh
# Assembles Bowheel.app: the engine plus the menu bar UI in one process. Universal,
# macOS 15+ (CoreHID). No Xcode project needed — a bundle is just a directory layout.
set -e
cd "$(dirname "$0")"
APP=Bowheel.app
MIN=15.0
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>      <string>org.bowheel.app</string>
  <key>CFBundleName</key>            <string>Bowheel</string>
  <key>CFBundleDisplayName</key>     <string>Bowheel</string>
  <key>CFBundleExecutable</key>      <string>Bowheel</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>${VERSION:-0.2.0}</string>
  <key>CFBundleVersion</key>         <string>${VERSION:-0.2.0}</string>
  <key>LSMinimumSystemVersion</key>  <string>$MIN</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos$MIN" \
    -framework SwiftUI -framework AppKit -framework ServiceManagement \
    -framework CoreHID -framework IOKit -framework CoreGraphics \
    -o "$APP/Contents/MacOS/Bowheel-$arch" Sources/Engine.swift Sources/BowheelApp.swift
done
lipo -create -output "$APP/Contents/MacOS/Bowheel" \
  "$APP/Contents/MacOS/Bowheel-arm64" "$APP/Contents/MacOS/Bowheel-x86_64"
rm -f "$APP/Contents/MacOS/Bowheel-arm64" "$APP/Contents/MacOS/Bowheel-x86_64"
xattr -cr "$APP"
codesign --force --sign - --identifier org.bowheel.app "$APP"
echo "built: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/Bowheel"), macOS >= $MIN)"
