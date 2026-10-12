// The owner's settings: shared folders, allowed apps and commands, network and
// policy. Stored as config.json in the data folder; nothing is shared by default.

import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import type { RootConfig } from "./pathPolicy.ts";
import { DEFAULT_SECRET_PATTERNS, DEFAULT_SKIP_DIRS } from "./pathPolicy.ts";
import { readJsonFile, writeJsonFileAtomic } from "./util.ts";

export type ToolPolicy = "allow" | "ask" | "deny";
export type PathArgument = "none" | "folder" | "file" | "any";

export interface AppEntry {
  id: string;
  label: string;
  /** Full path of the program. Never a shell command. */
  exe: string;
  /** Fixed arguments; the companion adds at most one path after them. */
  args: string[];
  pathArg: PathArgument;
}

export interface CommandEntry {
  id: string;
  label: string;
  /** Full path of the program (or a .cmd/.bat file when `shell` is true). */
  exe: string;
  /** Fixed arguments. The model can choose the command and the folder, never the arguments. */
  args: string[];
  /** Needed for .cmd/.bat files such as npm.cmd. The command line is still fixed by the owner. */
  shell: boolean;
  timeoutSec: number;
  /** Commands that build or test write files, so they need a folder shared with write access. */
  needsWriteAccess: boolean;
}

export interface CompanionConfig {
  version: 1;
  serverName: string;
  roots: RootConfig[];
  apps: AppEntry[];
  commands: CommandEntry[];
  network: {
    lan: boolean;
    bindAddress: string | null;
    port: number;
  };
  pairing: {
    requireConsoleConfirm: boolean;
    ttlSec: number;
  };
  policy: {
    tools: Record<string, ToolPolicy>;
    approvalTtlSec: number;
    secretPatterns: string[];
    skipDirs: string[];
    maxReadBytes: number;
    maxWriteBytes: number;
  };
}

export const DEFAULT_PORT = 47600;
const ID = /^[a-z0-9][a-z0-9._-]{0,39}$/;

function windowsDir(): string {
  return process.env.SystemRoot ?? "C:\\Windows";
}

/** Programs that exist on this PC and are safe to start with at most a folder or file argument. */
export function detectDefaultApps(): AppEntry[] {
  const localAppData = process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local");
  const candidates: AppEntry[] = [
    { id: "explorer", label: "Dosya Gezgini", exe: path.join(windowsDir(), "explorer.exe"), args: [], pathArg: "folder" },
    { id: "notepad", label: "Not Defteri", exe: path.join(windowsDir(), "System32", "notepad.exe"), args: [], pathArg: "file" },
    { id: "calculator", label: "Hesap Makinesi", exe: path.join(windowsDir(), "System32", "calc.exe"), args: [], pathArg: "none" },
    {
      id: "vscode",
      label: "Visual Studio Code",
      exe: path.join(localAppData, "Programs", "Microsoft VS Code", "Code.exe"),
      args: [],
      pathArg: "any",
    },
  ];
  return candidates.filter((app) => existsSync(app.exe));
}

export function defaultConfig(): CompanionConfig {
  return {
    version: 1,
    serverName: os.hostname(),
    roots: [],
    apps: detectDefaultApps(),
    commands: [],
    network: { lan: false, bindAddress: null, port: DEFAULT_PORT },
    pairing: { requireConsoleConfirm: true, ttlSec: 300 },
    policy: {
      tools: {},
      approvalTtlSec: 600,
      secretPatterns: [...DEFAULT_SECRET_PATTERNS],
      skipDirs: [...DEFAULT_SKIP_DIRS],
      maxReadBytes: 256 * 1024,
      maxWriteBytes: 512 * 1024,
    },
  };
}

