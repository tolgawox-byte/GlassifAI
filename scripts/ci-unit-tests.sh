#!/usr/bin/env bash
# Runs the fast, hardware-free unit tests on the first available iPhone simulator.
# The Meta mock-device integration tests are excluded because they depend on
# long fixed sleeps; run them locally in Xcode when touching the DAT pipeline.
# Results are also published as GitHub annotations so they are visible on the
# public run page without downloading logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="${AUTOLOOM_UNIT_TESTS:-GlassifAITests/GlassesGestureInterpreterTests GlassifAITests/AutoLoomCoreTests GlassifAITests/AutoLoomTaskTests}"
LOG="$ROOT/build-tests-output.log"

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

set +e
xcodebuild test \
  -project "$ROOT/ios/GlassifAI.xcodeproj" \
  -scheme GlassifAI \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/build-tests" \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY_TESTING[@]}" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

passed_names="$(grep -E "Test Case '-\[[^]]+\]' passed" "$LOG" | sed -E "s/.*Test Case '-\[[A-Za-z0-9_]+\.([^]]+)\]' passed.*/\1/" | sort -u || true)"
failed_names="$(grep -E "Test Case '-\[[^]]+\]' failed" "$LOG" | sed -E "s/.*Test Case '-\[[A-Za-z0-9_]+\.([^]]+)\]' failed.*/\1/" | sort -u || true)"
passed_count="$(printf '%s\n' "$passed_names" | grep -c . || true)"
failed_count="$(printf '%s\n' "$failed_names" | grep -c . || true)"

echo "::notice title=iOS unit tests::${passed_count} passed, ${failed_count} failed (xcodebuild exit ${status})"
if [ -n "$passed_names" ]; then
  echo "::notice title=Passed iOS tests::$(printf '%s' "$passed_names" | paste -sd ';' - | sed 's/;/; /g')"
fi
if [ -n "$failed_names" ]; then
  echo "::error title=Failed iOS tests::$(printf '%s' "$failed_names" | paste -sd ';' - | sed 's/;/; /g')"
  grep -E "error: -\[|XCTAssert|failed: caught" "$LOG" | head -n 20 | while IFS= read -r line; do
    echo "::error title=Test failure detail::${line//::/:}"
  done
fi
exit "$status"
