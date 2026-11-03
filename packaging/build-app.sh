#!/bin/sh
# Builds Quoder.app into ~/Applications.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP="$HOME/Applications/Quoder.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Quoder "$APP/Contents/MacOS/Quoder"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier net.ahg.quoder "$APP"
echo "Built $APP"
