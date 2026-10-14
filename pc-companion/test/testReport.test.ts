import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { after, before, describe, test } from "node:test";
import type { CompanionCore } from "../src/core.ts";
import type { TaskRecord } from "../src/tasks.ts";
import { compareRuns, describeComparison, describeSummary, parseTestOutput, TestHistory } from "../src/testReport.ts";
import { makeCore, tempDir } from "./helpers.ts";
import type { TestCore } from "./helpers.ts";

describe("test output (research D2-04)", () => {
  test("node --test, spec reporter (Node 24's default)", () => {
    const output = [
      "▶ programs and commands",
      "  ✔ run_command: success, failure with output tail, and the folder rule (179.0818ms)",
      "  ✖ run_command can be cancelled (the process tree is killed) and times out (5703.8771ms)",
      "✖ programs and commands (5897.698ms)",
      "ℹ tests 71",
      "ℹ suites 12",
      "ℹ pass 70",
      "ℹ fail 1",
      "ℹ cancelled 0",
      "ℹ skipped 0",
      "ℹ todo 0",
      "✖ failing tests:",
      "test at test/tools.test.ts:264:3",
      "✖ run_command can be cancelled (the process tree is killed) and times out (5703.8771ms)",
    ].join("\n");
    const summary = parseTestOutput(output);
    assert.equal(summary?.framework, "node --test");
    assert.deepEqual([summary?.passed, summary?.failed, summary?.skipped, summary?.total], [70, 1, 0, 71]);
    assert.ok(summary?.failures.includes("run_command can be cancelled (the process tree is killed) and times out"));
    assert.ok(!summary?.failures.includes("failing tests:"));
  });

  test("TAP: node's TAP reporter and plain ok / not ok lines", () => {
    const reporter = parseTestOutput("TAP version 13\nok 1 - parses\nnot ok 2 - adds numbers\n1..2\n# tests 2\n# pass 1\n# fail 1\n# skipped 0\n");
    assert.deepEqual([reporter?.framework, reporter?.passed, reporter?.failed, reporter?.total], ["TAP", 1, 1, 2]);
    assert.deepEqual(reporter?.failures, ["adds numbers"]);
    const plain = parseTestOutput("1..4\nok 1 one\nok 2 two # SKIP no network\nnot ok 3 three\nnot ok 4 four # TODO later\n");
    assert.deepEqual([plain?.passed, plain?.failed, plain?.skipped, plain?.total], [1, 1, 2, 4]);
  });

  test("Jest and Vitest", () => {
    const jest = parseTestOutput("  ● Cart › adds a line\n\n    expect(received)\nTests:       1 failed, 2 skipped, 70 passed, 73 total\nTime: 2 s\n");
    assert.deepEqual([jest?.framework, jest?.passed, jest?.failed, jest?.skipped, jest?.total], ["Jest", 70, 1, 2, 73]);
    assert.deepEqual(jest?.failures, ["Cart › adds a line"]);
    const vitest = parseTestOutput(" × src/cart.test.ts > Cart > adds a line 12ms\n Test Files  1 failed | 4 passed (5)\n      Tests  1 failed | 70 passed (71)\n");
    assert.deepEqual([vitest?.framework, vitest?.passed, vitest?.failed, vitest?.total], ["Vitest", 70, 1, 71]);
    assert.deepEqual(vitest?.failures, ["src/cart.test.ts > Cart > adds a line"]);
  });

  test("pytest, dotnet test (two projects), cargo test, go test -v", () => {
    const pytest = parseTestOutput("FAILED tests/test_cart.py::test_total - AssertionError: 3 != 4\n===== 1 failed, 70 passed, 2 skipped in 1.23s =====\n");
    assert.deepEqual([pytest?.framework, pytest?.passed, pytest?.failed, pytest?.skipped, pytest?.total], ["pytest", 70, 1, 2, 73]);
    assert.deepEqual(pytest?.failures, ["tests/test_cart.py::test_total"]);
    const dotnet = parseTestOutput([
      "  Failed Shop.Tests.CartTests.AddsALine [12 ms]",
      "Failed!  - Failed:     1, Passed:    40, Skipped:     0, Total:    41, Duration: 1 s - Shop.Tests.dll (net8.0)",
      "Passed!  - Failed:     0, Passed:    30, Skipped:     2, Total:    32, Duration: 1 s - Api.Tests.dll (net8.0)",
    ].join("\r\n"));
    assert.deepEqual([dotnet?.passed, dotnet?.failed, dotnet?.skipped, dotnet?.total], [70, 1, 2, 73]);
    assert.deepEqual(dotnet?.failures, ["Shop.Tests.CartTests.AddsALine"]);
    const cargo = parseTestOutput("test tests::reconnect ... FAILED\ntest result: FAILED. 12 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out\ntest result: ok. 3 passed; 0 failed; 1 ignored; 0 measured\n");
    assert.deepEqual([cargo?.passed, cargo?.failed, cargo?.skipped], [15, 1, 1]);
    assert.deepEqual(cargo?.failures, ["tests::reconnect"]);
    const go = parseTestOutput("=== RUN TestA\n--- PASS: TestA (0.00s)\n--- FAIL: TestB (0.01s)\n--- SKIP: TestC (0.00s)\nFAIL\n");
    assert.deepEqual([go?.framework, go?.passed, go?.failed, go?.skipped], ["go test", 1, 1, 1]);
  });

  test("colours are ignored; output without tests gives nothing", () => {
    const coloured = parseTestOutput("\u001b[32mℹ tests 3\u001b[39m\nℹ pass 3\nℹ fail 0\n");
    assert.equal(coloured?.passed, 3);
    assert.equal(parseTestOutput("Build succeeded.\n0 Warning(s)\n0 Error(s)\n"), undefined);
    assert.equal(parseTestOutput("ℹ tests 0\nℹ pass 0\n"), undefined, "zero tests is not a test result");
  });

  test("names are data: at most 20, each cut short", () => {
    const lines = Array.from({ length: 30 }, (_, i) => `not ok ${i + 1} - ${i} ${"x".repeat(300)}`);
    const summary = parseTestOutput(lines.join("\n"));
    assert.equal(summary?.failed, 30);
    assert.equal(summary?.failures.length, 20);
    assert.ok(summary?.failures.every((name) => name.length <= 160));
  });

  test("a run is compared with the previous one", () => {
    const current = { framework: "TAP", passed: 9, failed: 2, skipped: 0, total: 11, failures: ["b", "c"] };
    const comparison = compareRuns(current, { at: "2026-10-14T03:00:00Z", passed: 9, failed: 2, failures: ["a", "b"] });
    assert.deepEqual(comparison.newFailures, ["c"]);
    assert.deepEqual(comparison.fixed, ["a"]);
    assert.equal(describeComparison(comparison), "Önceki çalıştırmaya göre: 1 yeni başarısız (c), 1 düzeldi.");
    assert.equal(describeSummary(current), "TAP: 9 geçti, 2 başarısız");
    assert.equal(describeComparison(compareRuns(current, { at: "x", passed: 9, failed: 2, failures: ["b", "c"] })), undefined);
  });

  test("the history keeps the last run per command and folder, at most 50", async () => {
    const dir = await tempDir("jpc-tests-");
    try {
      const history = new TestHistory(dir);
      const summary = { framework: "TAP", passed: 1, failed: 1, skipped: 0, total: 2, failures: ["a"] };
      for (let i = 0; i < 55; i++) await history.record(TestHistory.key("test", `Projeler/p${i}`), summary);
      assert.equal(await history.previous(TestHistory.key("test", "Projeler/p0")), undefined, "the oldest are dropped");
      assert.deepEqual((await history.previous(TestHistory.key("test", "Projeler/p54")))?.failures, ["a"]);
      const stored = JSON.parse(await fs.readFile(path.join(dir, "test-history.json"), "utf8")) as Record<string, unknown>;
      assert.equal(Object.keys(stored).length, 50);
    } finally {
      await fs.rm(dir, { recursive: true, force: true });
    }
  });
});

