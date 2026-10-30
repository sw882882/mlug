#!/bin/sh
# Builds mlug.app (menu bar app) into mac/build/.
set -e
cd "$(dirname "$0")"
swift build -c release --product MlugBar
APP=build/mlug.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MlugBar" "$APP/Contents/MacOS/mlug"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.mlug.mac</string>
    <key>CFBundleName</key><string>mlug</string>
    <key>CFBundleExecutable</key><string>mlug</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>mlug streams the virtual display to your tablet.</string>
</dict>
</plist>
PLIST
codesign --force --sign "${MLUG_SIGN_IDENTITY:--}" "$APP"
echo "Built $PWD/$APP"
