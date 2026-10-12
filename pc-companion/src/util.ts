// Small helpers shared by the companion modules. No third-party code.

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";

const BASE32 = "ABCDEFGHJKMNPQRSTVWXYZ0123456789"; // Crockford-like, no I/L/O/U

/** Random identifier such as `t_7KX2M9Q4ZB1C` (60 bits of entropy for 12 characters). */
export function randomId(prefix: string, length = 12): string {
  const bytes = randomBytes(length);
  let out = "";
  for (let i = 0; i < length; i++) out += BASE32[bytes[i] & 31];
  return `${prefix}_${out}`;
}

/** Random code from an alphabet that is easy to read aloud and type. */
export function randomCode(length: number): string {
  const bytes = randomBytes(length);
  let out = "";
  for (let i = 0; i < length; i++) out += BASE32[bytes[i] & 31];
  return out;
}

export function base64url(buffer: Buffer): string {
  return buffer.toString("base64url");
}

export function sha256(data: string | Buffer): Buffer {
  return createHash("sha256").update(data).digest();
}

export function sha256Hex(data: string | Buffer): string {
  return createHash("sha256").update(data).digest("hex");
}

/** Constant-time comparison of two strings of possibly different lengths. */
export function safeEqual(a: string, b: string): boolean {
  const left = sha256(a);
  const right = sha256(b);
  return timingSafeEqual(left, right) && a.length === b.length;
}

/** JSON with sorted object keys, so equal values always hash the same. */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const key of Object.keys(value as Record<string, unknown>).sort()) {
      out[key] = sortKeys((value as Record<string, unknown>)[key]);
    }
    return out;
  }
  return value;
}

export function nowIso(): string {
  return new Date().toISOString();
}

export function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  return text.slice(0, Math.max(0, max - 1)) + "…";
}

/** Keeps the end of a long text, which is where build and test errors usually are. */
export function tail(text: string, max: number): string {
  if (text.length <= max) return text;
  return "…" + text.slice(text.length - max + 1);
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function readJsonFile<T>(file: string): Promise<T | undefined> {
  try {
    const raw = await fs.readFile(file, "utf8");
    return JSON.parse(raw) as T;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return undefined;
    throw error;
  }
}

/** Writes through a temporary file and a rename, so a crash never leaves half a file. */
export async function writeJsonFileAtomic(file: string, value: unknown): Promise<void> {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const temp = `${file}.${process.pid}.${randomCode(6)}.tmp`;
  await fs.writeFile(temp, JSON.stringify(value, null, 2) + "\n", { encoding: "utf8", mode: 0o600 });
  await renameWithRetry(temp, file);
}

/** Windows can briefly refuse a rename while an antivirus scanner holds the target open. */
export async function renameWithRetry(from: string, to: string): Promise<void> {
  for (let attempt = 0; ; attempt++) {
    try {
      await fs.rename(from, to);
      return;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (attempt < 5 && (code === "EPERM" || code === "EBUSY" || code === "EACCES")) {
        await sleep(40 * (attempt + 1));
        continue;
      }
      throw error;
    }
  }
}

export class CompanionError extends Error {
  readonly code: string;
  readonly retryable: boolean;
  readonly status: number;

  constructor(code: string, message: string, options: { retryable?: boolean; status?: number } = {}) {
    super(message);
    this.name = "CompanionError";
    this.code = code;
    this.retryable = options.retryable ?? false;
    this.status = options.status ?? 400;
  }
}

export function isAbortError(error: unknown): boolean {
  return (error as { name?: string } | undefined)?.name === "AbortError";
}
