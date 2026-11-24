#!/bin/sh
# Builds QuickMark.app into ~/Applications.
set -eu
cd "$(dirname "$0")"

swift build -c release --product QuickMark

app="$HOME/Applications/QuickMark.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/QuickMark "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
codesign --force --sign - "$app"

# Register with Launch Services so "Open With" lists it straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed $app"
