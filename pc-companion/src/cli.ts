// jarvis-pc command line.
//
//   jarvis-pc start [--lan] [--bind <ip>] [--port <n>] [--pair]
//   jarvis-pc roots list | add <folder> --name <name> [--write] | remove <name>
//   jarvis-pc devices list | revoke <id>
//   jarvis-pc audit verify
//   jarvis-pc config path | check
//   jarvis-pc doctor

import { promises as fs } from "node:fs";
import path from "node:path";
import { verifyAuditLog } from "./audit.ts";
import { checkConfig, loadConfig, saveConfig } from "./config.ts";
import { CompanionConsole } from "./console.ts";
import { CompanionCore, VERSION, defaultDataDir } from "./core.ts";
import { DeviceStore } from "./devices.ts";
import { chooseBindAddress, privateIPv4Addresses } from "./network.ts";
import { PathPolicy } from "./pathPolicy.ts";
import { startServer } from "./server.ts";

interface Parsed {
  positional: string[];
  flags: Map<string, string | true>;
}

function parse(argv: string[]): Parsed {
  const positional: string[] = [];
  const flags = new Map<string, string | true>();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      const name = arg.slice(2);
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith("--") && ["bind", "port", "name", "data"].includes(name)) {
        flags.set(name, next);
        i++;
      } else {
        flags.set(name, true);
      }
    } else {
      positional.push(arg);
    }
  }
  return { positional, flags };
}

const USAGE = `JARVIS PC Companion ${VERSION}

Kullanım:
  jarvis-pc start [--lan] [--bind <ip>] [--port <n>] [--pair]
      Sunucuyu başlatır. Varsayılan: yalnızca bu bilgisayar (127.0.0.1).
      --lan  telefonun bağlanabilmesi için yerel ağ adresinde dinler.
      --pair başlarken eşleştirme QR'ını gösterir.
  jarvis-pc roots list
  jarvis-pc roots add <klasör> --name <ad> [--write]
  jarvis-pc roots remove <ad>
  jarvis-pc devices list
  jarvis-pc devices revoke <id>
  jarvis-pc audit verify
  jarvis-pc config path | check
  jarvis-pc doctor

Veri klasörü: ${defaultDataDir()} (JARVIS_PC_HOME ile değiştirilebilir)`;

async function main(): Promise<number> {
  const { positional, flags } = parse(process.argv.slice(2));
  const dataDir = typeof flags.get("data") === "string" ? path.resolve(flags.get("data") as string) : defaultDataDir();
  const configFile = path.join(dataDir, "config.json");
  const [command, sub, ...rest] = positional;

  switch (command) {
    case "start":
      return start(dataDir, flags);
    case "roots": {
      const { config } = await loadConfig(configFile);
      if (sub === "list" || sub === undefined) {
        const { policy, problems } = await PathPolicy.create(config.roots, { dataDir, secretPatterns: config.policy.secretPatterns });
        for (const root of policy.roots) console.log(`${root.name}\t${root.access === "write" ? "okuma/yazma" : "salt okunur"}\t${root.path}`);
        for (const problem of problems) console.log(`! ${problem}`);
        if (config.roots.length === 0) console.log("Paylaşılan klasör yok.");
        return 0;
      }
      if (sub === "add") {
        const folder = rest[0];
        const name = flags.get("name");
        if (!folder || typeof name !== "string") {
          console.error("Kullanım: jarvis-pc roots add <klasör> --name <ad> [--write]");
          return 2;
        }
        const candidate = { name, path: path.resolve(folder), access: flags.has("write") ? ("write" as const) : ("read" as const) };
        const result = await PathPolicy.validateRoot(candidate, dataDir);
        if (typeof result === "string") {
          console.error(`Eklenemedi: ${result}`);
          return 1;
        }
        if (config.roots.some((r) => r.name.toLowerCase() === name.toLowerCase())) {
          console.error(`"${name}" adında bir klasör zaten var.`);
          return 1;
        }
        config.roots.push(candidate);
        await saveConfig(configFile, config);
        console.log(`Eklendi: ${name} → ${result.path} (${candidate.access === "write" ? "okuma/yazma" : "salt okunur"}). Çalışan companion'da "reload" yaz.`);
        return 0;
      }
      if (sub === "remove") {
        const before = config.roots.length;
        config.roots = config.roots.filter((r) => r.name.toLowerCase() !== (rest[0] ?? "").toLowerCase());
        if (config.roots.length === before) {
          console.error("Böyle bir klasör yok.");
          return 1;
        }
        await saveConfig(configFile, config);
        console.log("Kaldırıldı. Çalışan companion'da \"reload\" yaz.");
        return 0;
      }
      break;
    }
    case "devices": {
      const devices = await DeviceStore.open(path.join(dataDir, "devices.json"));
      if (sub === "list" || sub === undefined) {
        const list = devices.list();
        if (list.length === 0) console.log("Eşleşmiş cihaz yok.");
        for (const d of list) console.log(`${d.id}\t${d.name}\t${d.revokedAt ? "kaldırıldı" : "etkin"}\tson: ${d.lastSeenAt ?? "—"}`);
        return 0;
      }
      if (sub === "revoke") {
        const ok = await devices.revoke(rest[0] ?? "");
        console.log(ok ? "Eşleşme kaldırıldı. (Çalışan companion'ı yeniden başlat.)" : "Böyle etkin bir cihaz yok.");
        return ok ? 0 : 1;
      }
      break;
    }
    case "audit": {
      if (sub === "verify") {
        const result = await verifyAuditLog(path.join(dataDir, "audit.log"));
        console.log(result.ok ? `Denetim kaydı sağlam (${result.entries} kayıt).` : `BOZUK: satır ${result.brokenAtLine}: ${result.reason} (${result.entries} sağlam kayıt).`);
        return result.ok ? 0 : 1;
      }
      break;
    }
    case "config": {
      if (sub === "path") {
        console.log(configFile);
        return 0;
      }
      if (sub === "check") {
        const { config } = await loadConfig(configFile);
        const problems = checkConfig(config);
        const { problems: rootProblems } = await PathPolicy.create(config.roots, { dataDir, secretPatterns: config.policy.secretPatterns });
        const all = [...problems, ...rootProblems];
        console.log(all.length ? `Sorunlar:\n- ${all.join("\n- ")}` : "config.json geçerli.");
        return all.length ? 1 : 0;
      }
      break;
    }
    case "doctor":
      return doctor(dataDir);
    case undefined:
    case "help":
    case "--help":
      console.log(USAGE);
      return 0;
  }
  console.error(USAGE);
  return 2;
}

