// The task engine. Every tool call becomes a task with a lifecycle:
//
//   pending ──► running ──► completed | failed | cancelled
//      ▲           │
//      └── retry ──┘ (only retry-safe tools, transient errors, bounded)
//   awaiting_approval ──► pending (approved) | cancelled (denied / expired / cancelled)
//
// An approval names the exact action: the approver sends the digest of the
// tool + arguments it showed, and a different digest is refused. Tasks that
// came from the model (MCP) can never approve themselves.

import { EventEmitter } from "node:events";
import type { AuditLog } from "./audit.ts";
import type { ToolPolicy } from "./config.ts";
import type { Scope } from "./devices.ts";
import { validate, withDefaults } from "./schema.ts";
import type { PrepareContext, Risk, TaskView, ToolDefinition, UndoRecord, Verification } from "./tools/types.ts";
import {
  CompanionError,
  canonicalJson,
  nowIso,
  randomId,
  readJsonFile,
  safeEqual,
  sha256Hex,
  truncate,
  writeJsonFileAtomic,
} from "./util.ts";

export type TaskState = "pending" | "awaiting_approval" | "running" | "completed" | "failed" | "cancelled";
export type TaskSource = "phone" | "mcp" | "console";

const TRANSITIONS: Record<TaskState, readonly TaskState[]> = {
  pending: ["running", "cancelled"],
  awaiting_approval: ["pending", "cancelled"],
  running: ["completed", "failed", "cancelled", "pending"],
  completed: [],
  failed: [],
  cancelled: [],
};

export function canTransition(from: TaskState, to: TaskState): boolean {
  return TRANSITIONS[from].includes(to);
}

export function isFinished(state: TaskState): boolean {
  return state === "completed" || state === "failed" || state === "cancelled";
}

export interface TaskApproval {
  required: boolean;
  expiresAt?: string;
  decision?: "approved" | "denied" | "expired";
  decidedBy?: string;
  decidedAt?: string;
}

export interface TaskError {
  code: string;
  message: string;
}

export interface TaskRecord {
  id: string;
  deviceId: string | null;
  source: TaskSource;
  tool: string;
  args: Record<string, unknown>;
  argsDigest: string;
  risk: Risk;
  summary: string;
  warnings: string[];
  state: TaskState;
  createdAt: string;
  updatedAt: string;
  startedAt?: string;
  finishedAt?: string;
  notBefore?: string;
  approval: TaskApproval;
  attempts: number;
  maxAttempts: number;
  timeoutMs: number;
  idempotencyKey?: string;
  progress?: { message: string; at: string };
  result?: unknown;
  resultText?: string;
  unsuccessful?: boolean;
  error?: TaskError;
  verification?: Verification;
  undo?: UndoRecord;
  undoneBy?: string;
}

/** What the phone and MCP clients see: long strings cut, internal undo data reduced to a flag. */
export interface PublicTask extends Omit<TaskRecord, "undo" | "args" | "notBefore"> {
  args: Record<string, unknown>;
  undoAvailable: boolean;
}

export interface SubmitRequest {
  deviceId: string | null;
  source: TaskSource;
  tool: string;
  args: unknown;
  idempotencyKey?: string;
  /** Scopes of the calling device; undefined for the local console (all scopes). */
  scopes?: readonly Scope[];
  /** Set only by a human channel (a tap in the phone UI, the PC console). Never by MCP. */
  preApprovedBy?: string;
}

export interface TaskManagerOptions {
  file: string;
  audit: AuditLog;
  tools: ReadonlyMap<string, ToolDefinition>;
  context: () => Omit<PrepareContext, "lookupTask">;
  policyFor: (tool: ToolDefinition) => ToolPolicy;
  approvalTtlSec: () => number;
  maxConcurrent?: number;
  maxConcurrentExecute?: number;
  retryBaseMs?: number;
  maxStoredTasks?: number;
  expiryCheckMs?: number;
  /** How long a stopped tool may take to clean up before it is abandoned. */
  abortGraceMs?: number;
}

interface RunningEntry {
  controller: AbortController;
  cancelReason?: "user" | "timeout" | "shutdown";
  risk: Risk;
}

