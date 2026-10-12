import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import path from "node:path";
import { after, before, describe, test } from "node:test";
import { deflateSync } from "node:zlib";
import type { CompanionCore } from "../src/core.ts";
import type { TaskRecord } from "../src/tasks.ts";
import { docxText, htmlText, pdfText, rtfText, xlsxSharedStrings, xlsxSheetRows } from "../src/tools/documents.ts";
import { foldForSearch, looksBinary } from "../src/tools/fsutil.ts";
import { ZipReader } from "../src/tools/zip.ts";
import { CompanionError } from "../src/util.ts";
import { makeCore, makeZip } from "./helpers.ts";
import type { TestCore } from "./helpers.ts";

let t: TestCore;
let core: CompanionCore;
let projects: string;

/** Runs a tool as the phone UI would after a tap (pre-approved) and waits for the result. */
async function run(tool: string, args: Record<string, unknown>, approve = true): Promise<TaskRecord> {
  const task = await core.tasks.submit({ deviceId: "d_test", source: "phone", tool, args, preApprovedBy: approve ? "phone:d_test" : undefined });
  return core.tasks.waitForSettle(task.id, 15_000);
}

before(async () => {
  t = await makeCore({
    roots: [
      { name: "Projeler", access: "write" },
      { name: "Arsiv", access: "read" },
    ],
    configure: (config) => {
      config.commands = [
        { id: "ok", label: "Başarılı komut", exe: process.execPath, args: ["-e", "console.log('merhaba'); process.exit(0)"], shell: false, timeoutSec: 30, needsWriteAccess: false },
        { id: "fail", label: "Başarısız komut", exe: process.execPath, args: ["-e", "console.error('HATA: test başarısız'); process.exit(3)"], shell: false, timeoutSec: 30, needsWriteAccess: false },
        { id: "long", label: "Uzun komut", exe: process.execPath, args: ["-e", "setInterval(() => console.log('çalışıyor'), 100)"], shell: false, timeoutSec: 30, needsWriteAccess: false },
        { id: "short", label: "Zaman aşımı", exe: process.execPath, args: ["-e", "setInterval(() => {}, 1000)"], shell: false, timeoutSec: 5, needsWriteAccess: false },
        { id: "build", label: "Derle", exe: process.execPath, args: ["-e", "require('fs').writeFileSync('out.txt','x')"], shell: false, timeoutSec: 30, needsWriteAccess: true },
      ];
      config.apps = [{ id: "nodeapp", label: "Node", exe: process.execPath, args: ["-e", "setTimeout(()=>{}, 200)"], pathArg: "folder" }];
    },
  });
  core = t.core;
  projects = t.roots.Projeler;
  await fs.mkdir(path.join(projects, "AutoLoom", "src"), { recursive: true });
  await fs.writeFile(path.join(projects, "AutoLoom", "README.md"), "# AutoLoom\nGözlük asistanı.\n");
  await fs.writeFile(path.join(projects, "AutoLoom", "src", "main.swift"), "let x = 1\nprint(\"Çalışma alanı\")\n");
  await fs.writeFile(path.join(projects, "AutoLoom", "package.json"), JSON.stringify({ name: "autoloom", version: "1.0.0", scripts: { test: "node test.js" } }));
  await fs.mkdir(path.join(projects, "AutoLoom", ".git"));
  await fs.writeFile(path.join(projects, "AutoLoom", ".git", "HEAD"), "ref: refs/heads/jarvis-v1\n");
  await fs.mkdir(path.join(projects, "AutoLoom", "node_modules", "dep"), { recursive: true });
  await fs.writeFile(path.join(projects, "AutoLoom", "node_modules", "dep", "AutoLoomHidden.js"), "x");
  await fs.writeFile(path.join(projects, "AutoLoom", ".env"), "SECRET=1");
  await fs.writeFile(path.join(projects, "binary.bin"), Buffer.from([0, 1, 2, 3, 0, 5]));
  await fs.writeFile(path.join(t.roots.Arsiv, "rapor.txt"), "Arşiv raporu");
});

after(async () => {
  await t.cleanup();
});

