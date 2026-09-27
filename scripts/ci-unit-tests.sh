#!/usr/bin/env bash
# Runs the fast, hardware-free unit tests on the first available iPhone simulator.
# The Meta mock-device integration tests are excluded because they depend on
# long fixed sleeps; run them locally in Xcode when touching the DAT pipeline.
# Results are read from the .xcresult bundle and published as GitHub
# annotations so they are visible on the public run page without logs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="${AUTOLOOM_UNIT_TESTS:-GlassifAITests/GlassesGestureInterpreterTests GlassifAITests/AutoLoomCoreTests GlassifAITests/AutoLoomTaskTests}"
LOG="$ROOT/build-tests-output.log"
RESULT="$ROOT/build-tests/UnitTests.xcresult"

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

rm -rf "$RESULT"
set +e
xcodebuild test \
  -project "$ROOT/ios/GlassifAI.xcodeproj" \
  -scheme GlassifAI \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/build-tests" \
  -resultBundlePath "$RESULT" \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY_TESTING[@]}" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

python3 - "$RESULT" "$status" <<'PY'
import json
import subprocess
import sys

result_path, status = sys.argv[1], sys.argv[2]


def xcresult(kind):
    output = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", result_path, "--format", "json"],
        capture_output=True, text=True)
    if output.returncode != 0:
        print(f"::warning title=xcresult {kind}::{output.stderr.strip()[:300]}")
        return None
    return json.loads(output.stdout)


summary = xcresult("summary") or {}
print(
    "::notice title=iOS unit tests::"
    f"result={summary.get('result')} total={summary.get('totalTestCount')} "
    f"passed={summary.get('passedTests')} failed={summary.get('failedTests')} "
    f"skipped={summary.get('skippedTests')} (xcodebuild exit {status})")

cases = []


def walk(node, suite):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind == "Test Case":
        cases.append((suite, name, node.get("result", "?")))
        return
    next_suite = name if kind == "Test Suite" else suite
    for child in node.get("children", []) or []:
        walk(child, next_suite)


tests = xcresult("tests") or {}
for node in tests.get("testNodes", []):
    walk(node, "")

passed = [f"{suite}.{name}" for suite, name, result in cases if result == "Passed"]
failed = [f"{suite}.{name}" for suite, name, result in cases if result not in ("Passed", "Skipped")]
if passed:
    print("::notice title=Passed iOS tests (" + str(len(passed)) + ")::" + "; ".join(passed))
if failed:
    print("::error title=Failed iOS tests (" + str(len(failed)) + ")::" + "; ".join(failed))
if not cases:
    # A green step must mean tests actually ran.
    print("::error title=iOS unit tests::No test cases found in the result bundle")
    sys.exit(3)
PY

exit "$status"