const TRANSIENT_CODES = new Set(["EBUSY", "EAGAIN", "EMFILE", "ENFILE"]);

function publicArgs(args: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(args)) {
    out[key] = typeof value === "string" && value.length > 2000 ? `${value.slice(0, 2000)}… (${value.length} karakter)` : value;
  }
  return out;
}

export function toPublicTask(task: TaskRecord): PublicTask {
  const { undo, args, notBefore: _notBefore, ...rest } = task;
  return { ...rest, args: publicArgs(args), undoAvailable: Boolean(undo) && !task.undoneBy && task.state === "completed" };
}

function errorOf(error: unknown): TaskError {
  if (error instanceof CompanionError) return { code: error.code, message: truncate(error.message, 500) };
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  const message = error instanceof Error ? error.message : String(error);
  return { code: typeof code === "string" ? code.toLowerCase() : "tool_error", message: truncate(message, 500) };
}

function isRetryable(error: unknown): boolean {
  if (error instanceof CompanionError) return error.retryable;
  const code = (error as NodeJS.ErrnoException | undefined)?.code;
  return typeof code === "string" && TRANSIENT_CODES.has(code);
}

/**
 * Waits for the tool. After an abort the tool gets `graceMs` to stop cleanly
 * (a command kills its process tree and reports back); a tool that ignores the
 * signal is abandoned after that, so a task never hangs.
 */
function untilAborted<T>(promise: Promise<T>, signal: AbortSignal, graceMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let graceTimer: NodeJS.Timeout | undefined;
    const onAbort = (): void => {
      graceTimer = setTimeout(() => {
        const error = new Error("aborted");
        error.name = "AbortError";
        reject(error);
      }, graceMs);
    };
    if (signal.aborted) onAbort();
    else signal.addEventListener("abort", onAbort, { once: true });
    promise.then(
      (value) => {
        signal.removeEventListener("abort", onAbort);
        if (graceTimer) clearTimeout(graceTimer);
        resolve(value);
      },
      (error) => {
        signal.removeEventListener("abort", onAbort);
        if (graceTimer) clearTimeout(graceTimer);
        reject(error);
      },
    );
  });
}

const DEFAULT_ABORT_GRACE_MS = 5000;

function capResult(result: unknown): unknown {
  const text = JSON.stringify(result ?? null);
  if (text.length <= 200_000) return result;
  return { truncated: true, note: "Sonuç çok büyüktü; özet metni kullan.", size: text.length };
}

interface TaskFile {
  version: 1;
  tasks: TaskRecord[];
}

export class TaskManager extends EventEmitter {
  private readonly options: TaskManagerOptions;
  private readonly tasks = new Map<string, TaskRecord>();
  private readonly running = new Map<string, RunningEntry>();
  private readonly idempotency = new Map<string, string>();
  private persistQueue: Promise<void> = Promise.resolve();
  private expiryTimer: NodeJS.Timeout | undefined;
  private retryTimer: NodeJS.Timeout | undefined;
  private closed = false;

  private constructor(options: TaskManagerOptions) {
    super();
    this.options = options;
  }

  static async open(options: TaskManagerOptions): Promise<TaskManager> {
    const manager = new TaskManager(options);
    const saved = await readJsonFile<TaskFile>(options.file);
    for (const task of saved?.tasks ?? []) manager.tasks.set(task.id, task);
    await manager.recoverAfterRestart();
    manager.expiryTimer = setInterval(() => void manager.expireApprovals(), options.expiryCheckMs ?? 5000);
    manager.expiryTimer.unref();
    return manager;
  }

  /** Work that was running or queued when the companion stopped is never resumed silently. */
  private async recoverAfterRestart(): Promise<void> {
    let changed = false;
    for (const task of this.tasks.values()) {
      if (task.state === "running") {
        this.finish(task, "failed", { code: "interrupted", message: "PC companion yeniden başladı; görev yarıda kaldı. Sonucu kontrol et." });
        changed = true;
      } else if (task.state === "pending") {
        this.finish(task, "cancelled", { code: "interrupted", message: "PC companion yeniden başladı; görev başlamadan durduruldu." });
        changed = true;
      }
      if (task.idempotencyKey) this.idempotency.set(this.idempotencyKeyOf(task.deviceId, task.idempotencyKey), task.id);
    }
    if (changed) {
      await this.persist();
      await this.options.audit.record("tasks.recovered", {});
    }
  }

