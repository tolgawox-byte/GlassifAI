// Where the companion may read and write. Every file tool resolves its paths here.
//
// Rules:
// - Only folders the owner added as roots are reachable. A path is either
//   "<RootName>/<relative>" or an absolute "C:\..." path inside a root.
// - Containment is checked twice: on the text of the path, and again on the
//   real path after symlinks, junctions and 8.3 short names are resolved.
// - Device names (NUL, COM1 …), alternate data streams ("a.txt:x"), UNC and
//   \\?\ paths, trailing dots or spaces and ".." are refused outright.
// - Secret-looking files (.env, keys, wallets …) are never read or written.
// - Writes never touch .git folders, Windows start-up folders, executables,
//   shortcuts or registry files, or the companion's own data folder.

import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { CompanionError } from "./util.ts";

export type Access = "read" | "write";

export interface RootConfig {
  name: string;
  path: string;
  access: Access;
}

export interface ResolvedRoot {
  name: string;
  /** The folder as configured (normalized). */
  path: string;
  /** The folder's real path (links resolved). */
  real: string;
  access: Access;
}

export interface ResolvedPath {
  /** Real absolute path (for an item that does not exist yet: its real parent + the new names). */
  abs: string;
  root: ResolvedRoot;
  /** Path relative to the root, with "\" separators; "" for the root itself. */
  relative: string;
  /** "<RootName>/<relative with / separators>", safe to show and speak. */
  display: string;
  exists: boolean;
}

export const DEFAULT_SECRET_PATTERNS: readonly string[] = [
  ".env", ".env.*", "*.pem", "*.key", "*.pfx", "*.p12", "*.p8", "*.ppk", "*.keystore", "*.jks",
  "*.kdbx", "*.ovpn", "id_rsa*", "id_dsa*", "id_ecdsa*", "id_ed25519*", ".ssh", ".aws", ".azure",
  ".gnupg", ".kube", ".docker", ".npmrc", ".pypirc", ".netrc", "_netrc", ".git-credentials",
  "credentials", "credentials.*", "secrets.*", "wallet.dat", "*.mobileprovision",
];

export const DEFAULT_SKIP_DIRS: readonly string[] = [
  "node_modules", ".git", ".hg", ".svn", "__pycache__", ".venv", "venv", ".next", ".cache",
  "target", "DerivedData", "Pods", ".gradle", ".idea", ".vs",
];

/** Never written: programs, libraries, shortcuts, installers, registry files, script hosts. */
const BLOCKED_WRITE_EXTENSIONS = new Set([
  ".exe", ".dll", ".sys", ".drv", ".ocx", ".scr", ".com", ".pif", ".cpl", ".msi", ".msp", ".msix",
  ".msixbundle", ".appx", ".appxbundle", ".lnk", ".url", ".reg", ".hta", ".vbs", ".vbe", ".jse",
  ".wsf", ".wsh", ".ws", ".scf", ".inf", ".gadget", ".application", ".ps1xml", ".psc1", ".msc",
  ".library-ms", ".searchconnector-ms", ".settingcontent-ms",
]);

/** Allowed with an approval, but the approval card says it is a script. */
const SCRIPT_EXTENSIONS = new Set([".bat", ".cmd", ".ps1", ".psm1", ".psd1", ".sh", ".js", ".mjs", ".cjs", ".py", ".rb", ".pl"]);