describe("run_command with a test run", () => {
  let t: TestCore;
  let core: CompanionCore;

  before(async () => {
    t = await makeCore({
      configure: (config) => {
        const script = (fail: string): string =>
          `console.log('ok 1 - a'); console.log('not ok 2 - ${fail}'); console.log('# tests 2'); console.log('# pass 1'); console.log('# fail 1'); process.exit(0)`;
        config.commands = [
          { id: "tests1", label: "Testler", exe: process.execPath, args: ["-e", script("b")], shell: false, timeoutSec: 30, needsWriteAccess: false },
          { id: "tests2", label: "Testler", exe: process.execPath, args: ["-e", script("c")], shell: false, timeoutSec: 30, needsWriteAccess: false },
        ];
      },
    });
    core = t.core;
  });

  after(async () => {
    await t.cleanup();
  });

  async function run(command: string): Promise<TaskRecord> {
    const task = await core.tasks.submit({ deviceId: "d", source: "phone", tool: "run_command", args: { command, path: "Projeler" }, preApprovedBy: "phone:d" });
    return core.tasks.waitForSettle(task.id, 15_000);
  }

  test("counts, a failing test is never a success, and the change since the last run", async () => {
    const first = await run("tests1");
    assert.equal(first.state, "completed", first.error?.message);
    assert.equal(first.unsuccessful, true, "exit code 0 with a failing test is not a success");
    assert.match(first.resultText ?? "", /TAP: 1 geçti, 1 başarısız/);
    assert.deepEqual((first.result as { tests: { failures: string[] } }).tests.failures, ["b"]);
    assert.doesNotMatch(first.resultText ?? "", /Önceki/, "nothing to compare with yet");
    // The same command id in the same folder: its previous run is the one to compare with.
    await core.tasks.waitForSettle(first.id, 1_000);
    const history = new TestHistory(t.dataDir);
    await history.record(TestHistory.key("tests2", "Projeler"), { framework: "TAP", passed: 1, failed: 1, skipped: 0, total: 2, failures: ["b"] });
    const second = await run("tests2");
    assert.match(second.resultText ?? "", /1 yeni başarısız \(c\), 1 düzeldi/);
  });
});
