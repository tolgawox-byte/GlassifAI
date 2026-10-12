// The interactive console shown while the companion runs: pairing, devices,
// approvals and tasks for the person sitting at the PC.

import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import readline from "node:readline";
import type { CompanionCore } from "./core.ts";
import { describeTask } from "./mcp.ts";
import { formatCode } from "./pairing.ts";
import { encodeQr, renderQrForTerminal, renderQrSvg } from "./qr.ts";
import type { RunningServer } from "./server.ts";
import type { TaskRecord } from "./tasks.ts";
import { CompanionError } from "./util.ts";

const HELP = `Komutlar:
  pair [open]        Telefonla eşleştirme kodu ve QR göster ("open": QR'ı tarayıcıda aç)
  devices            Eşleşmiş cihazlar
  revoke <id>        Bir cihazın eşleşmesini kaldır
  tasks              Son görevler
  approve <id>       Bekleyen görevi onayla
  deny <id>          Bekleyen görevi reddet
  cancel <id>        Görevi iptal et / durdur
  roots              Paylaşılan klasörler
  reload             config.json'ı yeniden oku
  status             Durum
  help               Bu liste
  quit               Kapat`;

export class CompanionConsole {
  private readonly core: CompanionCore;
  private readonly server: RunningServer;
  private readonly advertisedHost: string;
  /** Undefined when stdin is not a terminal (running in the background). */
  private readonly rl: readline.Interface | undefined;
  private question: { resolve: (answer: string) => void; timer: NodeJS.Timeout } | undefined;
  private onQuit: () => void = () => {};

