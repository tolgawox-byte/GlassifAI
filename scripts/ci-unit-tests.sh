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
# A test that hangs fails on its own after its time allowance (named in the
# results) instead of the whole step being killed without any results.
set +e
xcodebuild test \
  -project "$ROOT/ios/GlassifAI.xcodeproj" \
  -scheme GlassifAI \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$ROOT/build-tests" \
  -resultBundlePath "$RESULT" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 300 \
  CODE_SIGNING_ALLOWED=NO \
  "${ONLY_TESTING[@]}" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
  # Test-target compile errors, visible without the raw log.
  grep -E ": error: " "$LOG" | sed "s|$ROOT/||g" | sort -u | head -n 40 \
    | while IFS= read -r line; do echo "::error title=Test build::${line}"; done || true
fi

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
run_time = ""
try:
    run_time = f", test run {float(summary['finishTime']) - float(summary['startTime']):.0f}s"
except (KeyError, TypeError, ValueError):
    pass
print(
    "::notice title=iOS unit tests::"
    f"result={summary.get('result')} total={summary.get('totalTestCount')} "
    f"passed={summary.get('passedTests')} failed={summary.get('failedTests')} "
    f"skipped={summary.get('skippedTests')} (xcodebuild exit {status}{run_time})")

cases = []


def seconds(node):
    value = node.get("durationInSeconds")
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(node.get("duration", "")).replace(",", ".").rstrip("s").strip())
    except ValueError:
        return 0.0


def walk(node, suite):
    kind = node.get("nodeType")
    name = node.get("name", "")
    if kind == "Test Case":
        cases.append((suite, name, node.get("result", "?"), seconds(node)))
        return
    next_suite = name if kind == "Test Suite" else suite
    for child in node.get("children", []) or []:
        walk(child, next_suite)


tests = xcresult("tests") or {}
for node in tests.get("testNodes", []):
    walk(node, "")

passed = [f"{suite}.{name}" for suite, name, result, _ in cases if result == "Passed"]
failed = [f"{suite}.{name}" for suite, name, result, _ in cases if result not in ("Passed", "Skipped")]
slowest = sorted(cases, key=lambda case: case[3], reverse=True)[:5]
if slowest and slowest[0][3] > 0:
    print("::notice title=Slowest iOS tests::" + "; ".join(f"{suite}.{name} {took:.1f}s" for suite, name, _, took in slowest))
if passed:
    print("::notice title=Passed iOS tests (" + str(len(passed)) + ")::" + "; ".join(passed))
if failed:
    print("::error title=Failed iOS tests (" + str(len(failed)) + ")::" + "; ".join(failed))
# The assertion messages, so a failure can be fixed from the run page.
for failure in (summary.get("testFailures") or [])[:25]:
    text = " ".join(str(failure.get("failureText", "")).split())[:900]
    print("::error title=Failure " + str(failure.get("testName", "?")) + "::" + text)
if not cases:
    # A green step must mean tests actually ran.
    print("::error title=iOS unit tests::No test cases found in the result bundle")
    sys.exit(3)
PY

exit "$status"
