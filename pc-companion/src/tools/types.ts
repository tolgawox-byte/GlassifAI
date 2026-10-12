// Shared tool types. A tool declares its risk; the task manager decides from
// the risk and the owner's policy whether it runs at once or waits for a yes.

import type { CompanionConfig } from "../config.ts";
import type { Scope } from "../devices.ts";
import type { PathPolicy } from "../pathPolicy.ts";
import type { JsonSchema } from "../schema.ts";

/**
 * read        — looks only, inside shared folders (runs without asking by default)
 * write       — creates or changes files in folders shared for writing (asks by default)
 * destructive — overwrites or removes (always asks; cannot be set to run silently)
 * execute     — starts a program or an owner-defined command (always asks)
 */
export type Risk = "read" | "write" | "destructive" | "execute";

export interface Verification {
  ok: boolean;
  details: string;
}

export interface UndoRecord {
  kind: "delete_created" | "restore_backup" | "restore_from_trash" | "rename_back" | "remove_created_dir";
  data: Record<string, string>;
}

export interface ToolOutcome {
  /** Structured result for the phone (kept small). */
  result: unknown;
  /** One or two sentences the assistant can say. */
  text: string;
  /** Checked after the action, separately from "the call returned". */
  verification?: Verification;
  undo?: UndoRecord;
  /** True when the tool ran but the thing it ran reported failure (a failing test run). */
  unsuccessful?: boolean;
  /** For undo_task: the task whose effect was reversed. */
  undid?: string;
}

export interface PreparedCall {
  /** What will happen, in words shown on the approval card. */
  summary: string;
  warnings: string[];
  /** A call can be riskier than the tool's default (overwrite=true). */
  risk?: Risk;
  /** Per-call time limit (owner-defined commands carry their own). */
  timeoutMs?: number;
}

export interface TaskView {
  id: string;
  tool: string;
  state: string;
  summary: string;
  undo?: UndoRecord;
  undoneBy?: string;
  finishedAt?: string;
}

export interface PrepareContext {
  policy: PathPolicy;
  config: CompanionConfig;
  dataDir: string;
  lookupTask(id: string): TaskView | undefined;
}

export interface ToolContext extends PrepareContext {
  taskId: string;
  signal: AbortSignal;
  progress(message: string): void;
}

export interface ToolDefinition {
  name: string;
  title: string;
  description: string;
  inputSchema: JsonSchema;
  risk: Risk;
  /** The permission a paired device needs to ask for this tool. */
  scope: Scope;
  /** Safe to run again automatically after a transient error (EBUSY …). */
  retrySafe: boolean;
  timeoutMs: number;
  prepare(args: Record<string, unknown>, ctx: PrepareContext): Promise<PreparedCall>;
  run(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolOutcome>;
}
