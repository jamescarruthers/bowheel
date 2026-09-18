#!/bin/sh
# Builds everything and packages one zip for GitHub Releases:
#   dist/bowheel-<version>.zip  ->  unzip, cd in, ./install.sh
set -e
cd "$(dirname "$0")"
V="${1:?usage: ./release.sh <version>   e.g. ./release.sh 1.0.0}"
./build.sh
VERSION="$V" ./build-gui.sh
STAGE="dist/bowheel-$V"
rm -rf dist && mkdir -p "$STAGE"
cp -R bowheel Bowheel.app install.sh uninstall.sh scroll-test.html README.md LICENSE "$STAGE/"
# Strip xattrs first and skip resource forks: otherwise ditto emits ._* AppleDouble files
# that codesign --strict rejects as "detritus" after extraction.
xattr -cr "$STAGE"
ditto -c -k --norsrc --keepParent "$STAGE" "dist/bowheel-$V.zip"
rm -rf "$STAGE"
shasum -a 256 "dist/bowheel-$V.zip" | tee "dist/bowheel-$V.zip.sha256"
