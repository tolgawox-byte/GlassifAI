import assert from "node:assert/strict";
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { after, before, describe, test } from "node:test";
import { PathPolicy, checkComponent, forbiddenRootReason, isWithin } from "../src/pathPolicy.ts";
import { CompanionError } from "../src/util.ts";
import { tempDir } from "./helpers.ts";

async function rejects(promise: Promise<unknown>, code: string): Promise<void> {
  await assert.rejects(promise, (error: unknown) => {
    assert.ok(error instanceof CompanionError, `expected CompanionError, got ${String(error)}`);
    assert.equal(error.code, code, error.message);
    return true;
  });
}

/** The 8.3 short form of an existing path, as cmd.exe reports it. */
function shortPath(longPath: string): string {
  const result = spawnSync("cmd.exe", ["/d", "/s", "/c", `"for %I in ("${longPath}") do @echo %~sI"`], {
    encoding: "utf8",
    windowsVerbatimArguments: true,
  });
  return result.stdout.trim();
}

describe("PathPolicy", () => {
  let base: string;
  let dataDir: string;
  let outside: string;
  let policy: PathPolicy;

  before(async () => {
    base = await tempDir("jpc-policy-");
    dataDir = path.join(base, "data");
    outside = path.join(base, "outside");
    await fs.mkdir(dataDir);
    await fs.mkdir(outside);
    await fs.writeFile(path.join(outside, "secret.txt"), "outside");
    await fs.mkdir(path.join(base, "Projects", "AutoLoom", "src"), { recursive: true });
    await fs.mkdir(path.join(base, "Docs"), { recursive: true });
    await fs.writeFile(path.join(base, "Projects", "AutoLoom", "README.md"), "# AutoLoom");
    await fs.writeFile(path.join(base, "Projects", ".env"), "TOKEN=1");
    await fs.mkdir(path.join(base, "Projects", ".ssh"));
    await fs.writeFile(path.join(base, "Projects", ".ssh", "config"), "Host x");
    // A junction inside a root that points outside (junctions need no admin rights).
    await fs.symlink(outside, path.join(base, "Projects", "escape"), "junction");
    const created = await PathPolicy.create(
      [
        { name: "Projeler", path: path.join(base, "Projects"), access: "write" },
        { name: "Belgeler", path: path.join(base, "Docs"), access: "read" },
      ],
      { dataDir, systemFolders: [] },
    );
    assert.deepEqual(created.problems, []);
    policy = created.policy;
  });

  after(async () => {
    await fs.rm(base, { recursive: true, force: true });
  });

  test("resolves root-relative paths, case-insensitively, with display names", async () => {
    const resolved = await policy.resolve("projeler/AutoLoom/README.md", "read", "existing");
    assert.equal(resolved.display, "Projeler/AutoLoom/README.md");
    assert.ok(resolved.exists);
    assert.ok(isWithin(path.join(base, "Projects"), resolved.abs));
  });

  test("resolves absolute paths inside a root", async () => {
    const resolved = await policy.resolve(path.join(base, "Projects", "AutoLoom"), "read", "existing");
    assert.equal(resolved.display, "Projeler/AutoLoom");
  });

  test("refuses traversal, absolute paths outside roots and unknown roots", async () => {
    await rejects(policy.resolve("Projeler/../outside/secret.txt", "read", "existing"), "invalid_path");
    await rejects(policy.resolve(path.join(outside, "secret.txt"), "read", "existing"), "outside_roots");
    await rejects(policy.resolve(path.join(base, "Projects", "..", "outside", "secret.txt"), "read", "existing"), "outside_roots");
    await rejects(policy.resolve("Gizli/x.txt", "read", "existing"), "unknown_root");
  });

  test("refuses a junction that leads outside the root", async () => {
    await rejects(policy.resolve("Projeler/escape/secret.txt", "read", "existing"), "outside_roots");
    await rejects(policy.resolve("Projeler/escape", "read", "existing"), "outside_roots");
    await rejects(policy.resolve("Projeler/escape/new.txt", "write", "create"), "outside_roots");
  });

  test("refuses Windows special names, streams, UNC and device paths", async () => {
    // The whole input is trimmed (models add stray spaces), but an inner name ending in a space is refused.
    for (const input of ["Projeler/NUL", "Projeler/con.txt", "Projeler/COM1", "Projeler/lpt9.log", "Projeler/a.txt:stream", "Projeler/name.", "Projeler/name /x.txt", "Projeler/a<b"]) {
      await rejects(policy.resolve(input, "read", "create"), "invalid_path");
    }
    for (const input of ["\\\\server\\share\\x", "\\\\?\\C:\\x", "//?/C:/x", "C:relative", "\\Projects", ""]) {
      await rejects(policy.resolve(input, "read", "existing"), "invalid_path");
    }
    assert.throws(() => checkComponent("COM\u00b9"));
    assert.throws(() => checkComponent("CONIN$"));
  });

  test("never opens secret-looking files, even inside a root", async () => {
    await rejects(policy.resolve("Projeler/.env", "read", "existing"), "protected_file");
    await rejects(policy.resolve("Projeler/.ssh/config", "read", "existing"), "protected_file");
    await rejects(policy.resolve("Projeler/new.pem", "write", "create"), "protected_file");
    assert.ok(policy.isSecretName("id_ed25519"));
    assert.ok(policy.isSecretName("Wallet.dat"));
    assert.ok(!policy.isSecretName("README.md"));
  });

  test("write rules: read-only roots, .git folders, programs and shortcuts", async () => {
    await rejects(policy.resolve("Belgeler/new.txt", "write", "create"), "read_only_root");
    await rejects(policy.resolve("Projeler/AutoLoom/.git/hooks/pre-commit", "write", "create"), "write_blocked");
    for (const name of ["tool.exe", "lib.dll", "link.lnk", "page.url", "setup.msi", "keys.reg", "run.vbs", "app.hta", "x.scr"]) {
      await rejects(policy.resolve(`Projeler/${name}`, "write", "create"), "write_blocked");
    }
    const script = await policy.resolve("Projeler/build.ps1", "write", "create");
    assert.ok(policy.isScript(script.abs));
  });

  test("refuses invisible and direction-changing characters that disguise names", async () => {
    for (const input of ["Projeler/evil‮exe.txt", "Projeler/a​b.txt", "Projeler/x﻿.md", "Projeler/⁦y.txt"]) {
      await rejects(policy.resolve(input, "write", "create"), "invalid_path");
    }
  });

  test("never writes through a hard link (it could point anywhere on the drive)", async () => {
    const target = path.join(outside, "linked.txt");
    await fs.writeFile(target, "outside file");
    await fs.link(target, path.join(base, "Projects", "hardlink.txt"));
    const read = await policy.resolve("Projeler/hardlink.txt", "read", "existing");
    assert.ok(read.exists, "reading is allowed");
    await rejects(policy.resolve("Projeler/hardlink.txt", "write", "existing"), "write_blocked");
  });

  test("8.3 short names are expanded before the containment check", async () => {
    const longDir = path.join(base, "Projects", "Very Long Folder Name");
    await fs.mkdir(longDir, { recursive: true });
    const short = shortPath(longDir);
    const resolved = await policy.resolve(short, "read", "existing");
    assert.equal(resolved.display, "Projeler/Very Long Folder Name");
    const outsideShort = shortPath(outside);
    await rejects(policy.resolve(outsideShort, "read", "existing"), "outside_roots");
  });

  test("allows creating nested new paths inside a writable root", async () => {
    const resolved = await policy.resolve("Projeler/AutoLoom/new/deeper/file.txt", "write", "create");
    assert.equal(resolved.exists, false);
    assert.equal(resolved.display, "Projeler/AutoLoom/new/deeper/file.txt");
  });

  test("root validation refuses drives, the profile, system folders and the data folder", async () => {
    assert.match(forbiddenRootReason("C:\\", dataDir, []) ?? "", /sürücü/);
    assert.match(forbiddenRootReason(os.homedir(), dataDir, []) ?? "", /Kullanıcı klasörünün/);
    assert.match(forbiddenRootReason(path.dirname(os.homedir()), dataDir, []) ?? "", /Kullanıcı klasörünün/);
    assert.match(forbiddenRootReason("C:\\Windows\\System32", dataDir, ["C:\\Windows"]) ?? "", /Sistem/);
    assert.match(forbiddenRootReason(dataDir, dataDir, []) ?? "", /veri klasörü/);
    assert.match(forbiddenRootReason(base, dataDir, []) ?? "", /veri klasörü/, "a parent of the data folder is refused too");
    const appData = process.env.LOCALAPPDATA;
    if (appData) assert.ok(forbiddenRootReason(path.join(appData, "Something"), dataDir));
    const bad = await PathPolicy.validateRoot({ name: "../x", path: path.join(base, "Docs"), access: "read" }, dataDir, []);
    assert.equal(typeof bad, "string");
  });
});