async function doctor(dataDir: string): Promise<number> {
  const [major, minor] = process.versions.node.split(".").map(Number);
  const nodeOk = major > 22 || (major === 22 && minor >= 18);
  console.log(`Node.js ${process.versions.node} ${nodeOk ? "✓" : "✗ (22.18 veya üstü gerekli)"}`);
  console.log(`Veri klasörü: ${dataDir}`);
  const addresses = privateIPv4Addresses();
  console.log(`Yerel ağ adresleri: ${addresses.map((a) => `${a.address} (${a.name})`).join(", ") || "yok"}`);
  try {
    await fs.access(path.join(dataDir, "config.json"));
    console.log("config.json ✓");
  } catch {
    console.log("config.json yok (ilk 'start' oluşturur).");
  }
  return nodeOk ? 0 : 1;
}

async function start(dataDir: string, flags: Map<string, string | true>): Promise<number> {
  const core = await CompanionCore.create({ dataDir });
  if (flags.has("lan")) core.config.network.lan = true;
  if (typeof flags.get("bind") === "string") {
    core.config.network.lan = true;
    core.config.network.bindAddress = flags.get("bind") as string;
  }
  if (typeof flags.get("port") === "string") core.config.network.port = Number(flags.get("port"));
  const host = chooseBindAddress(core.config.network);
  const server = await startServer(core, { host, port: core.config.network.port });
  const consoleUi = new CompanionConsole(core, server, host);
  console.log(`\nJARVIS PC Companion ${VERSION} çalışıyor.`);
  consoleUi.printStatus();
  if (core.problems.length) console.log(`Klasör sorunları:\n- ${core.problems.join("\n- ")}`);
  if (core.policy.roots.length === 0) console.log("Henüz paylaşılan klasör yok: jarvis-pc roots add <klasör> --name <ad> [--write]");
  if (!core.config.network.lan) console.log("Telefonun bağlanması için --lan ile başlat (Windows Güvenlik Duvarı 'Özel ağ' izni isteyebilir).");
  console.log('Komutlar için "help" yaz.\n');
  if (flags.has("pair")) await consoleUi.pair(false);

  let stopping = false;
  const stop = async (): Promise<void> => {
    if (stopping) return;
    stopping = true;
    console.log("\nKapatılıyor…");
    await server.close();
    await core.close();
    process.exit(0);
  };
  process.on("SIGINT", () => void stop());
  consoleUi.start(() => void stop());
  return new Promise<number>(() => {});
}

main().then(
  (code) => {
    if (code !== undefined) process.exitCode = code;
  },
  (error: unknown) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  },
);
