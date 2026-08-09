#!/bin/bash
# Builds Prism.app. No Xcode required — SwiftPM compiles the binary and we
# assemble the bundle by hand.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Prism.app"

# An Xcode update resets the license agreement, and the compiler then refuses
# to run until someone types `sudo xcodebuild -license`. The Command Line Tools
# ship the same macOS 26 SDK and carry no such prompt, so fall back to them.
# (`xcodebuild -version` still succeeds in this state, so probe the compiler.)
if ! swift -version >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
    echo "==> Xcode toolchain unusable (license?); using Command Line Tools"
fi

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Prism"
[ -f "$BIN" ] || { echo "build failed: no binary at $BIN"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Prism"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Prism</string>
    <key>CFBundleDisplayName</key>           <string>Prism</string>
    <key>CFBundleIdentifier</key>            <string>com.gerald.prism</string>
    <key>CFBundleExecutable</key>            <string>Prism</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>26.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <!-- YouTube serves media over https only; no arbitrary loads needed. -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsArbitraryLoads</key><false/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for local use, and required for the webview's
# networking to behave on Apple silicon.
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"

echo "==> Built $(pwd)/$APP"
