import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { after, describe, test } from "node:test";
import { AuditLog, verifyAuditLog } from "../src/audit.ts";
import { defaultConfig } from "../src/config.ts";
import type { ToolPolicy } from "../src/config.ts";
import { PathPolicy } from "../src/pathPolicy.ts";
import { TaskManager, canTransition, isFinished } from "../src/tasks.ts";
import type { TaskRecord } from "../src/tasks.ts";
import type { ToolDefinition } from "../src/tools/types.ts";
import { CompanionError } from "../src/util.ts";
import { tempDir, waitFor } from "./helpers.ts";

const dirs: string[] = [];
after(async () => {
  for (const dir of dirs) await fs.rm(dir, { recursive: true, force: true });
});

let flakyFailures = 0;

function tool(partial: Partial<ToolDefinition> & Pick<ToolDefinition, "name" | "run">): ToolDefinition {
  return {
    title: partial.name,
    description: partial.name,
    inputSchema: { type: "object", additionalProperties: false, properties: { n: { type: "integer" }, text: { type: "string" } } },
    risk: "read",
    scope: "files:read",
    retrySafe: false,
    timeoutMs: 5_000,
    prepare: async () => ({ summary: `${partial.name} çalıştır`, warnings: [] }),
    ...partial,
  };
}

const TOOLS: ToolDefinition[] = [
  tool({ name: "quick", run: async (args) => ({ result: { n: args.n ?? 0 }, text: "tamam" }) }),
  tool({ name: "write_thing", risk: "write", scope: "files:write", run: async () => ({ result: {}, text: "yazıldı", verification: { ok: true, details: "var" } }) }),
  tool({ name: "danger", risk: "destructive", scope: "files:write", run: async () => ({ result: {}, text: "silindi" }) }),
  tool({
    name: "slow",
    run: (_args, ctx) =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(() => resolve({ result: {}, text: "bitti" }), 10_000);
        ctx.signal.addEventListener("abort", () => {
          clearTimeout(timer);
          const error = new Error("aborted");
          error.name = "AbortError";
          reject(error);
        });
      }),
  }),
  tool({ name: "stuck", timeoutMs: 100, run: () => new Promise(() => {}) }),
  tool({
    name: "flaky",
    retrySafe: true,
    run: async () => {
      if (flakyFailures > 0) {
        flakyFailures--;
        const error = new Error("busy") as NodeJS.ErrnoException;
        error.code = "EBUSY";
        throw error;
      }
      return { result: {}, text: "sonunda" };
    },
  }),
  tool({ name: "fails", run: async () => { throw new CompanionError("nope", "olmadı"); } }),
  tool({ name: "unverified", risk: "write", scope: "files:write", run: async () => ({ result: {}, text: "?", verification: { ok: false, details: "dosya yok" } }) }),
  tool({ name: "bad_prepare", prepare: async () => { throw new CompanionError("outside_roots", "dışarıda"); }, run: async () => ({ result: {}, text: "" }) }),
];

async function manager(overrides: Record<string, ToolPolicy> = {}, file?: string): Promise<{ tasks: TaskManager; dir: string; audit: AuditLog }> {
  const dir = file ? path.dirname(file) : await tempDir("jpc-tasks-");
  if (!file) dirs.push(dir);
  const audit = await AuditLog.open(path.join(dir, "audit.log"));
  const config = defaultConfig();
  config.policy.tools = overrides;
  const { policy } = await PathPolicy.create([], { dataDir: dir, systemFolders: [] });
  const map = new Map(TOOLS.map((t) => [t.name, t]));
  const tasks = await TaskManager.open({
    file: file ?? path.join(dir, "tasks.json"),
    audit,
    tools: map,
    context: () => ({ policy, config, dataDir: dir }),
    policyFor: (t) => {
      const o = config.policy.tools[t.name];
      if (o === "deny") return "deny";
      if (t.risk === "destructive" || t.risk === "execute") return "ask";
      return o ?? (t.risk === "read" ? "allow" : "ask");
    },
    approvalTtlSec: () => 600,
    retryBaseMs: 10,
    expiryCheckMs: 20,
    abortGraceMs: 200,
  });
  return { tasks, dir, audit };
}

const settle = (tasks: TaskManager, task: TaskRecord): Promise<TaskRecord> => tasks.waitForSettle(task.id, 5000);

