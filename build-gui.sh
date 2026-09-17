#!/bin/sh
# Assembles Bowheel.app by hand — a SwiftUI menu bar app needs a bundle (LSUIElement
# hides it from the Dock) but does not need an Xcode project.
set -e
cd "$(dirname "$0")"
APP=Bowheel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>      <string>org.bowheel.gui</string>
  <key>CFBundleName</key>            <string>Bowheel</string>
  <key>CFBundleDisplayName</key>     <string>Bowheel</string>
  <key>CFBundleExecutable</key>      <string>Bowheel</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

MIN=14.0   # must match LSMinimumSystemVersion above
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos$MIN" \
    -framework SwiftUI -framework AppKit \
    -o "$APP/Contents/MacOS/Bowheel-$arch" BowheelGUI.swift
done
lipo -create -output "$APP/Contents/MacOS/Bowheel" \
  "$APP/Contents/MacOS/Bowheel-arm64" "$APP/Contents/MacOS/Bowheel-x86_64"
rm -f "$APP/Contents/MacOS/Bowheel-arm64" "$APP/Contents/MacOS/Bowheel-x86_64"
xattr -cr "$APP"   # Finder/provenance xattrs make codesign reject the bundle
codesign --force --sign - --identifier org.bowheel.gui "$APP"
echo "built: $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/Bowheel"), macOS >= $MIN)"