describe("read tools", () => {
  test("list_dir marks secrets as protected and sorts folders first", async () => {
    const task = await run("list_dir", { path: "Projeler/AutoLoom" }, false);
    assert.equal(task.state, "completed", task.error?.message);
    assert.equal(task.approval.required, false, "reads do not ask");
    const entries = (task.result as { entries: Array<{ name: string; type: string; protected: boolean }> }).entries;
    assert.equal(entries[0].type, "dir");
    assert.ok(entries.find((e) => e.name === ".env")?.protected);
  });

  test("search_files: accent/case-insensitive, skips node_modules and secrets, honest empty result", async () => {
    const found = await run("search_files", { query: "autoloom" }, false);
    const matches = (found.result as { matches: Array<{ path: string; type: string }> }).matches;
    assert.equal(matches[0].path, "Projeler/AutoLoom");
    assert.equal(matches[0].type, "dir");
    assert.ok(!matches.some((m) => m.path.includes("node_modules")));
    const turkish = await run("search_files", { query: "MAIN.swift" }, false);
    assert.equal((turkish.result as { matches: unknown[] }).matches.length, 1);
    const glob = await run("search_files", { query: "*.md", kind: "file" }, false);
    assert.ok((glob.result as { matches: Array<{ path: string }> }).matches.some((m) => m.path.endsWith("README.md")));
    const none = await run("search_files", { query: "kesinlikleyokboyle" }, false);
    assert.match(none.resultText ?? "", /sonuç bulunamadı/);
    const env = await run("search_files", { query: ".env" }, false);
    assert.equal((env.result as { matches: unknown[] }).matches.length, 0, "secret files never show up in search");
  });

  test("searches never follow a junction out of the shared folder", async () => {
    const outside = await fs.mkdtemp(path.join(path.dirname(projects), "..", "jpc-outside-"));
    try {
      await fs.writeFile(path.join(outside, "DisaridakiGizliRapor.txt"), "outside secret line");
      await fs.symlink(outside, path.join(projects, "kacis"), "junction");
      const byName = await run("search_files", { query: "DisaridakiGizliRapor" }, false);
      assert.equal((byName.result as { matches: unknown[] }).matches.length, 0);
      const byText = await run("search_text", { query: "outside secret" }, false);
      assert.equal((byText.result as { matches: unknown[] }).matches.length, 0);
      await assert.rejects(
        core.tasks.submit({ deviceId: "d", source: "phone", tool: "read_text", args: { path: "Projeler/kacis/DisaridakiGizliRapor.txt" } }),
        (e: CompanionError) => e.code === "outside_roots",
      );
    } finally {
      await fs.rm(path.join(projects, "kacis"), { force: true, recursive: false }).catch(() => fs.rmdir(path.join(projects, "kacis")));
      await fs.rm(outside, { recursive: true, force: true });
    }
  });

  test("search_text finds lines, folding Turkish characters", async () => {
    const task = await run("search_text", { query: "calisma alani" }, false);
    const matches = (task.result as { matches: Array<{ path: string; line: number }> }).matches;
    assert.equal(matches.length, 1);
    assert.equal(matches[0].path, "Projeler/AutoLoom/src/main.swift");
    assert.equal(matches[0].line, 2);
  });

  test("read_text reads text, refuses binary and secrets, and pages large files", async () => {
    const ok = await run("read_text", { path: "Projeler/AutoLoom/README.md" }, false);
    assert.equal((ok.result as { text: string }).text, "# AutoLoom\nGözlük asistanı.\n");
    const binary = await run("read_text", { path: "Projeler/binary.bin" }, false);
    assert.equal(binary.state, "failed");
    assert.equal(binary.error?.code, "binary_file");
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "read_text", args: { path: "Projeler/AutoLoom/.env" } }), (e: CompanionError) => e.code === "protected_file");
    const big = "ş".repeat(1000); // 2 bytes each
    await fs.writeFile(path.join(projects, "big.txt"), big);
    const page = await run("read_text", { path: "Projeler/big.txt", maxBytes: 301 }, false);
    const first = page.result as { text: string; nextOffset: number; eof: boolean };
    assert.equal(first.eof, false);
    assert.ok(!first.text.includes("�"), "never cuts a character in half");
    const rest = await run("read_text", { path: "Projeler/big.txt", offset: first.nextOffset, maxBytes: 100_000 }, false);
    assert.equal(first.text + (rest.result as { text: string }).text, big);
  });

  test("analyze_project reports the stack and the branch without running git", async () => {
    const task = await run("analyze_project", { path: "Projeler/AutoLoom" }, false);
    assert.equal(task.state, "completed", task.error?.message);
    const result = task.result as { stack: string[]; gitBranch: string; package: { name: string }; topLanguages: Array<{ language: string }> };
    assert.ok(result.stack.includes("Node.js / npm"));
    assert.equal(result.gitBranch, "jarvis-v1");
    assert.equal(result.package.name, "autoloom");
    assert.match(task.resultText ?? "", /dal: jarvis-v1/);
  });
});

