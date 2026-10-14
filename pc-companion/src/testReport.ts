// Test results read from a command's output (research idea D2-04): counts
// and failing test names for node --test (spec and TAP), Jest, Vitest,
// pytest, dotnet test, cargo test, go test -v and plain TAP. Output parsing
// only: no file is opened and nothing runs. A summary is compared with the
// previous run of the same command in the same folder ("2 new failures,
// 1 fixed"). Test names come from the project, so they are data: cut short
// and never treated as instructions.

import path from "node:path";
import { nowIso, readJsonFile, truncate, writeJsonFileAtomic } from "./util.ts";

export interface TestSummary {
  framework: string;
  passed: number;
  failed: number;
  skipped: number;
  total: number;
  /** Failing test names, at most 20, each at most 160 characters. */
  failures: string[];
}

export interface TestComparison {
  /** Failing now, not failing in the previous run. */
  newFailures: string[];
  /** Failing in the previous run, not now. */
  fixed: string[];
  previous: { passed: number; failed: number; at: string };
}

const MAX_NAMES = 20;
const MAX_NAME = 160;

function names(list: Iterable<string>): string[] {
  const unique: string[] = [];
  for (const raw of list) {
    const name = truncate(raw.trim(), MAX_NAME);
    if (name && !unique.includes(name)) unique.push(name);
    if (unique.length === MAX_NAMES) break;
  }
  return unique;
}

function count(text: string, pattern: RegExp): number {
  const match = pattern.exec(text);
  return match ? Number(match[1]) : 0;
}

function summary(framework: string, passed: number, failed: number, skipped: number, total: number | undefined, failures: string[]): TestSummary {
  return { framework, passed, failed, skipped, total: total ?? passed + failed + skipped, failures: names(failures) };
}

function linesMatching(lines: string[], pattern: RegExp): string[] {
  const found: string[] = [];
  for (const line of lines) {
    const match = pattern.exec(line);
    if (match?.[1]) found.push(match[1]);
  }
  return found;
}

/** "Failed!  - Failed: 1, Passed: 70, Skipped: 0, Total: 71" (one line per test project). */
function dotnet(text: string, lines: string[]): TestSummary | undefined {
  const pattern = /(?:Passed|Failed)!\s+-\s+Failed:\s*(\d+),\s*Passed:\s*(\d+),\s*Skipped:\s*(\d+),\s*Total:\s*(\d+)/g;
  let passed = 0, failed = 0, skipped = 0, total = 0, seen = false;
  for (const match of text.matchAll(pattern)) {
    seen = true;
    failed += Number(match[1]);
    passed += Number(match[2]);
    skipped += Number(match[3]);
    total += Number(match[4]);
  }
  if (!seen) return undefined;
  return summary("dotnet test", passed, failed, skipped, total, linesMatching(lines, /^\s+Failed\s+(\S.*?)\s+\[[^\]]*\]\s*$/));
}

/** Jest: "Tests:       1 failed, 2 skipped, 70 passed, 73 total". */
function jest(text: string, lines: string[]): TestSummary | undefined {
  const line = /^Tests:\s+(.*\d+ total)\s*$/m.exec(text)?.[1];
  if (!line) return undefined;
  return summary(
    "Jest", count(line, /(\d+) passed/), count(line, /(\d+) failed/), count(line, /(\d+) (?:skipped|todo|pending)/),
    count(line, /(\d+) total/), linesMatching(lines, /^\s*● (.+?)\s*$/).filter((n) => !/^Console$/.test(n)));
}

/** Vitest: " Tests  1 failed | 70 passed (71)". */
function vitest(text: string, lines: string[]): TestSummary | undefined {
  const line = /^\s*Tests\s+(.*)\((\d+)\)\s*$/m.exec(text);
  if (!line || !/passed|failed/.test(line[1] ?? "")) return undefined;
  const parts = line[1] ?? "";
  return summary(
    "Vitest", count(parts, /(\d+) passed/), count(parts, /(\d+) failed/), count(parts, /(\d+) (?:skipped|todo)/),
    Number(line[2]), linesMatching(lines, /^\s*(?:×|✗|FAIL)\s+(.+?)(?:\s+\d+ms)?\s*$/));
}

/** pytest: "===== 1 failed, 70 passed, 2 skipped in 1.23s =====". */
function pytest(text: string, lines: string[]): TestSummary | undefined {
  const line = /^=+ (.*\b(?:passed|failed|error|errors)\b.*) in [\d.]+s(?: \([^)]*\))? =+\s*$/m.exec(text)?.[1];
  if (!line) return undefined;
  const failed = count(line, /(\d+) failed/) + count(line, /(\d+) errors?/);
  return summary(
    "pytest", count(line, /(\d+) passed/), failed, count(line, /(\d+) skipped/), undefined,
    linesMatching(lines, /^(?:FAILED|ERROR) (\S+)/));
}

/** cargo test: "test result: FAILED. 12 passed; 1 failed; 0 ignored; …" (one per test binary). */
function cargo(text: string, lines: string[]): TestSummary | undefined {
  const pattern = /^test result: \w+\. (\d+) passed; (\d+) failed; (\d+) ignored/gm;
  let passed = 0, failed = 0, skipped = 0, seen = false;
  for (const match of text.matchAll(pattern)) {
    seen = true;
    passed += Number(match[1]);
    failed += Number(match[2]);
    skipped += Number(match[3]);
  }
  if (!seen) return undefined;
  return summary("cargo test", passed, failed, skipped, undefined, linesMatching(lines, /^test (\S+) \.\.\. FAILED\s*$/));
}