describe("task state machine", () => {
  test("transition table", () => {
    assert.ok(canTransition("pending", "running"));
    assert.ok(canTransition("awaiting_approval", "pending"));
    assert.ok(canTransition("running", "pending"), "retry");
    assert.ok(!canTransition("completed", "running"));
    assert.ok(!canTransition("awaiting_approval", "running"), "approval must queue first");
    assert.ok(!canTransition("cancelled", "pending"));
    assert.ok(isFinished("failed") && !isFinished("running"));
  });

  test("read tools run at once and complete", async () => {
    const { tasks } = await manager();
    const task = await tasks.submit({ deviceId: "d1", source: "phone", tool: "quick", args: { n: 3 } });
    const done = await settle(tasks, task);
    assert.equal(done.state, "completed");
    assert.deepEqual(done.result, { n: 3 });
    assert.equal(done.attempts, 1);
    await tasks.close();
  });

  test("write tools wait for an approval bound to the exact arguments", async () => {
    const { tasks } = await manager();
    const task = await tasks.submit({ deviceId: "d1", source: "mcp", tool: "write_thing", args: { text: "a" } });
    assert.equal(task.state, "awaiting_approval");
    await assert.rejects(tasks.approve(task.id, "phone:d1", "0".repeat(64)), (e: CompanionError) => e.code === "digest_mismatch");
    await assert.rejects(tasks.approve(task.id, "phone:d1", task.argsDigest, ["files:read"]), (e: CompanionError) => e.code === "forbidden");
    await tasks.approve(task.id, "phone:d1", task.argsDigest);
    const done = await settle(tasks, task);
    assert.equal(done.state, "completed");
    assert.equal(done.approval.decision, "approved");
    assert.equal(done.approval.decidedBy, "phone:d1");
    await assert.rejects(tasks.approve(task.id, "phone:d1", task.argsDigest), (e: CompanionError) => e.code === "not_awaiting_approval");
    await tasks.close();
  });

  test("the model channel cannot pre-approve; destructive tools always ask even when allowed", async () => {
    const { tasks } = await manager({ danger: "allow", write_thing: "allow" });
    await assert.rejects(
      tasks.submit({ deviceId: "d1", source: "mcp", tool: "write_thing", args: {}, preApprovedBy: "phone:d1" }),
      (e: CompanionError) => e.code === "invalid_request",
    );
    const allowedWrite = await tasks.submit({ deviceId: "d1", source: "mcp", tool: "write_thing", args: {} });
    assert.equal((await settle(tasks, allowedWrite)).state, "completed", "owner may let plain writes run");
    const danger = await tasks.submit({ deviceId: "d1", source: "mcp", tool: "danger", args: {} });
    assert.equal(danger.state, "awaiting_approval", "destructive can never be silent");
    const phone = await tasks.submit({ deviceId: "d1", source: "phone", tool: "danger", args: {}, preApprovedBy: "phone:d1" });
    assert.equal((await settle(tasks, phone)).state, "completed", "a human tap in the phone UI is an approval");
    await tasks.close();
  });

  test("deny, cancel while waiting, and approval expiry", async () => {
    const { tasks } = await manager();
    const a = await tasks.submit({ deviceId: "d1", source: "mcp", tool: "write_thing", args: { n: 1 } });
    await tasks.deny(a.id, "phone:d1");
    assert.equal(tasks.get(a.id)?.state, "cancelled");
    assert.equal(tasks.get(a.id)?.error?.code, "denied");
    const b = await tasks.submit({ deviceId: "d1", source: "mcp", tool: "write_thing", args: { n: 2 } });
    await tasks.cancel(b.id, "phone:d1");
    assert.equal(tasks.get(b.id)?.state, "cancelled");
    const c = await tasks.submit({ deviceId: "d1", source: "mcp", tool: "write_thing", args: { n: 3 } });
    c.approval.expiresAt = new Date(Date.now() - 1).toISOString();
    await waitFor(() => tasks.get(c.id)?.state === "cancelled");
    assert.equal(tasks.get(c.id)?.error?.code, "approval_expired");
    await tasks.close();
  });

  test("cancelling a running task aborts it", async () => {
    const { tasks } = await manager();
    const task = await tasks.submit({ deviceId: "d1", source: "phone", tool: "slow", args: {} });
    await waitFor(() => tasks.get(task.id)?.state === "running");
    await tasks.cancel(task.id, "phone:d1");
    await waitFor(() => tasks.get(task.id)?.state === "cancelled");
    assert.equal(tasks.get(task.id)?.error?.code, "cancelled");
    await assert.rejects(tasks.cancel(task.id, "x"), (e: CompanionError) => e.code === "already_finished");
    await tasks.close();
  });

  test("a tool that ignores cancellation still ends at its time limit", async () => {
    const { tasks } = await manager();
    const task = await tasks.submit({ deviceId: "d1", source: "phone", tool: "stuck", args: {} });
    const done = await settle(tasks, task);
    assert.equal(done.state, "failed");
    assert.equal(done.error?.code, "timeout");
    await tasks.close();
  });

  test("transient errors are retried only for retry-safe tools, with a limit", async () => {
    const { tasks } = await manager();
    flakyFailures = 2;
    const ok = await tasks.submit({ deviceId: "d1", source: "phone", tool: "flaky", args: { n: 1 } });
    await waitFor(() => isFinished(tasks.get(ok.id)?.state ?? "pending"));
    assert.equal(tasks.get(ok.id)?.state, "completed");
    assert.equal(tasks.get(ok.id)?.attempts, 3);
    flakyFailures = 5;
    const giveUp = await tasks.submit({ deviceId: "d1", source: "phone", tool: "flaky", args: { n: 2 } });
    await waitFor(() => isFinished(tasks.get(giveUp.id)?.state ?? "pending"));
    assert.equal(tasks.get(giveUp.id)?.state, "failed");
    assert.equal(tasks.get(giveUp.id)?.attempts, 3);
    flakyFailures = 0;
    const fails = await tasks.submit({ deviceId: "d1", source: "phone", tool: "fails", args: {} });
    const failed = await settle(tasks, fails);
    assert.equal(failed.attempts, 1, "non-transient errors are not retried");
    assert.deepEqual(failed.error, { code: "nope", message: "olmadı" });
    await tasks.close();
  });

  test("a failed verification fails the task even though the tool returned", async () => {
    const { tasks } = await manager({ unverified: "allow" });
    const task = await tasks.submit({ deviceId: "d1", source: "phone", tool: "unverified", args: {} });
    const done = await settle(tasks, task);
    assert.equal(done.state, "failed");
    assert.equal(done.error?.code, "verification_failed");
    await tasks.close();
  });

  test("bad arguments, blocked tools and failed preparation create no task", async () => {
    const { tasks } = await manager({ quick: "deny" });
    await assert.rejects(tasks.submit({ deviceId: "d1", source: "phone", tool: "quick", args: {} }), (e: CompanionError) => e.code === "tool_blocked");
    await assert.rejects(tasks.submit({ deviceId: "d1", source: "phone", tool: "slow", args: { n: "x" } }), (e: CompanionError) => e.code === "invalid_arguments");
    await assert.rejects(tasks.submit({ deviceId: "d1", source: "phone", tool: "slow", args: { bogus: 1 } }), (e: CompanionError) => e.code === "invalid_arguments");
    await assert.rejects(tasks.submit({ deviceId: "d1", source: "phone", tool: "bad_prepare", args: {} }), (e: CompanionError) => e.code === "outside_roots");
    await assert.rejects(tasks.submit({ deviceId: "d1", source: "phone", tool: "nope", args: {} }), (e: CompanionError) => e.code === "unknown_tool");
    await assert.rejects(
      tasks.submit({ deviceId: "d1", source: "phone", tool: "write_thing", args: {}, scopes: ["files:read"] }),
      (e: CompanionError) => e.code === "forbidden",
    );
    assert.equal(tasks.list().length, 0);
    await tasks.close();
  });

  test("idempotency keys return the same task and refuse a different action", async () => {
    const { tasks } = await manager();
    const first = await tasks.submit({ deviceId: "d1", source: "phone", tool: "quick", args: { n: 1 }, idempotencyKey: "key-12345678" });
    const again = await tasks.submit({ deviceId: "d1", source: "phone", tool: "quick", args: { n: 1 }, idempotencyKey: "key-12345678" });
    assert.equal(again.id, first.id);
    await assert.rejects(
      tasks.submit({ deviceId: "d1", source: "phone", tool: "quick", args: { n: 2 }, idempotencyKey: "key-12345678" }),
      (e: CompanionError) => e.code === "idempotency_conflict",
    );
    const otherDevice = await tasks.submit({ deviceId: "d2", source: "phone", tool: "quick", args: { n: 1 }, idempotencyKey: "key-12345678" });
    assert.notEqual(otherDevice.id, first.id);
    await tasks.close();
  });

  test("after a restart, interrupted work is reported, never resumed silently", async () => {
    const { tasks, dir, audit } = await manager();
    const running = await tasks.submit({ deviceId: "d1", source: "phone", tool: "slow", args: {} });
    await waitFor(() => tasks.get(running.id)?.state === "running");
    const waiting = await tasks.submit({ deviceId: "d1", source: "mcp", tool: "write_thing", args: {} });
    await tasks.flush();
    // Simulate a crash: copy the file that still says "running" and open a second manager on the copy.
    const crashDir = await tempDir("jpc-crash-");
    dirs.push(crashDir);
    await fs.copyFile(path.join(dir, "tasks.json"), path.join(crashDir, "tasks.json"));
    const reopened = await manager({}, path.join(crashDir, "tasks.json"));
    assert.equal(reopened.tasks.get(running.id)?.state, "failed");
    assert.equal(reopened.tasks.get(running.id)?.error?.code, "interrupted");
    assert.equal(reopened.tasks.get(waiting.id)?.state, "awaiting_approval", "approvals survive a restart until they expire");
    await reopened.tasks.close();
    await tasks.close();
    await audit.flush();
    assert.ok((await verifyAuditLog(path.join(dir, "audit.log"))).ok);
  });
});