describe("write tools", () => {
  test("create_file asks, writes, verifies by checksum, and can be undone", async () => {
    const pending = await core.tasks.submit({ deviceId: "d", source: "mcp", tool: "create_file", args: { path: "Projeler/notlar/yeni.md", content: "Merhaba" } });
    assert.equal(pending.state, "awaiting_approval");
    assert.match(pending.summary, /Dosya oluştur: Projeler\/notlar\/yeni\.md/);
    await core.tasks.approve(pending.id, "phone:d", pending.argsDigest);
    const done = await core.tasks.waitForSettle(pending.id, 5000);
    assert.equal(done.state, "completed", done.error?.message);
    assert.equal(done.verification?.ok, true);
    assert.equal(await fs.readFile(path.join(projects, "notlar", "yeni.md"), "utf8"), "Merhaba");

    const undo = await run("undo_task", { taskId: done.id });
    assert.equal(undo.state, "completed", undo.error?.message);
    await assert.rejects(fs.stat(path.join(projects, "notlar", "yeni.md")));
    await assert.rejects(fs.stat(path.join(projects, "notlar")), "the folder it created is removed too");
    assert.equal(core.tasks.get(done.id)?.undoneBy, undo.id);
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "undo_task", args: { taskId: done.id } }), (e: CompanionError) => e.code === "already_undone");
  });

  test("create_file refuses to replace a file unless overwrite, which is destructive and backed up", async () => {
    await fs.writeFile(path.join(projects, "mevcut.txt"), "eski");
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "create_file", args: { path: "Projeler/mevcut.txt", content: "yeni" } }), (e: CompanionError) => e.code === "exists");
    const over = await core.tasks.submit({ deviceId: "d", source: "mcp", tool: "create_file", args: { path: "Projeler/mevcut.txt", content: "yeni", overwrite: true } });
    assert.equal(over.risk, "destructive");
    assert.equal(over.state, "awaiting_approval");
    await core.tasks.approve(over.id, "phone:d", over.argsDigest);
    const done = await core.tasks.waitForSettle(over.id, 5000);
    assert.equal(await fs.readFile(path.join(projects, "mevcut.txt"), "utf8"), "yeni");
    const undo = await run("undo_task", { taskId: done.id });
    assert.equal(undo.state, "completed", undo.error?.message);
    assert.equal(await fs.readFile(path.join(projects, "mevcut.txt"), "utf8"), "eski");
  });

  test("undo refuses when the file changed afterwards", async () => {
    const created = await run("create_file", { path: "Projeler/degisen.txt", content: "1" });
    await fs.writeFile(path.join(projects, "degisen.txt"), "2");
    const undo = await run("undo_task", { taskId: created.id });
    assert.equal(undo.state, "failed");
    assert.equal(undo.error?.code, "changed_since");
    assert.equal(await fs.readFile(path.join(projects, "degisen.txt"), "utf8"), "2", "nothing was touched");
  });

  test("replace_in_file needs an unambiguous match and keeps the BOM", async () => {
    const file = path.join(projects, "config.txt");
    await fs.writeFile(file, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from("a=1\nb=1\n")]));
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "replace_in_file", args: { path: "Projeler/config.txt", find: "=1", replace: "=2" } }), (e: CompanionError) => e.code === "match_count");
    const task = await run("replace_in_file", { path: "Projeler/config.txt", find: "=1", replace: "=2", expectedCount: 2 });
    assert.equal(task.state, "completed", task.error?.message);
    const bytes = await fs.readFile(file);
    assert.deepEqual([...bytes.subarray(0, 3)], [0xef, 0xbb, 0xbf]);
    assert.equal(bytes.subarray(3).toString("utf8"), "a=2\nb=2\n");
  });

  test("append_text, make_dir, rename_path and their undo", async () => {
    await fs.writeFile(path.join(projects, "log.txt"), "satır1");
    const appended = await run("append_text", { path: "Projeler/log.txt", content: "satır2" });
    assert.equal(appended.state, "completed", appended.error?.message);
    assert.equal(await fs.readFile(path.join(projects, "log.txt"), "utf8"), "satır1\nsatır2");
    const dir = await run("make_dir", { path: "Projeler/a/b/c" });
    assert.equal(dir.state, "completed");
    const moved = await run("rename_path", { from: "Projeler/log.txt", to: "Projeler/a/log.txt" });
    assert.equal(moved.state, "completed", moved.error?.message);
    assert.equal((await run("undo_task", { taskId: moved.id })).state, "completed");
    assert.equal(await fs.readFile(path.join(projects, "log.txt"), "utf8"), "satır1\nsatır2");
    assert.equal((await run("undo_task", { taskId: appended.id })).state, "completed");
    assert.equal(await fs.readFile(path.join(projects, "log.txt"), "utf8"), "satır1");
    assert.equal((await run("undo_task", { taskId: dir.id })).state, "completed");
    await assert.rejects(fs.stat(path.join(projects, "a")));
  });

  test("move_to_trash is destructive, keeps the item restorable, and never removes the root", async () => {
    await fs.mkdir(path.join(projects, "eski-klasor"));
    await fs.writeFile(path.join(projects, "eski-klasor", "x.txt"), "x");
    const pending = await core.tasks.submit({ deviceId: "d", source: "mcp", tool: "move_to_trash", args: { path: "Projeler/eski-klasor" } });
    assert.equal(pending.state, "awaiting_approval");
    assert.equal(pending.risk, "destructive");
    await core.tasks.approve(pending.id, "phone:d", pending.argsDigest);
    const done = await core.tasks.waitForSettle(pending.id, 5000);
    assert.equal(done.state, "completed", done.error?.message);
    await assert.rejects(fs.stat(path.join(projects, "eski-klasor")));
    const restore = await run("undo_task", { taskId: done.id });
    assert.equal(restore.state, "completed", restore.error?.message);
    assert.equal(await fs.readFile(path.join(projects, "eski-klasor", "x.txt"), "utf8"), "x");
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "move_to_trash", args: { path: "Projeler" } }), (e: CompanionError) => e.code === "invalid_path");
  });

  test("changing the PC's settings voids approvals given under the old rules", async () => {
    const waiting = await core.tasks.submit({ deviceId: "d", source: "mcp", tool: "create_file", args: { path: "Projeler/sonra.txt", content: "x" } });
    assert.equal(waiting.state, "awaiting_approval");
    await core.reload();
    assert.equal(core.tasks.get(waiting.id)?.state, "cancelled");
    assert.equal(core.tasks.get(waiting.id)?.error?.code, "policy_changed");
    await assert.rejects(core.tasks.approve(waiting.id, "phone:d", waiting.argsDigest), (e: CompanionError) => e.code === "not_awaiting_approval");
  });

  test("read-only roots and blocked file types cannot be written", async () => {
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "create_file", args: { path: "Arsiv/yeni.txt", content: "x" } }), (e: CompanionError) => e.code === "read_only_root");
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "create_file", args: { path: "Projeler/run.lnk", content: "x" } }), (e: CompanionError) => e.code === "write_blocked");
    const script = await core.tasks.submit({ deviceId: "d", source: "mcp", tool: "create_file", args: { path: "Projeler/build.ps1", content: "Write-Host hi" } });
    assert.ok(script.warnings.some((w) => /betik/.test(w)), "scripts carry a warning on the approval card");
    await core.tasks.deny(script.id, "phone:d");
  });
});