const RESERVED_NAME = /^(con|prn|aux|nul|com[0-9\u00b9\u00b2\u00b3]|lpt[0-9\u00b9\u00b2\u00b3]|conin\$|conout\$|clock\$)$/i;
// Windows-invalid characters, control characters, and invisible or
// direction-changing characters that can disguise a name on an approval card
// ("evil\u202eexe.txt" shows as "eviltxt.exe").
const INVALID_COMPONENT_CHARS = /[<>:"|?*\u0000-\u001f\u007f\u00ad\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/;
const ROOT_NAME = /^[\p{L}\p{N}][\p{L}\p{N} ._-]{0,39}$/u;

export function pathError(code: string, message: string): CompanionError {
  return new CompanionError(code, message, { status: code === "not_found" ? 404 : 403 });
}

function lower(p: string): string {
  return p.toLowerCase();
}

/** True if `child` is `parent` or inside it (case-insensitive, Windows separators). */
export function isWithin(parent: string, child: string): boolean {
  const p = lower(path.win32.normalize(parent)).replace(/\\+$/, "");
  const c = lower(path.win32.normalize(child)).replace(/\\+$/, "");
  return c === p || c.startsWith(p + "\\");
}

function components(relative: string): string[] {
  return relative.split(/[\\/]+/).filter((part) => part.length > 0);
}

/** Rejects names Windows treats specially. */
export function checkComponent(name: string): void {
  if (name === "." || name === "..") throw pathError("invalid_path", "Yolda '.' veya '..' kullanılamaz.");
  if (INVALID_COMPONENT_CHARS.test(name)) {
    throw pathError("invalid_path", `Geçersiz karakter içeren ad: ${JSON.stringify(name)}.`);
  }
  if (/[. ]$/.test(name)) throw pathError("invalid_path", `Nokta veya boşlukla biten ad kullanılamaz: ${JSON.stringify(name)}.`);
  const stem = name.split(".")[0];
  if (RESERVED_NAME.test(stem) || RESERVED_NAME.test(name)) {
    throw pathError("invalid_path", `Windows aygıt adı kullanılamaz: ${JSON.stringify(name)}.`);
  }
}

function checkRawInput(input: unknown): string {
  if (typeof input !== "string") throw pathError("invalid_path", "Yol metin olmalı.");
  const text = input.trim();
  if (text.length === 0) throw pathError("invalid_path", "Yol boş.");
  if (text.length > 1024) throw pathError("invalid_path", "Yol çok uzun.");
  if (/[\u0000-\u001f\u007f­​-‏‪-‮⁠-⁤⁦-⁩﻿]/.test(text)) {
    throw pathError("invalid_path", "Yolda kontrol veya görünmez karakter var.");
  }
  if (/^[\\/]{2}/.test(text)) throw pathError("invalid_path", "Ağ (UNC) ve \\\\?\\ yolları desteklenmiyor.");
  if (/^[a-zA-Z]:(?![\\/])/.test(text)) throw pathError("invalid_path", "Sürücüye göreli yol (C:dosya) kullanılamaz.");
  if (/^[\\/]/.test(text)) throw pathError("invalid_path", "Kök klasör adıyla başlayan bir yol ver (ör. Projeler/AutoLoom).");
  return text;
}

function compileGlob(pattern: string): RegExp {
  const escaped = pattern
    .toLowerCase()
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*/g, ".*")
    .replace(/\?/g, ".");
  return new RegExp(`^${escaped}$`);
}

/** Folders that must never become roots: system folders, AppData, the profile itself, the companion's data. */
export function forbiddenRootReason(real: string, dataDir: string, systemFolders: readonly string[] = defaultSystemFolders()): string | undefined {
  const normalized = path.win32.normalize(real);
  if (/^[a-zA-Z]:\\?$/.test(normalized)) return "Bir sürücünün tamamı paylaşılamaz; bir alt klasör seç.";
  const home = os.homedir();
  if (lower(normalized) === lower(home) || isWithin(normalized, home)) {
    return "Kullanıcı klasörünün tamamı paylaşılamaz; Belgeler veya Projeler gibi bir alt klasör seç.";
  }
  for (const folder of systemFolders) {
    if (isWithin(folder, normalized)) return `Sistem veya uygulama verisi klasörü paylaşılamaz (${folder}).`;
  }
  if (isWithin(normalized, dataDir) || isWithin(dataDir, normalized)) {
    return "Companion'ın kendi veri klasörü (anahtarlar, cihazlar, kayıtlar) paylaşılamaz.";
  }
  return undefined;
}

/** System and per-user application folders that must never be shared. */
export function defaultSystemFolders(): string[] {
  const env = process.env;
  const home = os.homedir();
  return [
    env.SystemRoot ?? "C:\\Windows",
    env.ProgramFiles ?? "C:\\Program Files",
    env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)",
    env.ProgramData ?? "C:\\ProgramData",
    env.APPDATA ?? path.join(home, "AppData", "Roaming"),
    env.LOCALAPPDATA ?? path.join(home, "AppData", "Local"),
    path.join(home, "AppData"),
  ];
}

/** Windows start-up folders: a file there runs at the next sign-in. */
function autostartFolders(): string[] {
  const home = os.homedir();
  const appData = process.env.APPDATA ?? path.join(home, "AppData", "Roaming");
  const programData = process.env.ProgramData ?? "C:\\ProgramData";
  return [
    path.join(appData, "Microsoft", "Windows", "Start Menu", "Programs", "Startup"),
    path.join(programData, "Microsoft", "Windows", "Start Menu", "Programs", "StartUp"),
  ];
}

/**
 * A hard link inside a root can point at a file anywhere on the same drive,
 * and no real-path check can see it. Files with more than one link are never
 * written (reading them is allowed; names still pass the secret filter).
 */
async function assertSingleLink(resolved: ResolvedPath): Promise<void> {
  const stat = await fs.lstat(resolved.abs);
  if (stat.isFile() && stat.nlink > 1) {
    throw pathError("write_blocked", `${resolved.display} başka bir konumla sabit bağlantılı (hard link); güvenlik için değiştirilmez.`);
  }
}

