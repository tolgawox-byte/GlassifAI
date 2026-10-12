// analyze_project: a structured overview of a code project, read-only.
// It never runs git or build tools: a repository's own config (core.fsmonitor,
// hooks, scripts) could execute code. The branch is read from .git/HEAD.

import { promises as fs } from "node:fs";
import path from "node:path";
import { CompanionError } from "../util.ts";
import { decodeText, displayFrom, formatBytes, requireKind, walk } from "./fsutil.ts";
import type { WalkStats } from "./fsutil.ts";
import type { ToolDefinition } from "./types.ts";
import { isWithin } from "../pathPolicy.ts";

const LANGUAGES: Record<string, string> = {
  ".swift": "Swift", ".rs": "Rust", ".ts": "TypeScript", ".tsx": "TypeScript", ".js": "JavaScript", ".mjs": "JavaScript",
  ".jsx": "JavaScript", ".py": "Python", ".go": "Go", ".java": "Java", ".kt": "Kotlin", ".cs": "C#", ".cpp": "C++",
  ".cc": "C++", ".c": "C", ".h": "C/C++ başlık", ".m": "Objective-C", ".mm": "Objective-C++", ".rb": "Ruby", ".php": "PHP",
  ".dart": "Dart", ".lua": "Lua", ".sql": "SQL", ".sh": "Shell", ".ps1": "PowerShell", ".html": "HTML", ".css": "CSS",
  ".scss": "SCSS", ".vue": "Vue", ".svelte": "Svelte", ".md": "Markdown",
};

const MARKERS: Array<{ test: (names: Set<string>, all: string[]) => boolean; label: string }> = [
  { test: (n) => n.has("package.json"), label: "Node.js / npm" },
  { test: (n) => n.has("tsconfig.json"), label: "TypeScript" },
  { test: (_n, all) => all.some((a) => a.endsWith(".xcodeproj")), label: "Xcode (iOS/macOS)" },
  { test: (n) => n.has("package.swift"), label: "Swift Package" },
  { test: (n) => n.has("cargo.toml"), label: "Rust (Cargo)" },
  { test: (n) => n.has("pyproject.toml") || n.has("requirements.txt") || n.has("setup.py"), label: "Python" },
  { test: (n) => n.has("go.mod"), label: "Go" },
  { test: (_n, all) => all.some((a) => a.endsWith(".sln") || a.endsWith(".csproj")), label: ".NET" },
  { test: (n) => n.has("pom.xml") || n.has("build.gradle") || n.has("build.gradle.kts"), label: "Java/Kotlin (JVM)" },
  { test: (n) => n.has("pubspec.yaml"), label: "Flutter/Dart" },
  { test: (n) => n.has("cmakelists.txt"), label: "CMake" },
  { test: (n) => n.has("dockerfile") || n.has("docker-compose.yml") || n.has("compose.yaml"), label: "Docker" },
  { test: (n) => n.has(".github"), label: "GitHub Actions/CI" },
];

async function readSmallText(file: string, max = 64 * 1024): Promise<string | undefined> {
  try {
    const stat = await fs.stat(file);
    if (!stat.isFile() || stat.size > max) return undefined;
    return decodeText(await fs.readFile(file));
  } catch {
    return undefined;
  }
}

/** The current branch from .git/HEAD (also for worktrees whose .git is a file), without running git. */
async function gitBranch(projectDir: string, rootReal: string): Promise<string | null> {
  const dotGit = path.join(projectDir, ".git");
  let gitDir = dotGit;
  try {
    const stat = await fs.stat(dotGit);
    if (stat.isFile()) {
      const pointer = (await readSmallText(dotGit, 4096))?.match(/^gitdir:\s*(.+)$/m)?.[1]?.trim();
      if (!pointer) return null;
      gitDir = path.resolve(projectDir, pointer);
      if (!isWithin(rootReal, gitDir)) return null; // never read outside the shared folder
    }
  } catch {
    return null;
  }
  const head = (await readSmallText(path.join(gitDir, "HEAD"), 4096))?.trim();
  if (!head) return null;
  const ref = /^ref:\s*refs\/heads\/(.+)$/.exec(head)?.[1];
  return ref ?? `(ayrık HEAD ${head.slice(0, 7)})`;
}

