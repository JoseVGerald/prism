#!/bin/bash
#
# Builds Prism for the iOS Simulator and assembles the .app by hand.
#
# Same approach as build.sh: no Xcode project, no pbxproj. swiftc is pointed at
# the simulator SDK and the bundle is put together from parts. The one thing
# that differs from the Mac build is that the source list is explicit — the
# iOS build takes the shared files plus Sources/PrismIOS, and deliberately
# leaves out the five macOS-only ones:
#
#   PrismApp.swift     window chrome, menu bar commands
#   RootView.swift     sidebar shell, compact mode, hover interactions
#   NotchIsland.swift  NSPanel against the notch
#   Floating.swift     the panel that hosts it
#   AudioOutput.swift  CoreAudio default-device switching
#   AudioProbe.swift   ScreenCaptureKit system-audio capture
#
# Those are not stubbed or faked. iOS has no counterpart for any of them, and
# a lookalike that behaved differently would be worse than an honest absence.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Prism"
BUNDLE_ID="com.gerald.prism.ios"
DEVICE="${PRISM_IOS_DEVICE:-iPhone 16 Pro}"
BUILD_DIR=".build-ios"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios26.1-simulator"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP"

# Shared sources, minus the macOS-only files.
SHARED=()
while IFS= read -r f; do SHARED+=("$f"); done < <(
  find Sources/Prism -name '*.swift' \
    ! -name 'PrismApp.swift' \
    ! -name 'RootView.swift' \
    ! -name 'NotchIsland.swift' \
    ! -name 'Floating.swift' \
    ! -name 'AudioOutput.swift' \
    ! -name 'AudioProbe.swift' | sort
)
CORE=()
while IFS= read -r f; do CORE+=("$f"); done < <(find Sources/AutoMixCore -name '*.swift' | sort)
IOS=()
while IFS= read -r f; do IOS+=("$f"); done < <(find Sources/PrismIOS -name '*.swift' | sort)

echo "==> Compiling ${#CORE[@]} core + ${#SHARED[@]} shared + ${#IOS[@]} iOS files"

# AutoMixCore is its own module on macOS; for iOS it is compiled straight in,
# which avoids shipping a framework for four files. `-parse-as-library` because
# the entry point is @main, not top-level code.
xcrun swiftc \
  -target "$TARGET" \
  -sdk "$SDK" \
  -parse-as-library \
  -O \
  -module-name PrismApp \
  -Xlinker -syslibroot -Xlinker "$SDK" \
  "${CORE[@]}" "${SHARED[@]}" "${IOS[@]}" \
  -o "$APP/$APP_NAME"

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>26.1</string>
  <key>UIDeviceFamily</key><array><integer>1</integer></array>
  <!-- Declare the scene explicitly.
       Without a manifest UIKit runs the app on an implicit compatibility
       scene, and a WKWebView on that scene crashed on the very first touch:
       'object cannot be nil' out of -[__NSArrayM insertObject:atIndex:]
       inside -[UIGestureRecognizer _delayTouchesForEvent:inPhase:]. The
       gesture environment and the keyboard arbiter both key off scene
       identity, and the log named the scene it was improvising:
       "scene:com.gerald.prism.ios-default". -->
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key>
    <dict>
      <key>UIWindowSceneSessionRoleApplication</key>
      <array>
        <dict>
          <key>UISceneConfigurationName</key><string>Default Configuration</string>
        </dict>
      </array>
    </dict>
  </dict>
  <key>UILaunchScreen</key><dict/>
  <key>UIUserInterfaceStyle</key><string>Dark</string>
  <!-- Without this, iOS stops playback the moment the app is backgrounded or
       the screen locks, which would make a music player useless. The
       AVAudioSession category in PrismIOSApp is the other half. -->
  <key>UIBackgroundModes</key><array><string>audio</string></array>
  <!-- YouTube Music is https, but the webview also loads media from hosts that
       are not always TLS-clean; this keeps a stray subresource from silently
       killing playback. -->
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
  <key>NSAppleMusicUsageDescription</key><string>Prism shows what you are listening to.</string>
</dict></plist>
PLIST

echo "==> Built $APP"

if [[ "${1:-}" == "--run" ]]; then
  xcrun simctl boot "$DEVICE" 2>/dev/null || true
  # Give the device a moment when it was cold, or install races the boot.
  until xcrun simctl list devices | grep "$DEVICE" | grep -q Booted; do sleep 1; done
  xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
  echo "==> Running on $DEVICE"
fi
