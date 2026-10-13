#!/usr/bin/env bash
# Runs the fast, hardware-free unit tests on the first available iPhone simulator.
# The Meta mock-device integration tests are excluded because they depend on
# long fixed sleeps; run them locally in Xcode when touching the DAT pipeline.
# Results are read from the .xcresult bundle and published as GitHub
# annotations so they are visible on the public run page without logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Every XCTestCase class in the test target, except the Meta mock-device
# integration tests. Discovered automatically so a new class cannot be missed.
DISCOVERED="$(grep -hoE '^(final )?class [A-Za-z0-9_]+: XCTestCase' "$ROOT"/ios/GlassifAITests/*.swift \
  | sed -E 's/^(final )?class ([A-Za-z0-9_]+):.*/\2/' \
  | grep -v '^ViewModelIntegrationTests$' \
  | sed 's#^#GlassifAITests/#' | tr '\n' ' ')"
TESTS="${AUTOLOOM_UNIT_TESTS:-$DISCOVERED}"
echo "Test classes: $TESTS"
LOG="$ROOT/build-tests-output.log"
RESULT="$ROOT/build-tests/UnitTests.xcresult"
RERUN_RESULT="$ROOT/build-tests/UnitTestsRerun.xcresult"
MISSING="$ROOT/build-tests/missing-classes.txt"

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

rm -rf "$RESULT" "$RERUN_RESULT" "$MISSING"
# A test that hangs fails on its own after its time allowance (named in the
# results) instead of the whole step being killed without any results.
# Parallel testing clones the simulator once per worker; on a slow runner a
# clone can miss its 60-second boot (phase 1c, run 38330128872). Two workers
# keep most of the speed with fewer simulators booting at once.
set +e
xcodebuild test \
  -project "$ROOT/ios/GlassifAI.xcodeproj" \
  -scheme GlassifAI \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/build-tests" \
  -resultBundlePath "$RESULT" \
  -maximum-parallel-testing-workers 2 \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 300 \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY_TESTING[@]}" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

# The voice evaluation's report (AutoLoomVoiceEvaluationTests writes it in the
# test app's temporary folder on the simulator).
# Tests may run on a clone of the simulator (XCTestDevices), so look everywhere.
EVAL="$(find "$HOME/Library/Developer/CoreSimulator/Devices" "$HOME/Library/Developer/XCTestDevices" \
  -name autoloom-voice-eval.txt -mmin -90 2>/dev/null | head -n 1 || true)"
if [ -n "$EVAL" ]; then
  head -n 16 "$EVAL" | while IFS= read -r line; do echo "::notice title=Voice evaluation::${line}"; done || true
fi

if [ "$status" -ne 0 ]; then
  # Test-target compile errors, visible without the raw log.
  grep -E ": error: " "$LOG" | sed "s|$ROOT/||g" | sort -u | head -n 40 \
    | while IFS= read -r line; do echo "::error title=Test build::${line}"; done || true
fi

# A failure that is only the simulator's (a clone that never booted) is
# reported as such and keeps the step red; the classes that did not run
# because of it run again on one simulator, without clones.
if [ "$status" -ne 0 ] && [ -d "$RESULT" ]; then
  set +e
  python3 "$ROOT/scripts/xcresult-classify.py" "$RESULT" "$ROOT/ios/GlassifAITests" "$MISSING"
  classified=$?
  set -e
  if [ "$classified" -eq 10 ] && [ -s "$MISSING" ]; then
    RERUN=()
    while IFS= read -r class_name; do
      [ -n "$class_name" ] && RERUN+=("-only-testing:GlassifAITests/$class_name")
    done < "$MISSING"
    set +e
    xcodebuild test-without-building \
      -project "$ROOT/ios/GlassifAI.xcodeproj" \
      -scheme GlassifAI \
      -configuration Debug \
      -destination "platform=iOS Simulator,id=$UDID" \
      -derivedDataPath "$ROOT/build-tests" \
      -resultBundlePath "$RERUN_RESULT" \
      -parallel-testing-enabled NO \
      -test-timeouts-enabled YES \
      -default-test-execution-time-allowance 180 \
      -maximum-test-execution-time-allowance 300 \
      CODE_SIGNING_ALLOWED=NO \
      "${RERUN[@]}" 2>&1 | tee -a "$LOG"
    rerun_status=${PIPESTATUS[0]}
    set -e
    python3 "$ROOT/scripts/xcresult-summary.py" "$RERUN_RESULT" "$rerun_status" "Rerun: " || true
  fi
fi

python3 "$ROOT/scripts/xcresult-summary.py" "$RESULT" "$status"

exit "$status"
