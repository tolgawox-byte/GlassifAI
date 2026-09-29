#!/usr/bin/env bash
# Screenshots of the main screens on the CI simulator, for reviewing the UI
# from a machine without Xcode. Uses the simulator build that the unit-test
# step left in build-tests/. The app is launched with -AutoLoomScreenshot
# <screen> (ScreenshotMode.swift: demo data in throwaway stores; onboarding,
# sign-in, cameras and microphones stay off). Never fails the job.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build-tests/Build/Products/Debug-iphonesimulator/GlassifAI.app"
OUT="$ROOT/screenshots"
SCREENS="${AUTOLOOM_SCREENS:-assistant memory tasks explore settings dealer vehicle shopping intelligence personality captures commands commandlab search privacy skills visualmemory translation remoteassist routines timeline performance}"

if [ ! -d "$APP" ]; then
  echo "::warning title=Screenshots::No simulator build at build-tests/ (did the unit tests run?)"
  exit 0
fi

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
for runtime in sorted((k for k in data if "iOS" in k), reverse=True):
    for device in data[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"]); sys.exit(0)
sys.exit(1)
')" || { echo "::warning title=Screenshots::No iPhone simulator"; exit 0; }

BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Info.plist")"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true
# Permissions granted up front so no system prompt covers a screen.
for service in camera microphone photos-add photos location reminders calendar contacts media-library motion; do
  xcrun simctl privacy "$UDID" grant "$service" "$BUNDLE" >/dev/null 2>&1 || true
done
xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP" || { echo "::warning title=Screenshots::install failed"; exit 0; }
for service in camera microphone photos-add photos location reminders calendar contacts media-library motion; do
  xcrun simctl privacy "$UDID" grant "$service" "$BUNDLE" >/dev/null 2>&1 || true
done

rm -rf "$OUT"
mkdir -p "$OUT"
taken=0
for screen in $SCREENS; do
  xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  if ! xcrun simctl launch "$UDID" "$BUNDLE" -AutoLoomScreenshot "$screen" >/dev/null 2>&1; then
    echo "::warning title=Screenshot $screen::launch failed"
    continue
  fi
  sleep 7
  if xcrun simctl io "$UDID" screenshot --type=png "$OUT/$screen.png" >/dev/null 2>&1; then
    taken=$((taken + 1))
  else
    echo "::warning title=Screenshot $screen::capture failed"
  fi
done
xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
echo "::notice title=Screenshots::$taken screens captured"