describe("programs and commands", () => {
  test("run_command: success, failure with output tail, and the folder rule", async () => {
    const ok = await run("run_command", { command: "ok", path: "Projeler/AutoLoom" });
    assert.equal(ok.state, "completed", ok.error?.message);
    assert.equal((ok.result as { exitCode: number }).exitCode, 0);
    assert.match((ok.result as { outputTail: string }).outputTail, /merhaba/);
    const failed = await run("run_command", { command: "fail", path: "Projeler/AutoLoom" });
    assert.equal(failed.state, "completed", "the command ran; its own failure is reported");
    assert.equal(failed.unsuccessful, true);
    assert.match(failed.resultText ?? "", /çıkış kodu 3/);
    assert.match(failed.resultText ?? "", /HATA: test başarısız/);
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "run_command", args: { command: "build", path: "Arsiv" } }), (e: CompanionError) => e.code === "read_only_root");
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "run_command", args: { command: "rm -rf", path: "Projeler" } }), (e: CompanionError) => e.code === "unknown_command");
    const mcp = await core.tasks.submit({ deviceId: "d", source: "mcp", tool: "run_command", args: { command: "ok", path: "Projeler" } });
    assert.equal(mcp.state, "awaiting_approval", "commands always ask");
    await core.tasks.deny(mcp.id, "phone:d");
  });

  test("run_command can be cancelled (the process tree is killed) and times out", async () => {
    const task = await core.tasks.submit({ deviceId: "d", source: "phone", tool: "run_command", args: { command: "long", path: "Projeler" }, preApprovedBy: "phone:d" });
    for (let i = 0; i < 100 && !core.tasks.get(task.id)?.progress; i++) await new Promise((r) => setTimeout(r, 50));
    assert.match(core.tasks.get(task.id)?.progress?.message ?? "", /çalışıyor/, "progress lines reach the task");
    await core.tasks.cancel(task.id, "phone:d");
    const cancelled = await core.tasks.waitForSettle(task.id, 10_000);
    assert.equal(cancelled.state, "cancelled");
    const timed = await run("run_command", { command: "short", path: "Projeler" });
    assert.equal(timed.state, "failed");
    assert.equal(timed.error?.code, "timeout");
  });

  test("open_app starts only allowlisted programs with a shared folder", async () => {
    const opened = await run("open_app", { app: "nodeapp", path: "Projeler/AutoLoom" });
    assert.equal(opened.state, "completed", opened.error?.message);
    assert.equal(opened.verification?.ok, true);
    assert.ok((opened.result as { pid: number }).pid > 0);
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "open_app", args: { app: "cmd" } }), (e: CompanionError) => e.code === "unknown_app");
    await assert.rejects(core.tasks.submit({ deviceId: "d", source: "phone", tool: "open_app", args: { app: "nodeapp", path: "Projeler/AutoLoom/README.md" } }), (e: CompanionError) => e.code === "not_a_folder");
  });
});