export const analyzeProject: ToolDefinition = {
  name: "analyze_project",
  title: "Projeyi incele",
  description:
    "Read-only overview of a code project folder on the PC: detected stack (npm, Xcode, Cargo, Python …), languages by file count, size, largest and most recently changed files, package scripts, README start and current git branch. Runs no commands.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    required: ["path"],
    properties: { path: { type: "string", minLength: 1, maxLength: 1024 } },
  },
  risk: "read",
  scope: "files:read",
  retrySafe: true,
  timeoutMs: 60_000,
  async prepare(args, ctx) {
    const resolved = await ctx.policy.resolve(args.path, "read", "existing");
    return { summary: `Projeyi incele: ${resolved.display}`, warnings: [] };
  },
  async run(args, ctx) {
    const resolved = await ctx.policy.resolve(args.path, "read", "existing");
    requireKind(await fs.stat(resolved.abs), "dir", resolved.display);
    const top = await fs.readdir(resolved.abs, { withFileTypes: true });
    const topNames = top.map((d) => d.name);
    const lowered = new Set(topNames.map((n) => n.toLowerCase()));
    const stack = MARKERS.filter((marker) => marker.test(lowered, topNames.map((n) => n.toLowerCase()))).map((m) => m.label);

    const stats: WalkStats = { visited: 0, truncated: false, timedOut: false };
    const byExtension = new Map<string, number>();
    let files = 0;
    let bytes = 0;
    const largest: Array<{ path: string; size: number }> = [];
    const recent: Array<{ path: string; modified: number }> = [];
    const skip = new Set(ctx.config.policy.skipDirs.map((d) => d.toLowerCase()));
    for await (const entry of walk(resolved.abs, {
      skipDirs: skip,
      isSecretName: (name) => ctx.policy.isSecretName(name),
      maxEntries: 80_000,
      deadline: Date.now() + 40_000,
      signal: ctx.signal,
    }, stats)) {
      if (!entry.dirent.isFile()) continue;
      let stat;
      try {
        stat = await fs.stat(entry.abs);
      } catch {
        continue;
      }
      files++;
      bytes += stat.size;
      const ext = path.extname(entry.name).toLowerCase();
      byExtension.set(ext, (byExtension.get(ext) ?? 0) + 1);
      const display = displayFrom(resolved.root.name, resolved.root.real, entry.abs);
      largest.push({ path: display, size: stat.size });
      if (largest.length > 20) largest.sort((a, b) => b.size - a.size).splice(10);
      recent.push({ path: display, modified: stat.mtimeMs });
      if (recent.length > 30) recent.sort((a, b) => b.modified - a.modified).splice(10);
    }
    largest.sort((a, b) => b.size - a.size).splice(5);
    recent.sort((a, b) => b.modified - a.modified).splice(8);

    const languages = [...byExtension.entries()]
      .filter(([ext]) => LANGUAGES[ext])
      .reduce((acc, [ext, count]) => acc.set(LANGUAGES[ext], (acc.get(LANGUAGES[ext]) ?? 0) + count), new Map<string, number>());
    const topLanguages = [...languages.entries()].sort((a, b) => b[1] - a[1]).slice(0, 6).map(([language, count]) => ({ language, files: count }));

    let packageInfo: Record<string, unknown> | null = null;
    const packageJson = await readSmallText(path.join(resolved.abs, "package.json"));
    if (packageJson) {
      try {
        const parsed = JSON.parse(packageJson) as { name?: string; version?: string; scripts?: Record<string, string>; dependencies?: object; devDependencies?: object };
        packageInfo = {
          name: parsed.name ?? null,
          version: parsed.version ?? null,
          scripts: Object.fromEntries(Object.entries(parsed.scripts ?? {}).slice(0, 25).map(([k, v]) => [k, String(v).slice(0, 160)])),
          dependencies: Object.keys(parsed.dependencies ?? {}).length,
          devDependencies: Object.keys(parsed.devDependencies ?? {}).length,
        };
      } catch {
        packageInfo = { error: "package.json okunamadı" };
      }
    }
    const readmeName = topNames.find((n) => /^readme(\.md|\.txt|\.markdown)?$/i.test(n));
    const readme = readmeName ? (await readSmallText(path.join(resolved.abs, readmeName), 512 * 1024))?.slice(0, 1500) ?? null : null;
    const branch = await gitBranch(resolved.abs, resolved.root.real);
    if (ctx.signal.aborted) throw new CompanionError("cancelled", "İptal edildi.");

    const name = path.basename(resolved.abs);
    const partial = stats.truncated || stats.timedOut;
    const text =
      `${name}: ${stack.length ? stack.join(", ") : "türü belirlenemeyen"} proje; ` +
      `${files.toLocaleString("tr-TR")} dosya, ${formatBytes(bytes)}` +
      (topLanguages.length ? `; en çok ${topLanguages[0].language} (${topLanguages[0].files} dosya)` : "") +
      (branch ? `; dal: ${branch}` : "") +
      (partial ? " (çok büyük olduğu için kısmen tarandı)" : "") +
      ".";
    return {
      result: {
        path: resolved.display,
        stack,
        files,
        bytes,
        topLanguages,
        topLevel: top.slice(0, 60).map((d) => ({ name: d.name, type: d.isDirectory() ? "dir" : "file" })),
        largestFiles: largest,
        recentlyChanged: recent.map((r) => ({ path: r.path, modified: new Date(r.modified).toISOString() })),
        package: packageInfo,
        readme,
        gitBranch: branch,
        scanned: stats.visited,
        partial,
      },
      text,
    };
  },
};