  constructor(core: CompanionCore, server: RunningServer, advertisedHost: string) {
    this.core = core;
    this.server = server;
    this.advertisedHost = advertisedHost;
    this.rl = process.stdin.isTTY ? readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true }) : undefined;
    if (core.config.pairing.requireConsoleConfirm) {
      core.pairing.setConfirm(async (deviceName, address) => {
        if (!process.stdin.isTTY) {
          this.print(`Eşleştirme isteği (${deviceName}, ${address}) reddedildi: onay için etkileşimli konsol gerekiyor.`);
          return false;
        }
        const answer = await this.ask(`\nEşleştirme isteği: "${deviceName}" (${address}). Kabul etmek için "evet", reddetmek için "hayır" yaz: `, 60_000);
        return /^(e|evet|y|yes)$/i.test(answer.trim());
      });
    }
    core.tasks.on("task", (task: TaskRecord) => {
      if (task.state === "awaiting_approval") {
        this.print(`\n[ONAY BEKLİYOR] ${task.id} · ${task.summary}${task.warnings.length ? ` · ${task.warnings.join(" ")}` : ""}\n  approve ${task.id}  /  deny ${task.id}`);
      } else if (task.state === "completed" || task.state === "failed") {
        this.print(`[${task.state === "completed" ? "TAMAM" : "HATA"}] ${task.id} · ${task.summary}${task.error ? ` · ${task.error.message}` : ""}`);
      }
    });
  }

  start(onQuit: () => void): void {
    this.onQuit = onQuit;
    if (!this.rl) {
      process.stdout.write("Etkileşimli konsol yok (arka planda çalışıyor): onaylar telefondan verilir, eşleştirme için companion'ı bir terminalde başlat.\n");
      return;
    }
    this.rl.setPrompt("jarvis-pc> ");
    this.rl.on("line", (line) => void this.handle(line));
    this.rl.on("close", () => this.onQuit());
    this.rl.prompt();
  }

  close(): void {
    this.rl?.close();
  }

  private print(text: string): void {
    process.stdout.write(`${text}\n`);
    this.rl?.prompt(true);
  }

  private ask(prompt: string, timeoutMs: number): Promise<string> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.question = undefined;
        this.print("(Süre doldu; reddedildi.)");
        resolve("");
      }, timeoutMs);
      this.question = { resolve, timer };
      process.stdout.write(prompt);
    });
  }

  private async handle(line: string): Promise<void> {
    if (this.question) {
      const { resolve, timer } = this.question;
      clearTimeout(timer);
      this.question = undefined;
      resolve(line);
      return;
    }
    const [command, ...rest] = line.trim().split(/\s+/);
    try {
      switch ((command ?? "").toLowerCase()) {
        case "":
          break;
        case "help":
        case "yardim":
        case "yardım":
          this.print(HELP);
          break;
        case "pair":
        case "eslestir":
        case "eşleştir":
          await this.pair(rest[0] === "open");
          break;
        case "devices":
          this.printDevices();
          break;
        case "revoke": {
          const ok = await this.core.devices.revoke(rest[0] ?? "");
          if (ok) await this.core.audit.record("device.revoked", { deviceId: rest[0], by: "console" });
          this.print(ok ? "Eşleşme kaldırıldı." : "Böyle etkin bir cihaz yok.");
          break;
        }
        case "tasks":
          this.printTasks();
          break;
        case "approve": {
          const task = this.core.tasks.get(rest[0] ?? "");
          if (!task) throw new CompanionError("task_not_found", "Görev bulunamadı.");
          await this.core.tasks.approve(task.id, "console", task.argsDigest);
          this.print(`Onaylandı: ${task.id}`);
          break;
        }
        case "deny":
          await this.core.tasks.deny(rest[0] ?? "", "console");
          this.print("Reddedildi.");
          break;
        case "cancel":
          await this.core.tasks.cancel(rest[0] ?? "", "console");
          this.print("İptal istendi.");
          break;
        case "roots":
          this.printRoots();
          break;
        case "reload": {
          const problems = await this.core.reload();
          this.print(problems.length ? `Yeniden okundu, sorunlar:\n- ${problems.join("\n- ")}` : "config.json yeniden okundu.");
          this.printRoots();
          break;
        }
        case "status":
          this.printStatus();
          break;
        case "quit":
        case "exit":
        case "cikis":
        case "çıkış":
          this.rl?.close();
          return;
        default:
          this.print(`Bilinmeyen komut: ${command}. "help" yaz.`);
      }
    } catch (error) {
      this.print(`Hata: ${error instanceof Error ? error.message : String(error)}`);
    }
    this.rl?.prompt();
  }

  async pair(openInBrowser: boolean): Promise<void> {
    if (this.advertisedHost === "127.0.0.1") {
      this.print("Companion yalnızca bu bilgisayarda dinliyor (127.0.0.1). Telefonla eşleştirmek için 'jarvis-pc start --lan' ile başlat.");
      return;
    }
    const window = this.core.pairing.open(
      { host: this.advertisedHost, port: this.server.port, pin: this.core.identity.pin, serverName: this.core.config.serverName },
      this.core.config.pairing.ttlSec,
    );
    const qr = encodeQr(window.uri);
    const svgFile = path.join(this.core.dataDir, "pairing-qr.svg");
    await fs.writeFile(svgFile, renderQrSvg(qr), "utf8");
    const minutes = Math.round(this.core.config.pairing.ttlSec / 60);
    this.print(
      `\n${renderQrForTerminal(qr)}\n\n` +
        `Telefonda: JARVIS → PC → "QR ile eşleştir" ve bu kodu okut.\n` +
        `Elle girmek için: adres ${this.advertisedHost}:${this.server.port} · kod ${formatCode(window.code)}\n` +
        `Anahtar parmak izi (pin): ${this.core.identity.pin}\n` +
        `Kod ${minutes} dakika geçerli ve tek kullanımlık.${this.core.config.pairing.requireConsoleConfirm ? " Telefon bağlanınca burada onay istenecek." : ""}\n` +
        `QR dosyası: ${svgFile}`,
    );
    if (openInBrowser) {
      spawn(path.join(process.env.SystemRoot ?? "C:\\Windows", "explorer.exe"), [svgFile], { detached: true, stdio: "ignore", shell: false }).unref();
    }
  }

  private printDevices(): void {
    const devices = this.core.devices.list();
    if (devices.length === 0) return this.print("Eşleşmiş cihaz yok.");
    this.print(
      devices
        .map((d) => `${d.id}  ${d.name}  ${d.revokedAt ? "(kaldırıldı)" : "etkin"}  son görülme: ${d.lastSeenAt ?? "—"} ${d.lastAddress ?? ""}`)
        .join("\n"),
    );
  }

  private printTasks(): void {
    const tasks = this.core.tasks.list({ limit: 15 });
    this.print(tasks.length ? tasks.map((t) => describeTask(t).split("\n")[0]).join("\n") : "Görev yok.");
  }

  private printRoots(): void {
    const roots = this.core.policy.roots;
    const lines = roots.map((r) => `${r.name}  ${r.access === "write" ? "okuma/yazma" : "salt okunur"}  ${r.path}`);
    if (this.core.problems.length) lines.push(...this.core.problems.map((p) => `! ${p}`));
    this.print(lines.length ? lines.join("\n") : "Paylaşılan klasör yok. Ekle: jarvis-pc roots add <klasör> --name <ad> [--write]");
  }

  printStatus(): void {
    const status = this.core.status();
    this.print(
      `${status.name} · JARVIS PC Companion ${status.version}\n` +
        `Dinliyor: https://${this.server.host}:${this.server.port} ${this.core.config.network.lan ? "(yerel ağ)" : "(yalnızca bu bilgisayar)"}\n` +
        `Pin: ${this.core.identity.pin}\n` +
        `Klasörler: ${this.core.policy.roots.map((r) => r.name).join(", ") || "yok"} · ` +
        `Uygulamalar: ${this.core.config.apps.map((a) => a.id).join(", ") || "yok"} · ` +
        `Komutlar: ${this.core.config.commands.map((c) => c.id).join(", ") || "yok"}\n` +
        `Onay bekleyen: ${status.awaitingApproval} · çalışan: ${status.running} · eşleşmiş cihaz: ${this.core.devices.active().length}`,
    );
  }
}
