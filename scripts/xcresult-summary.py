#!/usr/bin/env python3
"""Publishes an .xcresult bundle's test results as GitHub annotations.

Usage: xcresult-summary.py <result.xcresult> <xcodebuild-exit-status> [label]

The label prefixes every annotation title ("" for the main run, "Rerun: "
for classes run again after a simulator failure). Without any test case in
the bundle it exits 3, so a green step always means tests actually ran.
"""
import json
import subprocess
import sys

result_path, status = sys.argv[1], sys.argv[2]
label = sys.argv[3] if len(sys.argv) > 3 else ""


def xcresult(kind):
    output = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", result_path, "--format", "json"],
        capture_output=True, text=True)
    if output.returncode != 0:
        print(f"::warning title={label}xcresult {kind}::{output.stderr.strip()[:300]}")
        return None
    return json.loads(output.stdout)


summary = xcresult("summary") or {}
run_time = ""
try:
    run_time = f", test run {float(summary['finishTime']) - float(summary['startTime']):.0f}s"
except (KeyError, TypeError, ValueError):
    pass
print(
    f"::notice title={label}iOS unit tests::"
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
    print(f"::notice title={label}Slowest iOS tests::" + "; ".join(f"{suite}.{name} {took:.1f}s" for suite, name, _, took in slowest))
if passed:
    print(f"::notice title={label}Passed iOS tests (" + str(len(passed)) + ")::" + "; ".join(passed))
if failed:
    print(f"::error title={label}Failed iOS tests (" + str(len(failed)) + ")::" + "; ".join(failed))
# The assertion messages, so a failure can be fixed from the run page.
for failure in (summary.get("testFailures") or [])[:25]:
    text = " ".join(str(failure.get("failureText", "")).split())[:900]
    print(f"::error title={label}Failure " + str(failure.get("testName", "?")) + "::" + text)
if not cases:
    # A green step must mean tests actually ran.
    print(f"::error title={label}iOS unit tests::No test cases found in the result bundle")
    sys.exit(3)
