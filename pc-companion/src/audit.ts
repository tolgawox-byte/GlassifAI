// Append-only audit log (JSON lines). Each entry carries the hash of the
// previous one, so editing or deleting a line breaks the chain and
// `jarvis-pc audit verify` reports where.
//
// Never logged: tokens, pairing codes, file contents, command output.

import { promises as fs } from "node:fs";
import path from "node:path";
import { canonicalJson, sha256Hex, truncate } from "./util.ts";

export interface AuditEntry {
  ts: string;
  seq: number;
  type: string;
  [field: string]: unknown;
}

const GENESIS = "0".repeat(64);
const FORBIDDEN_KEYS = /token|secret|password|code|content|output|stdout|stderr|authorization/i;

/** Keeps entries small and free of secrets: strings are cut, suspicious keys dropped. */
export function sanitizeAuditFields(fields: Record<string, unknown>, depth = 0): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(fields)) {
    const harmless = typeof value === "number" || typeof value === "boolean" || key === "errorCode";
    if (FORBIDDEN_KEYS.test(key) && !harmless) {
      out[key] = "[redacted]";
      continue;
    }
    if (typeof value === "string") out[key] = truncate(value, 300);
    else if (typeof value === "number" || typeof value === "boolean" || value === null) out[key] = value;
    else if (Array.isArray(value)) out[key] = value.slice(0, 20).map((item) => (typeof item === "string" ? truncate(item, 200) : item));
    else if (value && typeof value === "object" && depth < 2) out[key] = sanitizeAuditFields(value as Record<string, unknown>, depth + 1);
  }
  return out;
}

export class AuditLog {
  private readonly file: string;
  private lastHash = GENESIS;
  private seq = 0;
  private queue: Promise<void> = Promise.resolve();

  private constructor(file: string) {
    this.file = file;
  }

  static async open(file: string): Promise<AuditLog> {
    const log = new AuditLog(file);
    await fs.mkdir(path.dirname(file), { recursive: true });
    try {
      const raw = await fs.readFile(file, "utf8");
      const lines = raw.split("\n").filter((line) => line.trim().length > 0);
      const last = lines.at(-1);
      if (last) {
        const parsed = JSON.parse(last) as { hash?: string; seq?: number };
        log.lastHash = typeof parsed.hash === "string" ? parsed.hash : GENESIS;
        log.seq = typeof parsed.seq === "number" ? parsed.seq : lines.length;
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    return log;
  }

  /** Appends one event. Writes are serialized so the chain stays in order. */
  record(type: string, fields: Record<string, unknown> = {}): Promise<void> {
    const write = async (): Promise<void> => {
      this.seq += 1;
      const entry: AuditEntry = { ts: new Date().toISOString(), seq: this.seq, type, ...sanitizeAuditFields(fields) };
      const hash = sha256Hex(this.lastHash + canonicalJson(entry));
      const line = JSON.stringify({ ...entry, prev: this.lastHash, hash }) + "\n";
      await fs.appendFile(this.file, line, { encoding: "utf8", mode: 0o600 });
      this.lastHash = hash;
    };
    this.queue = this.queue.then(write, write);
    return this.queue;
  }

  async flush(): Promise<void> {
    await this.queue;
  }

  /** Reads the newest entries (for the phone's activity view and the console). */
  async recent(limit: number): Promise<AuditEntry[]> {
    await this.flush();
    try {
      const raw = await fs.readFile(this.file, "utf8");
      return raw
        .split("\n")
        .filter((line) => line.trim().length > 0)
        .slice(-limit)
        .map((line) => {
          const { prev: _prev, hash: _hash, ...entry } = JSON.parse(line) as AuditEntry & { prev: string; hash: string };
          return entry as AuditEntry;
        });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }
  }
}

export interface AuditVerification {
  ok: boolean;
  entries: number;
  /** 1-based line number of the first broken entry. */
  brokenAtLine?: number;
  reason?: string;
}

export async function verifyAuditLog(file: string): Promise<AuditVerification> {
  let raw: string;
  try {
    raw = await fs.readFile(file, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { ok: true, entries: 0 };
    throw error;
  }
  const lines = raw.split("\n");
  let previous = GENESIS;
  let count = 0;
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (line.trim().length === 0) continue;
    let parsed: AuditEntry & { prev?: string; hash?: string };
    try {
      parsed = JSON.parse(line);
    } catch {
      return { ok: false, entries: count, brokenAtLine: index + 1, reason: "satır JSON değil" };
    }
    const { prev, hash, ...entry } = parsed;
    if (prev !== previous) return { ok: false, entries: count, brokenAtLine: index + 1, reason: "önceki kayıtla bağ kopuk" };
    if (sha256Hex(previous + canonicalJson(entry)) !== hash) {
      return { ok: false, entries: count, brokenAtLine: index + 1, reason: "kayıt değiştirilmiş" };
    }
    previous = hash as string;
    count += 1;
  }
  return { ok: true, entries: count };
}
