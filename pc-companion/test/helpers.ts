// Test helpers: temporary data folders and roots, a ZIP writer for document
// fixtures, and an HTTPS client that checks the companion's key pin.

import { X509Certificate } from "node:crypto";
import { promises as fs } from "node:fs";
import https from "node:https";
import os from "node:os";
import path from "node:path";
import { deflateRawSync } from "node:zlib";
import { publicKeyPin } from "../src/cert.ts";
import { defaultConfig } from "../src/config.ts";
import type { CompanionConfig } from "../src/config.ts";
import { CompanionCore } from "../src/core.ts";
import type { ToolDefinition } from "../src/tools/types.ts";

export async function tempDir(prefix: string): Promise<string> {
  return fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), prefix)));
}

export interface TestCore {
  core: CompanionCore;
  dataDir: string;
  roots: Record<string, string>;
  cleanup(): Promise<void>;
}

export async function makeCore(options: {
  roots?: Array<{ name: string; access: "read" | "write" }>;
  configure?: (config: CompanionConfig) => void;
  tools?: readonly ToolDefinition[];
} = {}): Promise<TestCore> {
  const dataDir = await tempDir("jpc-data-");
  const rootsBase = await tempDir("jpc-roots-");
  const roots: Record<string, string> = {};
  const config = defaultConfig();
  config.serverName = "TestPC";
  config.apps = [];
  config.pairing.requireConsoleConfirm = false;
  for (const root of options.roots ?? [{ name: "Projeler", access: "write" }]) {
    const dir = path.join(rootsBase, root.name);
    await fs.mkdir(dir, { recursive: true });
    roots[root.name] = await fs.realpath(dir);
    config.roots.push({ name: root.name, path: roots[root.name], access: root.access });
  }
  options.configure?.(config);
  await fs.writeFile(path.join(dataDir, "config.json"), JSON.stringify(config, null, 2));
  const core = await CompanionCore.create({ dataDir, systemFolders: [], expiryCheckMs: 50, tools: options.tools });
  return {
    core,
    dataDir,
    roots,
    async cleanup() {
      await core.close();
      // Windows can hold a folder briefly after a child process that used it exits.
      await fs.rm(dataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
      await fs.rm(rootsBase, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
    },
  };
}

// ---- ZIP writer (deflate) for Office fixtures --------------------------------

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(data: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of data) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

export function makeZip(files: Record<string, string | Buffer>): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let offset = 0;
  for (const [name, content] of Object.entries(files)) {
    const data = Buffer.isBuffer(content) ? content : Buffer.from(content, "utf8");
    const compressed = deflateRawSync(data);
    const nameBuffer = Buffer.from(name, "utf8");
    const crc = crc32(data);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(0x800, 6);
    local.writeUInt16LE(8, 8);
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBuffer.length, 26);
    locals.push(local, nameBuffer, compressed);
    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x800, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBuffer.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, nameBuffer);
    offset += local.length + nameBuffer.length + compressed.length;
  }
  const centralBuffer = Buffer.concat(centrals);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(Object.keys(files).length, 8);
  end.writeUInt16LE(Object.keys(files).length, 10);
  end.writeUInt32LE(centralBuffer.length, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, centralBuffer, end]);
}

// ---- HTTPS client ------------------------------------------------------------

export interface HttpResult {
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: unknown;
  text: string;
  pin: string;
}

export function request(
  port: number,
  method: string,
  pathName: string,
  options: { token?: string; body?: unknown; headers?: Record<string, string>; host?: string } = {},
): Promise<HttpResult> {
  return new Promise((resolve, reject) => {
    const payload = options.body === undefined ? undefined : JSON.stringify(options.body);
    const req = https.request(
      {
        host: options.host ?? "127.0.0.1",
        port,
        method,
        path: pathName,
        rejectUnauthorized: false, // the test checks the pin itself, like the phone does
        headers: {
          ...(payload !== undefined ? { "Content-Type": "application/json", "Content-Length": String(Buffer.byteLength(payload)) } : {}),
          ...(options.token ? { Authorization: `Bearer ${options.token}` } : {}),
          ...(options.headers ?? {}),
        },
      },
      (res) => {
        // Read the peer certificate now: the socket is detached once the body ends.
        const socket = res.socket as unknown as { getPeerX509Certificate?: () => X509Certificate | undefined } | null;
        const cert = socket?.getPeerX509Certificate?.();
        const pin = cert ? publicKeyPin(cert.publicKey) : "";
        const chunks: Buffer[] = [];
        res.on("data", (chunk: Buffer) => chunks.push(chunk));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let body: unknown = undefined;
          try {
            body = text ? JSON.parse(text) : undefined;
          } catch {
            body = undefined;
          }
          resolve({ status: res.statusCode ?? 0, headers: res.headers, body, text, pin });
        });
      },
    );
    req.on("error", reject);
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}

export function waitFor(predicate: () => boolean, timeoutMs = 5000, stepMs = 20): Promise<void> {
  return new Promise((resolve, reject) => {
    const started = Date.now();
    const tick = (): void => {
      if (predicate()) return resolve();
      if (Date.now() - started > timeoutMs) return reject(new Error("waitFor timed out"));
      setTimeout(tick, stepMs);
    };
    tick();
  });
}