export interface PolicyOptions {
  dataDir: string;
  secretPatterns?: readonly string[];
  /** Folders that can never be roots. Defaults to Windows, Program Files, ProgramData and AppData; tests narrow it. */
  systemFolders?: readonly string[];
}

export class PathPolicy {
  readonly roots: readonly ResolvedRoot[];
  readonly dataDir: string;
  private readonly secretMatchers: RegExp[];

  private constructor(roots: ResolvedRoot[], options: PolicyOptions) {
    this.roots = roots;
    this.dataDir = options.dataDir;
    this.secretMatchers = (options.secretPatterns ?? DEFAULT_SECRET_PATTERNS).map(compileGlob);
  }

  /** Validates the configured roots. Invalid ones are left out and reported. */
  static async create(configRoots: readonly RootConfig[], options: PolicyOptions): Promise<{ policy: PathPolicy; problems: string[] }> {
    const problems: string[] = [];
    const roots: ResolvedRoot[] = [];
    const seen = new Set<string>();
    for (const root of configRoots) {
      const result = await PathPolicy.validateRoot(root, options.dataDir, options.systemFolders);
      if (typeof result === "string") {
        problems.push(`${root.name}: ${result}`);
        continue;
      }
      if (seen.has(lower(result.name))) {
        problems.push(`${root.name}: aynı adla iki klasör var.`);
        continue;
      }
      seen.add(lower(result.name));
      roots.push(result);
    }
    return { policy: new PathPolicy(roots, options), problems };
  }

  static async validateRoot(root: RootConfig, dataDir: string, systemFolders?: readonly string[]): Promise<ResolvedRoot | string> {
    if (!root || typeof root.name !== "string" || !ROOT_NAME.test(root.name)) {
      return "Kök adı 1–40 harf, rakam, boşluk, nokta, alt çizgi veya tire olmalı.";
    }
    if (root.access !== "read" && root.access !== "write") return "Erişim 'read' veya 'write' olmalı.";
    if (typeof root.path !== "string" || !/^[a-zA-Z]:[\\/]/.test(root.path)) {
      return "Klasör, sürücü harfiyle başlayan tam bir yol olmalı (ör. C:\\Users\\ad\\Projeler).";
    }
    const normalized = path.win32.normalize(root.path).replace(/\\+$/, "");
    let real: string;
    try {
      real = await fs.realpath(normalized);
      const stat = await fs.stat(real);
      if (!stat.isDirectory()) return "Bu bir klasör değil.";
    } catch {
      return "Klasör bulunamadı.";
    }
    for (const candidate of [normalized, real]) {
      const reason = forbiddenRootReason(candidate, dataDir, systemFolders);
      if (reason) return reason;
    }
    return { name: root.name, path: normalized, real, access: root.access };
  }

  listRoots(): Array<{ name: string; access: Access }> {
    return this.roots.map((root) => ({ name: root.name, access: root.access }));
  }

  findRoot(name: string): ResolvedRoot | undefined {
    return this.roots.find((root) => lower(root.name) === lower(name));
  }