  get(id: string): TaskRecord | undefined {
    return this.tasks.get(id);
  }

  list(options: { limit?: number; states?: TaskState[] } = {}): TaskRecord[] {
    const all = [...this.tasks.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt) || b.id.localeCompare(a.id));
    const filtered = options.states ? all.filter((task) => options.states?.includes(task.state)) : all;
    return filtered.slice(0, options.limit ?? 50);
  }

  lookupTask = (id: string): TaskView | undefined => {
    const task = this.tasks.get(id);
    if (!task) return undefined;
    return { id: task.id, tool: task.tool, state: task.state, summary: task.summary, undo: task.undo, undoneBy: task.undoneBy, finishedAt: task.finishedAt };
  };

  private prepareContext(): PrepareContext {
    return { ...this.options.context(), lookupTask: this.lookupTask };
  }

  private idempotencyKeyOf(deviceId: string | null, key: string): string {
    return `${deviceId ?? "console"}:${key}`;
  }

  async submit(request: SubmitRequest): Promise<TaskRecord> {
    if (this.closed) throw new CompanionError("shutting_down", "PC companion kapanıyor.", { status: 503 });
    const tool = this.options.tools.get(request.tool);
    if (!tool) throw new CompanionError("unknown_tool", `Bilinmeyen araç: ${request.tool}`, { status: 404 });
    if (request.source === "mcp" && request.preApprovedBy) {
      throw new CompanionError("invalid_request", "Model kanalından gelen bir istek kendi kendini onaylayamaz.", { status: 400 });
    }
    if (request.scopes && !request.scopes.includes(tool.scope)) {
      await this.options.audit.record("task.forbidden", { deviceId: request.deviceId, tool: tool.name, scope: tool.scope });
      throw new CompanionError("forbidden", `Bu cihazın "${tool.scope}" izni yok.`, { status: 403 });
    }
    const policy = this.options.policyFor(tool);
    if (policy === "deny") {
      await this.options.audit.record("task.blocked", { deviceId: request.deviceId, tool: tool.name });
      throw new CompanionError("tool_blocked", `${tool.title} bu bilgisayarda kapalı.`, { status: 403 });
    }

    const raw = request.args ?? {};
    const errors = validate(tool.inputSchema, raw);
    if (errors.length > 0) throw new CompanionError("invalid_arguments", errors.slice(0, 5).join("; "), { status: 400 });
    const args = withDefaults(tool.inputSchema, raw as Record<string, unknown>);

    if (request.idempotencyKey) {
      const existingId = this.idempotency.get(this.idempotencyKeyOf(request.deviceId, request.idempotencyKey));
      const existing = existingId ? this.tasks.get(existingId) : undefined;
      if (existing) {
        if (existing.tool !== tool.name || existing.argsDigest !== this.digest(tool.name, args)) {
          throw new CompanionError("idempotency_conflict", "Aynı istek anahtarı farklı bir işlem için kullanılmış.", { status: 409 });
        }
        return existing;
      }
    }

    // Resolves paths and checks rules without side effects; failures create no task.
    const prepared = await tool.prepare(args, this.prepareContext());
    const risk = prepared.risk ?? tool.risk;
    const needsApproval = policy !== "allow" || risk === "destructive" || risk === "execute";
    const now = nowIso();
    const task: TaskRecord = {
      id: randomId("t"),
      deviceId: request.deviceId,
      source: request.source,
      tool: tool.name,
      args,
      argsDigest: this.digest(tool.name, args),
      risk,
      summary: prepared.summary,
      warnings: prepared.warnings,
      state: needsApproval ? "awaiting_approval" : "pending",
      createdAt: now,
      updatedAt: now,
      approval: needsApproval
        ? { required: true, expiresAt: new Date(Date.now() + this.options.approvalTtlSec() * 1000).toISOString() }
        : { required: false },
      attempts: 0,
      maxAttempts: tool.retrySafe ? 3 : 1,
      timeoutMs: prepared.timeoutMs ?? tool.timeoutMs,
      idempotencyKey: request.idempotencyKey,
    };
    if (needsApproval && request.preApprovedBy) {
      task.approval = { ...task.approval, decision: "approved", decidedBy: request.preApprovedBy, decidedAt: now };
      task.state = "pending";
    }
    this.tasks.set(task.id, task);
    if (request.idempotencyKey) this.idempotency.set(this.idempotencyKeyOf(request.deviceId, request.idempotencyKey), task.id);
    await this.options.audit.record("task.created", {
      taskId: task.id,
      tool: task.tool,
      risk,
      source: task.source,
      deviceId: task.deviceId,
      summary: task.summary,
      state: task.state,
      approvedBy: task.approval.decidedBy ?? null,
    });
    this.changed(task);
    this.schedule();
    return task;
  }

  private digest(tool: string, args: Record<string, unknown>): string {
    return sha256Hex(canonicalJson({ tool, args }));
  }

  async approve(id: string, by: string, argsDigest: unknown, scopes?: readonly Scope[]): Promise<TaskRecord> {
    const task = this.require(id);
    if (scopes && !scopes.includes("tasks:approve")) throw new CompanionError("forbidden", "Bu cihaz onay veremez.", { status: 403 });
    if (task.state !== "awaiting_approval") {
      throw new CompanionError("not_awaiting_approval", "Bu görev onay beklemiyor.", { status: 409 });
    }
    if (this.isExpired(task)) {
      this.expire(task);
      throw new CompanionError("approval_expired", "Onay süresi dolmuş; işlemi yeniden iste.", { status: 410 });
    }
    if (typeof argsDigest !== "string" || !safeEqual(argsDigest, task.argsDigest)) {
      await this.options.audit.record("task.approval_mismatch", { taskId: id, by });
      throw new CompanionError("digest_mismatch", "Onaylanan işlem, bekleyen işlemle aynı değil.", { status: 409 });
    }
    task.approval = { ...task.approval, decision: "approved", decidedBy: by, decidedAt: nowIso() };
    this.transition(task, "pending");
    await this.options.audit.record("task.approved", { taskId: id, by });
    this.changed(task);
    this.schedule();
    return task;
  }

  async deny(id: string, by: string): Promise<TaskRecord> {
    const task = this.require(id);
    if (task.state !== "awaiting_approval") {
      throw new CompanionError("not_awaiting_approval", "Bu görev onay beklemiyor.", { status: 409 });
    }
    task.approval = { ...task.approval, decision: "denied", decidedBy: by, decidedAt: nowIso() };
    this.finish(task, "cancelled", { code: "denied", message: "İşlem onaylanmadı." });
    await this.options.audit.record("task.denied", { taskId: id, by });
    this.changed(task);
    return task;
  }

  async cancel(id: string, by: string): Promise<TaskRecord> {
    const task = this.require(id);
    if (isFinished(task.state)) throw new CompanionError("already_finished", "Görev zaten bitmiş.", { status: 409 });
    await this.options.audit.record("task.cancel_requested", { taskId: id, by, state: task.state });
    const running = this.running.get(id);
    if (running) {
      running.cancelReason = "user";
      running.controller.abort();
      return task;
    }
    if (task.state === "awaiting_approval") task.approval = { ...task.approval, decision: "denied", decidedBy: by, decidedAt: nowIso() };
    this.finish(task, "cancelled", { code: "cancelled", message: "İptal edildi." });
    this.changed(task);
    return task;
  }

  /** Resolves when the task finishes or waits for approval, or after `timeoutMs`. */
  waitForSettle(id: string, timeoutMs: number): Promise<TaskRecord> {
    const task = this.require(id);
    const settled = (t: TaskRecord): boolean => isFinished(t.state) || t.state === "awaiting_approval";
    if (settled(task)) return Promise.resolve(task);
    return new Promise((resolve) => {
      const onTask = (updated: TaskRecord): void => {
        if (updated.id === id && settled(updated)) done();
      };
      const timer = setTimeout(() => done(), timeoutMs);
      const done = (): void => {
        clearTimeout(timer);
        this.off("task", onTask);
        resolve(this.require(id));
      };
      this.on("task", onTask);
    });
  }

  private require(id: string): TaskRecord {
    const task = this.tasks.get(id);
    if (!task) throw new CompanionError("task_not_found", "Görev bulunamadı.", { status: 404 });
    return task;
  }

  private isExpired(task: TaskRecord): boolean {
    return Boolean(task.approval.expiresAt && Date.parse(task.approval.expiresAt) <= Date.now());
  }

  private expire(task: TaskRecord): void {
    task.approval = { ...task.approval, decision: "expired", decidedAt: nowIso() };
    this.finish(task, "cancelled", { code: "approval_expired", message: "Onay süresi doldu." });
    void this.options.audit.record("task.approval_expired", { taskId: task.id });
    this.changed(task);
  }

  /** After the owner changes folders, apps or policy, approvals given for the old rules are void. */
  async voidPendingApprovals(reason: string): Promise<number> {
    let count = 0;
    for (const task of this.tasks.values()) {
      if (task.state !== "awaiting_approval") continue;
      task.approval = { ...task.approval, decision: "denied", decidedBy: "policy", decidedAt: nowIso() };
      this.finish(task, "cancelled", { code: "policy_changed", message: reason });
      this.changed(task);
      count++;
    }
    if (count > 0) await this.options.audit.record("tasks.approvals_voided", { count, reason });
    return count;
  }

  async expireApprovals(): Promise<void> {
    for (const task of this.tasks.values()) {
      if (task.state === "awaiting_approval" && this.isExpired(task)) this.expire(task);
    }
  }

  private transition(task: TaskRecord, to: TaskState): void {
    if (!canTransition(task.state, to)) {
      throw new Error(`Invalid task transition ${task.state} -> ${to} for ${task.id}`);
    }
    task.state = to;
    task.updatedAt = nowIso();
  }

  private finish(task: TaskRecord, state: "completed" | "failed" | "cancelled", error?: TaskError): void {
    this.transition(task, state);
    task.finishedAt = task.updatedAt;
    if (error) task.error = error;
    else delete task.error;
  }

  private changed(task: TaskRecord): void {
    void this.persist();
    this.emit("task", task);
  }

  private schedule(): void {
    if (this.closed) return;
    const maxConcurrent = this.options.maxConcurrent ?? 3;
    const maxExecute = this.options.maxConcurrentExecute ?? 1;
    const pending = [...this.tasks.values()]
      .filter((task) => task.state === "pending")
      .sort((a, b) => a.createdAt.localeCompare(b.createdAt));
    let nextRetryAt = Infinity;
    for (const task of pending) {
      if (this.running.size >= maxConcurrent) break;
      if (task.notBefore) {
        const at = Date.parse(task.notBefore);
        if (at > Date.now()) {
          nextRetryAt = Math.min(nextRetryAt, at);
          continue;
        }
      }
      const executing = [...this.running.values()].filter((entry) => entry.risk === "execute").length;
      if (task.risk === "execute" && executing >= maxExecute) continue;
      void this.run(task);
    }
    if (nextRetryAt !== Infinity) {
      if (this.retryTimer) clearTimeout(this.retryTimer);
      this.retryTimer = setTimeout(() => this.schedule(), Math.max(10, nextRetryAt - Date.now()));
      this.retryTimer.unref();
    }
  }

  private async run(task: TaskRecord): Promise<void> {
    const tool = this.options.tools.get(task.tool);
    const entry: RunningEntry = { controller: new AbortController(), risk: task.risk };
    this.running.set(task.id, entry);
    this.transition(task, "running");
    task.attempts += 1;
    task.startedAt ??= task.updatedAt;
    delete task.notBefore;
    void this.options.audit.record("task.started", { taskId: task.id, tool: task.tool, attempt: task.attempts });
    this.changed(task);

    const timer = setTimeout(() => {
      entry.cancelReason = "timeout";
      entry.controller.abort();
    }, task.timeoutMs);

    try {
      if (!tool) throw new CompanionError("unknown_tool", `Bilinmeyen araç: ${task.tool}`);
      // The owner may have switched the tool off after it was approved.
      if (this.options.policyFor(tool) === "deny") throw new CompanionError("tool_blocked", `${tool.title} bu bilgisayarda kapatıldı.`);
      const context = {
        ...this.prepareContext(),
        taskId: task.id,
        signal: entry.controller.signal,
        progress: (message: string): void => {
          task.progress = { message: truncate(message, 300), at: nowIso() };
          task.updatedAt = task.progress.at;
          this.emit("task", task);
        },
      };
      const outcome = await untilAborted(tool.run(task.args, context), entry.controller.signal, this.options.abortGraceMs ?? DEFAULT_ABORT_GRACE_MS);
      if (entry.cancelReason) {
        // It finished only because it was stopped: report the stop, not a success.
        const stopped = new Error("aborted");
        stopped.name = "AbortError";
        throw stopped;
      }
      task.result = capResult(outcome.result);
      task.resultText = truncate(outcome.text, 2000);
      task.verification = outcome.verification;
      task.unsuccessful = outcome.unsuccessful;
      if (outcome.undo) task.undo = outcome.undo;
      if (outcome.verification && !outcome.verification.ok) {
        this.finish(task, "failed", { code: "verification_failed", message: truncate(outcome.verification.details, 500) });
      } else {
        this.finish(task, "completed");
      }
      if (outcome.undid) {
        const target = this.tasks.get(outcome.undid);
        if (target && task.state === "completed") {
          target.undoneBy = task.id;
          this.changed(target);
        }
      }
    } catch (error) {
      if (entry.cancelReason === "user") {
        this.finish(task, "cancelled", { code: "cancelled", message: "İptal edildi." });
      } else if (entry.cancelReason === "timeout") {
        this.finish(task, "failed", { code: "timeout", message: `Zaman aşımı (${Math.round(task.timeoutMs / 1000)} sn).` });
      } else if (entry.cancelReason === "shutdown") {
        this.finish(task, "failed", { code: "shutdown", message: "PC companion kapanırken görev durduruldu." });
      } else if (tool?.retrySafe && isRetryable(error) && task.attempts < task.maxAttempts) {
        task.error = errorOf(error);
        this.transition(task, "pending");
        const delay = (this.options.retryBaseMs ?? 500) * 2 ** (task.attempts - 1);
        task.notBefore = new Date(Date.now() + delay).toISOString();
        void this.options.audit.record("task.retry_scheduled", { taskId: task.id, attempt: task.attempts, delayMs: delay, errorCode: task.error.code });
      } else {
        this.finish(task, "failed", errorOf(error));
      }
    } finally {
      clearTimeout(timer);
      this.running.delete(task.id);
    }
    void this.options.audit.record(`task.${task.state}`, {
      taskId: task.id,
      tool: task.tool,
      errorCode: task.error?.code ?? null,
      verified: task.verification?.ok ?? null,
    });
    this.changed(task);
    this.schedule();
  }

  private persist(): Promise<void> {
    const write = async (): Promise<void> => {
      const maxStored = this.options.maxStoredTasks ?? 500;
      const all = [...this.tasks.values()].sort((a, b) => a.createdAt.localeCompare(b.createdAt));
      const finished = all.filter((task) => isFinished(task.state));
      const drop = new Set(finished.slice(0, Math.max(0, finished.length - maxStored)).map((task) => task.id));
      for (const id of drop) this.tasks.delete(id);
      const data: TaskFile = { version: 1, tasks: all.filter((task) => !drop.has(task.id)) };
      await writeJsonFileAtomic(this.options.file, data);
    };
    this.persistQueue = this.persistQueue.then(write, write);
    return this.persistQueue;
  }

  async flush(): Promise<void> {
    await this.persistQueue;
  }

  /** Stops timers and running work; running tasks end as failed ("shutdown"). */
  async close(): Promise<void> {
    this.closed = true;
    if (this.expiryTimer) clearInterval(this.expiryTimer);
    if (this.retryTimer) clearTimeout(this.retryTimer);
    for (const entry of this.running.values()) {
      entry.cancelReason = "shutdown";
      entry.controller.abort();
    }
    const deadline = Date.now() + 5000;
    while (this.running.size > 0 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20));
    await this.flush();
  }
}