describe("documents", () => {
  test("extract_text reads docx, xlsx and pptx made by a ZIP writer", async () => {
    const docx = makeZip({
      "word/document.xml": '<w:document><w:body><w:p><w:r><w:t>Teklif</w:t></w:r><w:r><w:tab/><w:t xml:space="preserve"> 2026 &amp; sonrası</w:t></w:r></w:p><w:p><w:r><w:t>İkinci paragraf</w:t></w:r></w:p></w:body></w:document>',
    });
    await fs.writeFile(path.join(projects, "teklif.docx"), docx);
    const doc = await run("extract_text", { path: "Projeler/teklif.docx" }, false);
    assert.equal(doc.state, "completed", doc.error?.message);
    assert.equal((doc.result as { text: string }).text, "Teklif\t 2026 & sonrası\nİkinci paragraf");

    const xlsx = makeZip({
      "xl/sharedStrings.xml": "<sst><si><t>Ürün</t></si><si><t>Fiyat</t></si><si><r><t>Gözlük</t></r></si></sst>",
      "xl/worksheets/sheet1.xml": '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>299.5</v></c></row></sheetData></worksheet>',
    });
    await fs.writeFile(path.join(projects, "fiyat.xlsx"), xlsx);
    const sheet = await run("extract_text", { path: "Projeler/fiyat.xlsx" }, false);
    assert.equal((sheet.result as { text: string }).text, "--- Sayfa 1 ---\nÜrün\tFiyat\nGözlük\t\t299.5");

    const pptx = makeZip({
      "ppt/slides/slide2.xml": "<p:sld><a:p><a:r><a:t>Sonuç</a:t></a:r></a:p></p:sld>",
      "ppt/slides/slide1.xml": "<p:sld><a:p><a:r><a:t>Başlık</a:t></a:r></a:p></p:sld>",
    });
    await fs.writeFile(path.join(projects, "sunum.pptx"), pptx);
    const slides = await run("extract_text", { path: "Projeler/sunum.pptx" }, false);
    assert.equal((slides.result as { text: string }).text, "--- Slayt 1 ---\nBaşlık\n\n--- Slayt 2 ---\nSonuç");
  });

  test("zip bombs and broken files are refused", async () => {
    const bomb = makeZip({ "word/document.xml": Buffer.alloc(50 * 1024 * 1024, 0x41) });
    assert.ok(bomb.length < 200 * 1024, "compresses to a small file");
    const reader = new ZipReader(bomb, { maxEntryBytes: 1024 * 1024, maxTotalBytes: 2 * 1024 * 1024 });
    assert.throws(() => reader.text("word/document.xml"), (e: CompanionError) => e.code === "too_large");
    assert.throws(() => new ZipReader(Buffer.from("not a zip at all, just text"), { maxEntryBytes: 1, maxTotalBytes: 1 }), (e: CompanionError) => e.code === "bad_document");
  });

  test("format helpers: html, rtf (Windows-1254), xlsx strings, docx", () => {
    assert.equal(htmlText("<html><script>evil()</script><p>Merhaba&nbsp;<b>dünya</b></p><p>2</p></html>"), "Merhaba dünya\n2");
    assert.equal(rtfText("{\\rtf1\\ansi\\ansicpg1254 {\\fonttbl{\\f0 Arial;}}\\f0 G\\'fczel \\'feehir\\par Son}"), "Güzel şehir\nSon");
    assert.deepEqual(xlsxSharedStrings("<sst><si><t>a</t></si><si><r><t>b</t></r><r><t>c</t></r></si></sst>"), ["a", "bc"]);
    assert.deepEqual(xlsxSheetRows('<row r="1"><c r="B1"><v>5</v></c></row>', [], 10), ["\t5"]);
    assert.equal(docxText("<w:p><w:r><w:t>a</w:t></w:r><w:r><w:br/><w:t>b</w:t></w:r></w:p>"), "a\nb");
  });

  test("PDF: simple text is read; unreadable PDFs are reported, not guessed", async () => {
    const content = "BT /F1 12 Tf 72 712 Td (Merhaba PDF metni) Tj T* [(Ikinci) -250 (satir)] TJ ET";
    const stream = deflateSync(Buffer.from(content, "latin1"));
    const pdf = Buffer.concat([
      Buffer.from("%PDF-1.4\n1 0 obj << /Length " + stream.length + " /Filter /FlateDecode >>\nstream\n", "latin1"),
      stream,
      Buffer.from("\nendstream\nendobj\n%%EOF\n", "latin1"),
    ]);
    const parsed = pdfText(pdf, 10_000);
    assert.ok(parsed.readable);
    assert.match(parsed.text, /Merhaba PDF metni\nIkinci\s*satir/);
    await fs.writeFile(path.join(projects, "tarama.pdf"), Buffer.from("%PDF-1.4\n1 0 obj << /Length 4 /Filter /DCTDecode >>\nstream\n\xff\xd8\xff\xe0\nendstream\nendobj\n", "latin1"));
    const scanned = await run("extract_text", { path: "Projeler/tarama.pdf" }, false);
    assert.equal(scanned.state, "failed");
    assert.equal(scanned.error?.code, "unreadable_pdf");
  });

  test("helpers: binary detection and Turkish folding", () => {
    assert.ok(looksBinary(Buffer.from([0x41, 0x00, 0x42])));
    assert.ok(!looksBinary(Buffer.from("Merhaba\r\n", "utf8")));
    assert.ok(!looksBinary(Buffer.from([0xff, 0xfe, 0x41, 0x00])), "UTF-16 with BOM is text");
    assert.equal(foldForSearch("ÇALIŞMA Işık İzmir"), "calisma isik izmir");
  });
});
