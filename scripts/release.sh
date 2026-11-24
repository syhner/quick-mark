#!/bin/sh
# Builds a universal (Apple Silicon and Intel) QuickMark.app into .build/QuickMark.zip, the GitHub release asset.
set -eu
cd "$(dirname "$0")/.."

min=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Info.plist)
for arch in arm64 x86_64; do
    swift build -c release --product QuickMark --triple "$arch-apple-macosx$min"
done
lipo -create -output .build/QuickMark-universal \
    .build/arm64-apple-macosx/release/QuickMark .build/x86_64-apple-macosx/release/QuickMark

app=.build/release-app/QuickMark.app
scripts/bundle.sh .build/QuickMark-universal "$app"
codesign --force --sign - "$app"
rm -f .build/QuickMark.zip
ditto -c -k --keepParent "$app" .build/QuickMark.zip
echo "Built .build/QuickMark.zip"
