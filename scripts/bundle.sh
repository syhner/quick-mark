#!/bin/sh
# Assembles QuickMark.app from a built binary. Usage: scripts/bundle.sh BINARY APP
set -eu
cd "$(dirname "$0")/.."
rm -rf "$2"
mkdir -p "$2/Contents/MacOS" "$2/Contents/Resources"
cp "$1" "$2/Contents/MacOS/QuickMark"
cp Info.plist "$2/Contents/"
cp AppIcon.icns "$2/Contents/Resources/"
