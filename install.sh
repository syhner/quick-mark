#!/bin/sh
# Builds QuickMark.app into ~/Applications.
set -eu
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "QuickMark needs the Xcode Command Line Tools. Install them with: xcode-select --install" >&2
    exit 1
fi

swift build -c release --product QuickMark

app="$HOME/Applications/QuickMark.app"
scripts/bundle.sh .build/release/QuickMark "$app"
codesign --force --sign - "$app"

# Register with Launch Services so "Open With" lists it straight away.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
echo "Installed $app"