  /**
   * Resolves `input` to a real path inside a root.
   * mode "existing": must exist. "create": may not exist yet (missing parents allowed).
   */
  async resolve(input: unknown, need: Access, mode: "existing" | "create"): Promise<ResolvedPath> {
    const text = checkRawInput(input);
    let root: ResolvedRoot | undefined;
    let parts: string[];

    if (/^[a-zA-Z]:[\\/]/.test(text)) {
      // Refuse ".." in the raw text so "C:\Root\..\Other" is never normalized away.
      if (components(text.slice(2)).some((part) => part === "..")) {
        throw pathError("invalid_path", "Yolda '.' veya '..' kullanılamaz.");
      }
      const normalized = path.win32.normalize(text);
      root = this.roots.find((r) => isWithin(r.path, normalized) || isWithin(r.real, normalized));
      if (root) {
        const base = isWithin(root.path, normalized) ? root.path : root.real;
        parts = components(normalized.slice(base.length));
      } else {
        // Another spelling of a shared folder (8.3 short name, a link): decide on the real path.
        const real = await this.realPathOfAbsolute(normalized);
        root = real ? this.roots.find((r) => isWithin(r.real, real)) : undefined;
        if (!root || !real) throw pathError("outside_roots", "Bu yol paylaşılan klasörlerin dışında.");
        parts = components(real.slice(root.real.length));
      }
    } else {
      const all = components(text);
      const rootName = all[0];
      root = this.findRoot(rootName);
      if (!root) {
        const names = this.roots.map((r) => r.name).join(", ") || "(yok)";
        throw pathError("unknown_root", `"${rootName}" adında paylaşılan klasör yok. Paylaşılanlar: ${names}.`);
      }
      parts = all.slice(1);
    }

    for (const part of parts) checkComponent(part);
    const lexical = path.win32.join(root.real, ...parts);
    if (!isWithin(root.real, lexical)) throw pathError("outside_roots", "Bu yol paylaşılan klasörlerin dışında.");

    if (need === "write" && root.access !== "write") {
      throw pathError("read_only_root", `"${root.name}" klasörü yalnızca okunabilir olarak paylaşıldı.`);
    }

    let abs: string;
    let exists: boolean;
    try {
      abs = await fs.realpath(lexical);
      exists = true;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code !== "ENOENT" && code !== "ENOTDIR") throw error;
      if (mode === "existing") throw pathError("not_found", `Bulunamadı: ${this.displayOf(root, parts.join("\\"))}.`);
      abs = await this.realPathOfMissing(root, parts);
      exists = false;
    }
    if (!isWithin(root.real, abs)) {
      throw pathError("outside_roots", "Bu yol bir bağlantı (symlink/junction) üzerinden paylaşılan klasörün dışına çıkıyor.");
    }
    const relative = abs.length > root.real.length ? abs.slice(root.real.length).replace(/^\\+/, "") : "";
    const resolved: ResolvedPath = { abs, root, relative, display: this.displayOf(root, relative), exists };
    if (this.isSecret(resolved)) {
      throw pathError("protected_file", `${resolved.display} gizli anahtar veya parola dosyası gibi görünüyor; companion bunu açmaz.`);
    }
    if (need === "write") {
      this.assertWritable(resolved);
      if (exists) await assertSingleLink(resolved);
    }
    return resolved;
  }

  /** Real path of an absolute path (or of its deepest existing ancestor plus the missing names). */
  private async realPathOfAbsolute(absolute: string): Promise<string | undefined> {
    const missing: string[] = [];
    let current = absolute;
    for (let depth = 0; depth < 64; depth++) {
      try {
        const real = await fs.realpath(current);
        return missing.length ? path.win32.join(real, ...missing) : real;
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code !== "ENOENT" && code !== "ENOTDIR") return undefined;
        const parent = path.win32.dirname(current);
        if (parent === current) return undefined;
        missing.unshift(path.win32.basename(current));
        current = parent;
      }
    }
    return undefined;
  }

  /** Real path of the deepest existing ancestor, plus the names that do not exist yet. */
  private async realPathOfMissing(root: ResolvedRoot, parts: string[]): Promise<string> {
    for (let keep = parts.length - 1; keep >= 0; keep--) {
      const ancestor = path.win32.join(root.real, ...parts.slice(0, keep));
      try {
        const real = await fs.realpath(ancestor);
        const stat = await fs.stat(real);
        if (!stat.isDirectory()) throw pathError("invalid_path", "Yolun bir parçası klasör değil.");
        if (!isWithin(root.real, real)) {
          throw pathError("outside_roots", "Bu yol bir bağlantı üzerinden paylaşılan klasörün dışına çıkıyor.");
        }
        return path.win32.join(real, ...parts.slice(keep));
      } catch (error) {
        const code = (error as NodeJS.ErrnoException).code;
        if (code === "ENOENT" || code === "ENOTDIR") continue;
        throw error;
      }
    }
    return root.real;
  }

  displayOf(root: ResolvedRoot, relative: string): string {
    const rel = relative.replace(/\\/g, "/").replace(/^\/+/, "");
    return rel ? `${root.name}/${rel}` : root.name;
  }

  /** Secret-looking names anywhere below the root (".ssh/config" counts too). */
  isSecret(resolved: Pick<ResolvedPath, "relative">): boolean {
    return components(resolved.relative).some((part) => this.isSecretName(part));
  }

  isSecretName(name: string): boolean {
    const lowered = lower(name);
    return this.secretMatchers.some((matcher) => matcher.test(lowered));
  }

  assertWritable(resolved: ResolvedPath): void {
    const parts = components(resolved.relative);
    if (parts.some((part) => lower(part) === ".git")) {
      throw pathError("write_blocked", ".git klasörlerine yazılamaz (git kancaları kod çalıştırabilir).");
    }
    const ext = lower(path.win32.extname(resolved.abs));
    if (BLOCKED_WRITE_EXTENSIONS.has(ext)) {
      throw pathError("write_blocked", `${ext} dosyaları (program, kısayol, kurulum veya kayıt defteri) companion tarafından yazılamaz.`);
    }
    for (const folder of autostartFolders()) {
      if (isWithin(folder, resolved.abs)) throw pathError("write_blocked", "Windows başlangıç klasörüne yazılamaz.");
    }
    if (isWithin(this.dataDir, resolved.abs)) throw pathError("write_blocked", "Companion'ın kendi veri klasörüne yazılamaz.");
  }

  isScript(absPath: string): boolean {
    return SCRIPT_EXTENSIONS.has(lower(path.win32.extname(absPath)));
  }
}
