// Composition root: loads settings and state from the data folder and wires
// the policy, devices, pairing, tasks and audit log together.

import os from "node:os";
import path from "node:path";
import { AuditLog } from "./audit.ts";
import { loadOrCreateIdentity } from "./cert.ts";
import type { Identity } from "./cert.ts";
import { checkConfig, loadConfig } from "./config.ts";
import type { CompanionConfig } from "./config.ts";
import { DeviceStore } from "./devices.ts";
import { privateIPv4Addresses } from "./network.ts";
import { PairingManager } from "./pairing.ts";
import { PathPolicy } from "./pathPolicy.ts";
import { TaskManager } from "./tasks.ts";
import { pruneOldTrash } from "./tools/files.ts";
import { ALL_TOOLS, effectivePolicy, toolMap } from "./tools/registry.ts";
import type { ToolDefinition } from "./tools/types.ts";

export const VERSION = "0.1.0";

export function defaultDataDir(): string {
  if (process.env.JARVIS_PC_HOME) return path.resolve(process.env.JARVIS_PC_HOME);
  const base = process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local");
  return path.join(base, "JarvisPC");
}

export interface CoreOptions {
  dataDir: string;
  /** Narrows the folders that can never be roots (tests use temporary folders under AppData). */
  systemFolders?: readonly string[];
  /** Extra addresses for the certificate (the LAN address chosen at start). */
  certificateAddresses?: string[];
  tools?: readonly ToolDefinition[];
  expiryCheckMs?: number;
}

export class CompanionCore {
  readonly dataDir: string;
  readonly audit: AuditLog;
  readonly devices: DeviceStore;
  readonly pairing: PairingManager;
  readonly identity: Identity;
  readonly tools: Map<string, ToolDefinition>;
  config: CompanionConfig;
  policy: PathPolicy;
  tasks!: TaskManager;
  problems: string[];
  private readonly systemFolders?: readonly string[];

  private constructor(init: {
    dataDir: string;
    audit: AuditLog;
    devices: DeviceStore;
    identity: Identity;
    config: CompanionConfig;
    policy: PathPolicy;
    tools: Map<string, ToolDefinition>;
    problems: string[];
    systemFolders?: readonly string[];
  }) {
    this.dataDir = init.dataDir;
    this.audit = init.audit;
    this.devices = init.devices;
    this.identity = init.identity;
    this.config = init.config;
    this.policy = init.policy;
    this.tools = init.tools;
    this.problems = init.problems;
    this.systemFolders = init.systemFolders;
    this.pairing = new PairingManager(this.devices, this.audit);
  }

  static async create(options: CoreOptions): Promise<CompanionCore> {
    const dataDir = path.resolve(options.dataDir);
    const { config } = await loadConfig(path.join(dataDir, "config.json"));
    const configProblems = checkConfig(config);
    if (configProblems.length > 0) {
      throw new Error(`config.json geçersiz:\n- ${configProblems.join("\n- ")}`);
    }
    const audit = await AuditLog.open(path.join(dataDir, "audit.log"));
    const { policy, problems } = await PathPolicy.create(config.roots, {
      dataDir,
      secretPatterns: config.policy.secretPatterns,
      systemFolders: options.systemFolders,
    });
    const addresses = ["127.0.0.1", ...privateIPv4Addresses().map((a) => a.address), ...(options.certificateAddresses ?? [])];
    const identity = await loadOrCreateIdentity({
      dir: path.join(dataDir, "identity"),
      commonName: `JARVIS PC ${os.hostname()}`.slice(0, 60),
      dnsNames: ["localhost"],
      ipAddresses: [...new Set(addresses)],
    });
    const devices = await DeviceStore.open(path.join(dataDir, "devices.json"));
    const tools = toolMap(options.tools ?? ALL_TOOLS);
    const core = new CompanionCore({ dataDir, audit, devices, identity, config, policy, tools, problems, systemFolders: options.systemFolders });
    core.tasks = await TaskManager.open({
      file: path.join(dataDir, "tasks.json"),
      audit,
      tools,
      context: () => ({ policy: core.policy, config: core.config, dataDir }),
      policyFor: (tool) => effectivePolicy(tool, core.config),
      approvalTtlSec: () => core.config.policy.approvalTtlSec,
      expiryCheckMs: options.expiryCheckMs,
    });
    await pruneOldTrash(dataDir);
    return core;
  }

  /** Re-reads config.json (roots, apps, commands, policy) without restarting. */
  async reload(): Promise<string[]> {
    const { config } = await loadConfig(path.join(this.dataDir, "config.json"));
    const configProblems = checkConfig(config);
    if (configProblems.length > 0) return configProblems;
    const { policy, problems } = await PathPolicy.create(config.roots, {
      dataDir: this.dataDir,
      secretPatterns: config.policy.secretPatterns,
      systemFolders: this.systemFolders,
    });
    this.config = config;
    this.policy = policy;
    this.problems = problems;
    await this.audit.record("config.reloaded", { roots: policy.roots.length, apps: config.apps.length, commands: config.commands.length });
    await this.tasks.voidPendingApprovals("Bilgisayardaki ayarlar değişti; işlemi yeniden iste.");
    return problems;
  }

  toolSummaries(): Array<{ name: string; title: string; risk: string; policy: string }> {
    return [...this.tools.values()].map((tool) => ({ name: tool.name, title: tool.title, risk: tool.risk, policy: effectivePolicy(tool, this.config) }));
  }

  status(): Record<string, unknown> {
    const tasks = this.tasks.list({ limit: 500 });
    return {
      service: "jarvis-pc",
      version: VERSION,
      name: this.config.serverName,
      roots: this.policy.listRoots(),
      apps: this.config.apps.map((app) => ({ id: app.id, label: app.label, pathArg: app.pathArg })),
      commands: this.config.commands.map((command) => ({ id: command.id, label: command.label })),
      tools: this.toolSummaries(),
      awaitingApproval: tasks.filter((t) => t.state === "awaiting_approval").length,
      running: tasks.filter((t) => t.state === "running").length,
      lan: this.config.network.lan,
      time: new Date().toISOString(),
    };
  }

  async close(): Promise<void> {
    await this.tasks.close();
    await this.audit.flush();
  }
}
