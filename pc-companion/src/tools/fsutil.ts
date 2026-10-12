// File helpers for the tools: bounded directory walks, text decoding, binary
// detection and search normalization (Turkish-aware, accent-insensitive).

import { createHash } from "node:crypto";
import { createReadStream, promises as fs } from "node:fs";
import type { Dirent } from "node:fs";
import path from "node:path";
import { CompanionError } from "../util.ts";

export const TEXT_EXTENSIONS = new Set([
  ".txt", ".md", ".markdown", ".rst", ".csv", ".tsv", ".json", ".jsonc", ".yaml", ".yml", ".xml", ".html",
  ".htm", ".css", ".scss", ".less", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".vue", ".svelte", ".swift",
  ".kt", ".kts", ".java", ".py", ".rb", ".go", ".rs", ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".fs", ".sql",
  ".sh", ".bash", ".zsh", ".ps1", ".psm1", ".bat", ".cmd", ".ini", ".cfg", ".conf", ".toml", ".log", ".gradle",
  ".properties", ".plist", ".pbxproj", ".xcconfig", ".entitlements", ".strings", ".tex", ".srt", ".vtt", ".dart",
  ".lua", ".r", ".m", ".mm", ".php", ".pl", ".gitignore", ".editorconfig", ".dockerfile", ".proto", ".graphql",
]);

/** True if the first bytes look binary (a NUL byte, or many control characters). */
export function looksBinary(sample: Buffer): boolean {
  if (sample.length === 0) return false;
  if (sample[0] === 0xff && sample[1] === 0xfe) return false; // UTF-16 LE text
  if (sample[0] === 0xfe && sample[1] === 0xff) return false; // UTF-16 BE text
  let control = 0;
  for (let i = 0; i < sample.length; i++) {
    const byte = sample[i];
    if (byte === 0) return true;
    if (byte < 9 || (byte > 13 && byte < 32)) control++;
  }
  return control / sample.length > 0.1;
}

/** Decodes UTF-8 (with or without BOM) and UTF-16 with BOM. Invalid bytes become U+FFFD. */
export function decodeText(buffer: Buffer): string {
  if (buffer[0] === 0xef && buffer[1] === 0xbb && buffer[2] === 0xbf) return buffer.subarray(3).toString("utf8");
  if (buffer[0] === 0xff && buffer[1] === 0xfe) return new TextDecoder("utf-16le").decode(buffer.subarray(2));
  if (buffer[0] === 0xfe && buffer[1] === 0xff) return new TextDecoder("utf-16be").decode(buffer.subarray(2));
  return new TextDecoder("utf-8").decode(buffer);
}

/** Lowercase, Turkish ı/İ folded to i, accents removed: "Çalışma" → "calisma". */
export function foldForSearch(text: string): string {
  return text
    .replace(/İ/g, "i")
    .replace(/I/g, "i")
    .replace(/ı/g, "i")
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "");
}

export function globToRegExp(glob: string): RegExp {
  const escaped = foldForSearch(glob)
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".");
  return new RegExp(`^${escaped}$`);
}

export async function sha256OfFile(file: string, signal?: AbortSignal): Promise<string> {
  const hash = createHash("sha256");
  const stream = createReadStream(file, { signal });
  for await (const chunk of stream) hash.update(chunk as Buffer);
  return hash.digest("hex");
}

export async function readSample(file: string, bytes = 8192): Promise<Buffer> {
  const handle = await fs.open(file, "r");
  try {
    const buffer = Buffer.alloc(bytes);
    const { bytesRead } = await handle.read(buffer, 0, bytes, 0);
    return buffer.subarray(0, bytesRead);
  } finally {
    await handle.close();
  }
}

export interface WalkEntry {
  abs: string;
  name: string;
  dirent: Dirent;
  depth: number;
}

export interface WalkOptions {
  skipDirs: ReadonlySet<string>;
  isSecretName: (name: string) => boolean;
  maxEntries: number;
  deadline: number;
  signal?: AbortSignal;
  maxDepth?: number;
}

export interface WalkStats {
  visited: number;
  truncated: boolean;
  timedOut: boolean;
}

/**
 * Breadth-first walk that never follows symlinks or junctions (so it cannot
 * leave the shared folder or loop), skips heavy and secret folders, and stops
 * at an entry budget or deadline.
 */
export async function* walk(start: string, options: WalkOptions, stats: WalkStats): AsyncGenerator<WalkEntry> {
  const queue: Array<{ dir: string; depth: number }> = [{ dir: start, depth: 0 }];
  while (queue.length > 0) {
    if (options.signal?.aborted) throw abortError();
    if (Date.now() > options.deadline) {
      stats.timedOut = true;
      return;
    }
    const { dir, depth } = queue.shift() as { dir: string; depth: number };
    let entries: Dirent[];
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      continue; // unreadable folder (permissions): skip it
    }
    for (const dirent of entries) {
      if (stats.visited >= options.maxEntries) {
        stats.truncated = true;
        return;
      }
      stats.visited++;
      const name = dirent.name;
      if (options.isSecretName(name)) continue;
      const abs = path.join(dir, name);
      yield { abs, name, dirent, depth: depth + 1 };
      if (dirent.isDirectory() && !dirent.isSymbolicLink()) {
        if (options.skipDirs.has(name.toLowerCase())) continue;
        if (options.maxDepth !== undefined && depth + 1 >= options.maxDepth) continue;
        queue.push({ dir: abs, depth: depth + 1 });
      }
    }
  }
}

export function abortError(): Error {
  const error = new Error("aborted");
  error.name = "AbortError";
  return error;
}

export function displayFrom(rootName: string, rootReal: string, abs: string): string {
  const relative = path.relative(rootReal, abs).replace(/\\/g, "/");
  return relative ? `${rootName}/${relative}` : rootName;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1).replace(".", ",")} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1).replace(".", ",")} MB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(1).replace(".", ",")} GB`;
}

export async function copyRecursive(from: string, to: string, signal?: AbortSignal): Promise<void> {
  await fs.cp(from, to, { recursive: true, errorOnExist: true, force: false, verbatimSymlinks: true });
  if (signal?.aborted) throw abortError();
}

export async function totalSize(target: string, limit: number): Promise<number> {
  const stat = await fs.lstat(target);
  if (!stat.isDirectory()) return stat.size;
  let total = 0;
  const stack = [target];
  while (stack.length > 0) {
    const dir = stack.pop() as string;
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory() && !entry.isSymbolicLink()) stack.push(abs);
      else total += (await fs.lstat(abs)).size;
      if (total > limit) return total;
    }
  }
  return total;
}

export function requireKind(stat: { isDirectory(): boolean; isFile(): boolean }, kind: "file" | "dir", display: string): void {
  if (kind === "dir" && !stat.isDirectory()) throw new CompanionError("not_a_folder", `${display} bir klasör değil.`);
  if (kind === "file" && !stat.isFile()) throw new CompanionError("not_a_file", `${display} bir dosya değil.`);
}
