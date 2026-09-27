#!/usr/bin/env bash
# Runs the fast, hardware-free unit tests on the first available iPhone simulator.
# The Meta mock-device integration tests are excluded because they depend on
# long fixed sleeps; run them locally in Xcode when touching the DAT pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="${AUTOLOOM_UNIT_TESTS:-GlassifAITests/GlassesGestureInterpreterTests GlassifAITests/AutoLoomCoreTests}"

UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
runtimes = sorted((k for k in data if "iOS" in k), reverse=True)
for runtime in runtimes:
    for device in data[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
')"
echo "Using simulator $UDID"

ONLY_TESTING=()
for test in $TESTS; do
  class_name="${test##*/}"
  if grep -rqsE "class ${class_name}([^A-Za-z0-9_]|$)" "$ROOT/ios/GlassifAITests"; then
    ONLY_TESTING+=("-only-testing:$test")
  else
    echo "Skipping $test (not present in this revision)"
  fi
done

xcodebuild test \
  -project "$ROOT/ios/GlassifAI.xcodeproj" \
  -scheme GlassifAI \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/build-tests" \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY_TESTING[@]}"
