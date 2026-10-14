// open_app and run_command: the only tools that start programs.
// Both use the owner's allowlist (config.json): the model picks an entry and
// a shared folder, never a program path or a command line. Programs start
// without a shell unless the owner marked a .cmd/.bat entry as needing one,
// and even then the command line is fixed by the owner.

import { spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";
import { promises as fs } from "node:fs";
import type { AppEntry, CommandEntry } from "../config.ts";
import { compareRuns, describeComparison, describeSummary, parseTestOutput, TestHistory } from "../testReport.ts";
import type { TestComparison } from "../testReport.ts";
import { CompanionError, tail, truncate } from "../util.ts";
import type { ToolDefinition } from "./types.ts";

function findApp(apps: readonly AppEntry[], id: unknown): AppEntry {
  const app = apps.find((a) => a.id === id);
  if (!app) {
    const ids = apps.map((a) => `${a.id} (${a.label})`).join(", ") || "(yok)";
    throw new CompanionError("unknown_app", `İzin verilen uygulamalarda "${String(id)}" yok. İzinliler: ${ids}.`, { status: 404 });
  }
  return app;
}

function findCommand(commands: readonly CommandEntry[], id: unknown): CommandEntry {
  const command = commands.find((c) => c.id === id);
  if (!command) {
    const ids = commands.map((c) => `${c.id} (${c.label})`).join(", ") || "(yok — bilgisayarda config.json'a komut ekle)";
    throw new CompanionError("unknown_command", `İzin verilen komutlarda "${String(id)}" yok. İzinliler: ${ids}.`, { status: 404 });
  }
  return command;
}

/** Kills a process and all its children (Windows: taskkill /T /F). */
export function killTree(child: ChildProcess): Promise<void> {
  return new Promise((resolve) => {
    if (child.pid === undefined || child.exitCode !== null) return resolve();
    if (process.platform === "win32") {
      const killer = spawn("taskkill", ["/pid", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore", shell: false });
      killer.on("exit", () => resolve());
      killer.on("error", () => {
        child.kill("SIGKILL");
        resolve();
      });
    } else {
      child.kill("SIGKILL");
      resolve();
    }
  });
}

/** Quotes one argument for a cmd.exe command line. Owner arguments are checked for metacharacters in config. */
function quoteForCmd(arg: string): string {
  return /[\s]/.test(arg) ? `"${arg}"` : arg;
}

export const openApp: ToolDefinition = {
  name: "open_app",
  title: "Uygulama aç",
  description:
    "Starts one of the programs the owner allowed on the PC (see pc_status for the list), optionally with a folder or file from a shared folder. Needs the owner's approval.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    required: ["app"],
    properties: {
      app: { type: "string", minLength: 1, maxLength: 40, description: "Allowed app id, e.g. vscode, explorer, notepad." },
      path: { type: "string", minLength: 1, maxLength: 1024, description: "Optional folder or file in a shared folder." },
    },
  },
  risk: "execute",
  scope: "apps:launch",
  retrySafe: false,
  timeoutMs: 15_000,
  async prepare(args, ctx) {
    const app = findApp(ctx.config.apps, args.app);
    if (args.path === undefined) return { summary: `Uygulama aç: ${app.label}`, warnings: [] };
    if (app.pathArg === "none") throw new CompanionError("invalid_arguments", `${app.label} bir dosya veya klasörle açılamaz.`);
    const resolved = await ctx.policy.resolve(args.path, "read", "existing");
    const stat = await fs.stat(resolved.abs);
    if (app.pathArg === "folder" && !stat.isDirectory()) throw new CompanionError("not_a_folder", `${app.label} yalnızca klasör açar.`);
    if (app.pathArg === "file" && !stat.isFile()) throw new CompanionError("not_a_file", `${app.label} yalnızca dosya açar.`);
    return { summary: `${app.label} ile aç: ${resolved.display}`, warnings: [] };
  },
  async run(args, ctx) {
    const app = findApp(ctx.config.apps, args.app);
    const extra: string[] = [];
    let display = "";
    if (args.path !== undefined) {
      const resolved = await ctx.policy.resolve(args.path, "read", "existing");
      extra.push(resolved.abs);
      display = ` · ${resolved.display}`;
    }
    const child = spawn(app.exe, [...app.args, ...extra], { detached: true, stdio: "ignore", windowsHide: false, shell: false });
    const pid = await new Promise<number>((resolve, reject) => {
      child.once("spawn", () => resolve(child.pid ?? 0));
      child.once("error", (error) => reject(new CompanionError("launch_failed", `${app.label} başlatılamadı: ${error.message}`)));
    });
    child.unref();
    return {
      result: { app: app.id, pid },
      text: `${app.label} başlatıldı${display}.`,
      verification: {
        ok: pid > 0,
        details: pid > 0 ? `Program başlatıldı (PID ${pid}). Pencerenin ekranda açıldığını companion göremez.` : "Program başlatılamadı.",
      },
    };
  },
};

export const runCommand: ToolDefinition = {
  name: "run_command",
  title: "Komut çalıştır",
  description:
    "Runs one of the owner's allowlisted commands (for example npm test or a build) in a project folder inside a shared folder, and returns the exit code and the end of the output. The model chooses only the command id and the folder. Needs the owner's approval; can be cancelled.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    required: ["command", "path"],
    properties: {
      command: { type: "string", minLength: 1, maxLength: 40, description: "Allowed command id (see pc_status)." },
      path: { type: "string", minLength: 1, maxLength: 1024, description: "Project folder in a shared folder; the command runs there." },
    },
  },
  risk: "execute",
  scope: "commands:run",
  retrySafe: false,
  timeoutMs: 600_000,
  async prepare(args, ctx) {
    const command = findCommand(ctx.config.commands, args.command);
    const resolved = await ctx.policy.resolve(args.path, command.needsWriteAccess ? "write" : "read", "existing");
    if (!(await fs.stat(resolved.abs)).isDirectory()) throw new CompanionError("not_a_folder", `${resolved.display} bir klasör değil.`);
    return {
      summary: `Komut çalıştır: ${command.label} · ${resolved.display}`,
      warnings: ["Bu komut projenin kendi kodunu çalıştırabilir (test/derleme betikleri). Yalnızca güvendiğin projelerde onayla."],
      timeoutMs: command.timeoutSec * 1000,
    };
  },
  async run(args, ctx) {
    const command = findCommand(ctx.config.commands, args.command);
    const resolved = await ctx.policy.resolve(args.path, command.needsWriteAccess ? "write" : "read", "existing");
    const started = Date.now();
    const env = { ...process.env };
    for (const key of Object.keys(env)) if (/^JARVIS_PC_/i.test(key)) delete env[key];
    const child = command.shell
      ? spawn([quoteForCmd(command.exe), ...command.args.map(quoteForCmd)].join(" "), [], { cwd: resolved.abs, shell: true, windowsHide: true, env })
      : spawn(command.exe, command.args, { cwd: resolved.abs, shell: false, windowsHide: true, env });

    let output = "";
    let lastProgress = 0;
    const onData = (chunk: Buffer): void => {
      output = tail(output + chunk.toString("utf8"), 64 * 1024);
      if (Date.now() - lastProgress > 500) {
        lastProgress = Date.now();
        const lastLine = output.trimEnd().split(/\r?\n/).at(-1) ?? "";
        ctx.progress(truncate(lastLine, 200));
      }
    };
    child.stdout?.on("data", onData);
    child.stderr?.on("data", onData);

    const onAbort = (): void => void killTree(child);
    ctx.signal.addEventListener("abort", onAbort, { once: true });
    let exitCode: number | null;
    try {
      exitCode = await new Promise<number | null>((resolve, reject) => {
        child.once("error", (error) => reject(new CompanionError("launch_failed", `${command.label} başlatılamadı: ${error.message}`)));
        child.once("close", (code) => resolve(code));
      });
    } finally {
      ctx.signal.removeEventListener("abort", onAbort);
    }
    if (ctx.signal.aborted) {
      const stopped = new Error("aborted");
      stopped.name = "AbortError";
      throw stopped;
    }
    const durationMs = Date.now() - started;
    const seconds = Math.max(1, Math.round(durationMs / 1000));
    const outputTail = tail(output, 16 * 1024);
    const lastLines = outputTail.trimEnd().split(/\r?\n/).slice(-3).join(" | ");
    // A test run's own counts (research D2-04), compared with the previous
    // run of this command in this folder. Failing tests make the run
    // unsuccessful even when the program exits with 0.
    const tests = parseTestOutput(output);
    let comparison: TestComparison | undefined;
    if (tests) {
      const history = new TestHistory(ctx.dataDir);
      const key = TestHistory.key(command.id, resolved.display);
      const previous = await history.previous(key);
      comparison = previous ? compareRuns(tests, previous) : undefined;
      await history.record(key, tests).catch(() => undefined);
    }
    const changes = comparison ? describeComparison(comparison) : undefined;
    const testText = tests ? ` ${describeSummary(tests)}.${changes ? ` ${changes}` : ""}` : "";
    const success = exitCode === 0 && !(tests && tests.failed > 0);
    return {
      result: { command: command.id, path: resolved.display, exitCode, durationMs, outputTail, tests, comparison },
      text: success
        ? `${command.label} ${seconds} sn'de başarıyla bitti.${testText}`
        : `${command.label} başarısız oldu (çıkış kodu ${exitCode ?? "yok"}, ${seconds} sn).${testText} Son satırlar: ${truncate(lastLines, 300)}`,
      verification: { ok: true, details: `Komut çalıştı ve bitti (çıkış kodu ${exitCode ?? "yok"}).` },
      unsuccessful: !success,
    };
  },
};
