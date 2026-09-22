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

# Signed with the Apple Development certificate when there is one. An ad-hoc
# signature is enough to run (and the webview's networking needs *some*
# signature on Apple silicon), but macOS pins privacy grants to it by the
# binary's hash — so every rebuild became a stranger to Screen & System Audio
# Recording and asked again. A certificate identity survives rebuilds.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | awk '/Apple Development/ { print $2; exit }')"
if [ -n "$IDENTITY" ] && codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "==> Signed with Apple Development identity"
else
    codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"
    echo "==> Ad-hoc signed — privacy permissions will re-prompt after each rebuild"
fi

echo "==> Built $(pwd)/$APP"
