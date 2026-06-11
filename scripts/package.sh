#!/bin/sh
# Zip a built terminal-notifier.app into versioned release artifacts.
# Shared by `just package` and the GitHub Actions workflows.
#
# Usage: package.sh [APP_PATH] [OUTPUT_DIR]
set -eu

APP="${1:-build/Release/terminal-notifier.app}"
OUT="${2:-build/package}"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p "$OUT"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$OUT/terminal-notifier-${version}.zip"
cp "$OUT/terminal-notifier-${version}.zip" "$OUT/terminal-notifier.zip"
echo "Created $OUT/terminal-notifier-${version}.zip and $OUT/terminal-notifier.zip"