/** go test -v: "--- PASS: TestX (0.00s)", "--- FAIL: TestY", "--- SKIP: TestZ". */
function goTest(_text: string, lines: string[]): TestSummary | undefined {
  const passed = linesMatching(lines, /^\s*--- PASS: (\S+)/).length;
  const failures = linesMatching(lines, /^\s*--- FAIL: (\S+)/);
  const skipped = linesMatching(lines, /^\s*--- SKIP: (\S+)/).length;
  if (passed + failures.length + skipped === 0) return undefined;
  return summary("go test", passed, failures.length, skipped, undefined, failures);
}

/** node --test with the spec reporter (Node 24's default): "ℹ tests 71", "ℹ pass 70", "✖ name (12ms)". */
function nodeSpec(text: string, lines: string[]): TestSummary | undefined {
  if (!/^ℹ tests \d+/m.test(text)) return undefined;
  const failures = linesMatching(lines, /^\s*✖ (.+?) \([\d.]+m?s\)\s*$/).filter((n) => n !== "failing tests:");
  return summary(
    "node --test", count(text, /^ℹ pass (\d+)/m), count(text, /^ℹ fail (\d+)/m) + count(text, /^ℹ cancelled (\d+)/m),
    count(text, /^ℹ skipped (\d+)/m) + count(text, /^ℹ todo (\d+)/m), count(text, /^ℹ tests (\d+)/m), failures);
}

/** TAP (node --test's TAP reporter, Mocha, tape …): "# pass 70", "not ok 3 - name", or counted lines. */
function tap(text: string, lines: string[]): TestSummary | undefined {
  const failures = linesMatching(lines, /^\s*not ok \d+(?: -)? (.+?)(?:\s+#\s*(?:TODO|todo).*)?$/);
  if (/^# (?:tests|pass) \d+/m.test(text)) {
    return summary(
      "TAP", count(text, /^# pass (\d+)/m), count(text, /^# fail (\d+)/m) + count(text, /^# cancelled (\d+)/m),
      count(text, /^# skip(?:ped)? (\d+)/m) + count(text, /^# todo (\d+)/m), count(text, /^# tests (\d+)/m) || undefined, failures);
  }
  if (!/^\s*(?:not )?ok \d+/m.test(text)) return undefined;
  let passed = 0, failed = 0, skipped = 0;
  for (const line of lines) {
    if (/^\s*ok \d+/.test(line)) {
      if (/#\s*SKIP/i.test(line)) skipped++;
      else passed++;
    } else if (/^\s*not ok \d+/.test(line)) {
      if (/#\s*TODO/i.test(line)) skipped++;
      else failed++;
    }
  }
  return summary("TAP", passed, failed, skipped, undefined, failures);
}

const PARSERS = [dotnet, jest, vitest, pytest, cargo, goTest, nodeSpec, tap];

/** The test results in a command's output, or undefined when it shows none. */
export function parseTestOutput(output: string): TestSummary | undefined {
  const text = output.replace(/\u001b\[[0-9;]*m/g, "").replace(/\r\n?/g, "\n");
  const lines = text.split("\n");
  for (const parser of PARSERS) {
    const found = parser(text, lines);
    if (found && found.total > 0) return found;
  }
  return undefined;
}

/** "70 geçti, 1 başarısız, 2 atlandı" (the companion speaks Turkish). */
export function describeSummary(summary: TestSummary): string {
  const parts = [`${summary.passed} geçti`];
  if (summary.failed > 0) parts.push(`${summary.failed} başarısız`);
  if (summary.skipped > 0) parts.push(`${summary.skipped} atlandı`);
  return `${summary.framework}: ${parts.join(", ")}`;
}

export function compareRuns(current: TestSummary, previous: StoredRun): TestComparison {
  return {
    newFailures: current.failures.filter((name) => !previous.failures.includes(name)),
    fixed: previous.failures.filter((name) => !current.failures.includes(name)),
    previous: { passed: previous.passed, failed: previous.failed, at: previous.at },
  };
}

export function describeComparison(comparison: TestComparison): string | undefined {
  const parts: string[] = [];
  if (comparison.newFailures.length > 0) {
    parts.push(`${comparison.newFailures.length} yeni başarısız (${truncate(comparison.newFailures.slice(0, 3).join(", "), 200)})`);
  }
  if (comparison.fixed.length > 0) parts.push(`${comparison.fixed.length} düzeldi`);
  return parts.length > 0 ? `Önceki çalıştırmaya göre: ${parts.join(", ")}.` : undefined;
}

export interface StoredRun {
  at: string;
  passed: number;
  failed: number;
  failures: string[];
}

const MAX_KEYS = 50;

/** The last summary of each command in each folder, in the companion's data folder. */
export class TestHistory {
  private readonly file: string;

  constructor(dataDir: string) {
    this.file = path.join(dataDir, "test-history.json");
  }

  static key(commandId: string, folder: string): string {
    return `${commandId}|${folder}`;
  }

  async previous(key: string): Promise<StoredRun | undefined> {
    const data = (await readJsonFile<Record<string, StoredRun>>(this.file).catch(() => undefined)) ?? {};
    return data[key];
  }

  async record(key: string, current: TestSummary): Promise<void> {
    const data = (await readJsonFile<Record<string, StoredRun>>(this.file).catch(() => undefined)) ?? {};
    delete data[key];
    data[key] = { at: nowIso(), passed: current.passed, failed: current.failed, failures: current.failures };
    const keys = Object.keys(data);
    for (const old of keys.slice(0, Math.max(0, keys.length - MAX_KEYS))) delete data[old];
    await writeJsonFileAtomic(this.file, data);
  }
}