/** Returns a list of problems; an empty list means the config can be used. */
export function checkConfig(config: CompanionConfig): string[] {
  const problems: string[] = [];
  if (config.version !== 1) problems.push("version 1 olmalı.");
  if (typeof config.serverName !== "string" || config.serverName.trim().length === 0 || config.serverName.length > 60) {
    problems.push("serverName 1–60 karakter olmalı.");
  }
  if (!Array.isArray(config.roots)) problems.push("roots bir liste olmalı.");
  const ids = new Set<string>();
  for (const app of config.apps ?? []) {
    if (!ID.test(app.id ?? "")) problems.push(`Uygulama kimliği geçersiz: ${app.id}`);
    if (ids.has(`app:${app.id}`)) problems.push(`Aynı uygulama kimliği iki kez: ${app.id}`);
    ids.add(`app:${app.id}`);
    if (typeof app.exe !== "string" || !/^[a-zA-Z]:\\/.test(app.exe)) problems.push(`${app.id}: exe tam bir yol olmalı.`);
    if (/\.(cmd|bat|ps1|vbs|js)$/i.test(app.exe ?? "")) problems.push(`${app.id}: uygulama bir betik olamaz; .exe yolunu ver.`);
    if (!Array.isArray(app.args) || app.args.some((arg) => typeof arg !== "string")) problems.push(`${app.id}: args metin listesi olmalı.`);
    if (!["none", "folder", "file", "any"].includes(app.pathArg)) problems.push(`${app.id}: pathArg none/folder/file/any olmalı.`);
  }
  for (const command of config.commands ?? []) {
    if (!ID.test(command.id ?? "")) problems.push(`Komut kimliği geçersiz: ${command.id}`);
    if (ids.has(`cmd:${command.id}`)) problems.push(`Aynı komut kimliği iki kez: ${command.id}`);
    ids.add(`cmd:${command.id}`);
    if (typeof command.exe !== "string" || !/^[a-zA-Z]:\\/.test(command.exe)) problems.push(`${command.id}: exe tam bir yol olmalı.`);
    if (!Array.isArray(command.args) || command.args.some((arg) => typeof arg !== "string")) {
      problems.push(`${command.id}: args metin listesi olmalı.`);
    }
    if (command.shell && (command.args ?? []).some((arg) => /[&|<>^%!"\r\n]/.test(arg))) {
      problems.push(`${command.id}: shell ile çalışan komutun argümanlarında & | < > ^ % ! " olamaz.`);
    }
    if (typeof command.timeoutSec !== "number" || command.timeoutSec < 5 || command.timeoutSec > 3600) {
      problems.push(`${command.id}: timeoutSec 5–3600 arası olmalı.`);
    }
  }
  const net = config.network;
  if (!net || typeof net.lan !== "boolean") problems.push("network.lan true/false olmalı.");
  if (!net || !Number.isInteger(net.port) || net.port < 1024 || net.port > 65535) problems.push("network.port 1024–65535 olmalı.");
  for (const [tool, policy] of Object.entries(config.policy?.tools ?? {})) {
    if (!["allow", "ask", "deny"].includes(policy)) problems.push(`policy.tools.${tool}: allow/ask/deny olmalı.`);
  }
  const ttl = config.policy?.approvalTtlSec;
  if (typeof ttl !== "number" || ttl < 30 || ttl > 86400) problems.push("policy.approvalTtlSec 30–86400 olmalı.");
  return problems;
}

/** Merges a saved file over the defaults, so new settings get sane values after an update. */
export function mergeWithDefaults(saved: Partial<CompanionConfig>): CompanionConfig {
  const base = defaultConfig();
  return {
    ...base,
    ...saved,
    version: 1,
    network: { ...base.network, ...(saved.network ?? {}) },
    pairing: { ...base.pairing, ...(saved.pairing ?? {}) },
    policy: { ...base.policy, ...(saved.policy ?? {}), tools: { ...(saved.policy?.tools ?? {}) } },
    roots: saved.roots ?? base.roots,
    apps: saved.apps ?? base.apps,
    commands: saved.commands ?? base.commands,
  };
}

export async function loadConfig(file: string): Promise<{ config: CompanionConfig; created: boolean }> {
  const saved = await readJsonFile<Partial<CompanionConfig>>(file);
  if (!saved) {
    const config = defaultConfig();
    await writeJsonFileAtomic(file, config);
    return { config, created: true };
  }
  return { config: mergeWithDefaults(saved), created: false };
}

export async function saveConfig(file: string, config: CompanionConfig): Promise<void> {
  await writeJsonFileAtomic(file, config);
}
