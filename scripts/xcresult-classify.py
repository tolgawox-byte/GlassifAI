#!/usr/bin/env python3
"""Tells a simulator failure from a test failure in an .xcresult bundle.

Usage: xcresult-classify.py <result.xcresult> <tests-dir> [missing-classes-file]

Prints one JSON object (for the log) and, when every failure is the
simulator's, a GitHub error annotation that says so, writes the classes that
did not run to missing-classes-file (one per line) and exits 10. The JSON:
  infra_only       every failure is the simulator's (a clone that did not
                   boot, a device that could not be prepared), none a test's
  infra_messages   those failure texts
  real_failures    failed test cases outside "System Failures"
  missing_classes  test classes with fewer results than test methods in the
                   source (their tests did not run, for example on a clone
                   that never booted)
  expected, ran    test methods in the source / test cases in the bundle

The CI step uses it to report a simulator failure as such (never as passed)
and to rerun only the classes that did not run. Exit codes: 0 not
simulator-only, 10 simulator-only, 2 the bundle could not be read.
"""
import json
import pathlib
import re
import subprocess
import sys

INFRA_PATTERNS = (
    "failed to prepare device",
    "timed out trying to boot",
    "unable to boot",
    "failed to boot",
    "lost connection to test manager",
    "test runner exited before starting test execution",
    "the test runner hung before establishing connection",
    "simulator device failed to launch",
)
SYSTEM_SUITE = "System Failures"


def xcresult(kind: str, path: str):
    output = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", kind, "--path", path, "--format", "json"],
        capture_output=True, text=True)
    if output.returncode != 0:
        return None
    return json.loads(output.stdout)


def expected_tests(tests_dir: pathlib.Path) -> dict[str, set[str]]:
    """Test methods per XCTestCase class, read from the Swift sources."""
    classes: dict[str, set[str]] = {}
    class_pattern = re.compile(r"^\s*(?:@\w+\s+)*(?:final\s+)?class\s+([A-Za-z0-9_]+)\s*:\s*XCTestCase\b")
    test_pattern = re.compile(r"^\s*(?:@\w+\s+)*func\s+(test[A-Za-z0-9_]*)\s*\(\s*\)")
    for path in sorted(tests_dir.glob("*.swift")):
        current = None
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            match = class_pattern.match(line)
            if match:
                current = match.group(1)
                classes.setdefault(current, set())
                continue
            match = test_pattern.match(line)
            if match and current:
                classes[current].add(match.group(1))
    classes.pop("ViewModelIntegrationTests", None)  # excluded by ci-unit-tests.sh
    return classes


def ran_tests(tree) -> tuple[dict[str, dict[str, str]], list[str]]:
    """Results per class (method -> result), and failed cases outside System Failures."""
    results: dict[str, dict[str, str]] = {}
    real_failures: list[str] = []

    def walk(node, suite):
        kind = node.get("nodeType")
        name = node.get("name", "")
        if kind == "Test Case":
            method = name.split("(")[0]
            outcome = node.get("result", "?")
            results.setdefault(suite, {})[method] = outcome
            if suite != SYSTEM_SUITE and outcome not in ("Passed", "Skipped", "Expected Failure"):
                real_failures.append(f"{suite}.{name}")
            return
        next_suite = name if kind == "Test Suite" else suite
        for child in node.get("children", []) or []:
            walk(child, next_suite)

    for node in (tree or {}).get("testNodes", []):
        walk(node, "")
    return results, real_failures


def main() -> int:
    result_path, tests_dir = sys.argv[1], pathlib.Path(sys.argv[2])
    summary = xcresult("summary", result_path)
    tree = xcresult("tests", result_path)
    if summary is None or tree is None:
        print(json.dumps({"error": "result bundle could not be read"}))
        return 2
    results, real_failures = ran_tests(tree)
    failures = summary.get("testFailures") or []
    texts = [" ".join(str(failure.get("failureText", "")).split()) for failure in failures]
    infra = [text for text in texts if any(pattern in text.lower() for pattern in INFRA_PATTERNS)]
    system_cases = results.get(SYSTEM_SUITE, {})
    infra_only = bool(failures) and not real_failures and len(infra) == len(texts) and bool(system_cases)
    expected = expected_tests(tests_dir)
    missing = sorted(
        name for name, methods in expected.items()
        if methods and len(set(results.get(name, {})) & methods) < len(methods))
    report = {
        "infra_only": infra_only,
        "infra_messages": infra[:5],
        "real_failures": real_failures[:25],
        "missing_classes": missing,
        "expected": sum(len(methods) for methods in expected.values()),
        "ran": sum(len(cases) for suite, cases in results.items() if suite != SYSTEM_SUITE),
    }
    print(json.dumps(report))
    if not infra_only:
        return 0
    message = (infra[0] if infra else "simulator failure")[:300]
    ran_all = "every test ran" if not missing else f"{len(missing)} class(es) did not run and run again on one simulator"
    print(
        "::error title=Simulator infrastructure::Not a test failure. "
        f"{message} Test cases that ran: {report['ran']} of {report['expected']}; {ran_all}. "
        "The step stays red so the problem is not hidden.")
    if len(sys.argv) > 3:
        pathlib.Path(sys.argv[3]).write_text("".join(f"{name}\n" for name in missing), encoding="utf-8")
    return 10


if __name__ == "__main__":
    sys.exit(main())
