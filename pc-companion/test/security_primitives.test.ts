import assert from "node:assert/strict";
import { X509Certificate, createPublicKey, generateKeyPairSync } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { after, describe, test } from "node:test";
import { AuditLog, sanitizeAuditFields, verifyAuditLog } from "../src/audit.ts";
import { createSelfSignedCertificate, loadOrCreateIdentity, pinOfCertificate, publicKeyPin } from "../src/cert.ts";
import { checkConfig, defaultConfig } from "../src/config.ts";
import { DeviceStore } from "../src/devices.ts";
import { chooseBindAddress, isPrivateAddress, normalizeAddress } from "../src/network.ts";
import { PairingManager, buildPairingUri, normalizeCode } from "../src/pairing.ts";
import { RateLimiter } from "../src/ratelimit.ts";
import { validate } from "../src/schema.ts";
import { CompanionError } from "../src/util.ts";
import { tempDir } from "./helpers.ts";

const cleanup: string[] = [];
after(async () => {
  for (const dir of cleanup) await fs.rm(dir, { recursive: true, force: true });
});

describe("certificate and pin", () => {
  test("self-signed P-256 certificate parses, verifies and carries the SANs", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const pem = createSelfSignedCertificate(privateKey, publicKey, {
      commonName: "JARVIS PC Test",
      dnsNames: ["localhost"],
      ipAddresses: ["127.0.0.1", "192.168.1.20", "fd7a:115c:a1e0::1"],
      validDays: 30,
    });
    const cert = new X509Certificate(pem);
    assert.ok(cert.verify(publicKey), "self-signature verifies");
    assert.equal(cert.checkIP("192.168.1.20"), "192.168.1.20");
    assert.equal(cert.checkIP("127.0.0.1"), "127.0.0.1");
    assert.equal(cert.checkHost("localhost"), "localhost");
    assert.equal(cert.ca, false);
    assert.match(cert.subject, /JARVIS PC Test/);
    assert.ok(new Date(cert.validTo).getTime() > Date.now());
    assert.equal(pinOfCertificate(pem), publicKeyPin(publicKey));
    assert.match(publicKeyPin(publicKey), /^[A-Za-z0-9_-]{43}$/);
  });

  test("identity is created once; renewal keeps the key and therefore the pin", async () => {
    const dir = await tempDir("jpc-id-");
    cleanup.push(dir);
    const first = await loadOrCreateIdentity({ dir, commonName: "T", dnsNames: ["localhost"], ipAddresses: ["127.0.0.1"] });
    const again = await loadOrCreateIdentity({ dir, commonName: "T", dnsNames: ["localhost"], ipAddresses: ["127.0.0.1"] });
    assert.equal(again.certPem, first.certPem, "valid certificate reused");
    // A new LAN address forces a new certificate, with the same key.
    const renewed = await loadOrCreateIdentity({ dir, commonName: "T", dnsNames: ["localhost"], ipAddresses: ["127.0.0.1", "10.0.0.7"] });
    assert.notEqual(renewed.certPem, first.certPem);
    assert.equal(renewed.pin, first.pin);
    assert.equal(publicKeyPin(createPublicKey(first.keyPem)), first.pin);
  });
});

describe("audit log", () => {
  test("hash chain verifies, and editing a line is detected", async () => {
    const dir = await tempDir("jpc-audit-");
    cleanup.push(dir);
    const file = path.join(dir, "audit.log");
    const log = await AuditLog.open(file);
    await log.record("server.started", { port: 1 });
    await log.record("task.created", { taskId: "t_1", token: "jpc_secret", content: "hello", contentLength: 5 });
    await log.record("task.completed", { taskId: "t_1" });
    assert.deepEqual(await verifyAuditLog(file), { ok: true, entries: 3 });
    const raw = await fs.readFile(file, "utf8");
    assert.ok(!raw.includes("jpc_secret"), "tokens are never written");
    assert.ok(!raw.includes("hello"), "contents are never written");
    assert.ok(raw.includes('"contentLength":5'), "harmless numbers are kept");

    // Reopening continues the same chain.
    const reopened = await AuditLog.open(file);
    await reopened.record("server.stopped", {});
    assert.equal((await verifyAuditLog(file)).entries, 4);

    const lines = (await fs.readFile(file, "utf8")).trim().split("\n");
    lines[1] = lines[1].replace("t_1", "t_2");
    await fs.writeFile(file, lines.join("\n") + "\n");
    const broken = await verifyAuditLog(file);
    assert.equal(broken.ok, false);
    assert.equal(broken.brokenAtLine, 2);
  });

  test("sanitizer redacts secret-looking keys and cuts long strings", () => {
    const out = sanitizeAuditFields({ password: "x", authorization: "Bearer y", note: "a".repeat(1000), errorCode: "timeout" });
    assert.equal(out.password, "[redacted]");
    assert.equal(out.authorization, "[redacted]");
    assert.equal(out.errorCode, "timeout");
    assert.ok((out.note as string).length <= 300);
  });
});

describe("devices and pairing", () => {
  test("tokens are stored hashed, authenticate in constant time and can be revoked", async () => {
    const dir = await tempDir("jpc-dev-");
    cleanup.push(dir);
    const store = await DeviceStore.open(path.join(dir, "devices.json"));
    const { device, token } = await store.add("Tolga'nın iPhone'u");
    assert.match(token, /^jpc_[A-Za-z0-9_-]{43}$/);
    const raw = await fs.readFile(path.join(dir, "devices.json"), "utf8");
    assert.ok(!raw.includes(token), "the token itself is never stored");
    assert.equal(store.authenticate(token)?.id, device.id);
    assert.equal(store.authenticate(token.slice(0, -1) + (token.endsWith("A") ? "B" : "A")), undefined);
    assert.equal(store.authenticate(undefined), undefined);
    assert.equal(store.authenticate("not-a-token"), undefined);
    assert.ok(await store.revoke(device.id));
    assert.equal(store.authenticate(token), undefined);
    const reopened = await DeviceStore.open(path.join(dir, "devices.json"));
    assert.equal(reopened.authenticate(token), undefined, "revocation persists");
  });

  test("pairing code: single use, expiry, five wrong codes close the window, optional PC confirmation", async () => {
    const dir = await tempDir("jpc-pair-");
    cleanup.push(dir);
    const store = await DeviceStore.open(path.join(dir, "devices.json"));
    const audit = await AuditLog.open(path.join(dir, "audit.log"));
    const pairing = new PairingManager(store, audit);
    const info = { host: "192.168.1.20", port: 47600, pin: "p".repeat(43), serverName: "PC" };

    await assert.rejects(pairing.pair("X", "iPhone", "192.168.1.5"), (e: CompanionError) => e.code === "pairing_closed");

    let window = pairing.open(info, 300);
    assert.match(window.uri, /^jarvis-pc:\/\/pair\?v=1&h=192\.168\.1\.20&p=47600&k=p+&c=[A-Z0-9]{10}&n=PC$/);
    const typed = `${window.code.slice(0, 5).toLowerCase()}-${window.code.slice(5)}`;
    const ok = await pairing.pair(typed, "iPhone", "192.168.1.5");
    assert.ok(ok.token);
    await assert.rejects(pairing.pair(window.code, "iPhone", "192.168.1.5"), (e: CompanionError) => e.code === "pairing_closed", "single use");

    window = pairing.open(info, 300);
    for (let i = 0; i < 5; i++) {
      await assert.rejects(pairing.pair("AAAAAAAAAA", "x", "192.168.1.9"), (e: CompanionError) => e.code === "pairing_code_invalid");
    }
    await assert.rejects(pairing.pair(window.code, "x", "192.168.1.9"), (e: CompanionError) => e.code === "pairing_closed", "locked after 5 failures");

    window = pairing.open(info, 0);
    await new Promise((r) => setTimeout(r, 5));
    await assert.rejects(pairing.pair(window.code, "x", "192.168.1.9"), (e: CompanionError) => e.code === "pairing_closed", "expired");

    pairing.setConfirm(async () => false);
    window = pairing.open(info, 300);
    await assert.rejects(pairing.pair(window.code, "x", "192.168.1.9"), (e: CompanionError) => e.code === "pairing_rejected");
    assert.equal(store.active().length, 1);
    await audit.flush();
  });

  test("pairing URI and code helpers", () => {
    assert.equal(normalizeCode(" abcde-fghjk "), "ABCDEFGHJK");
    const uri = buildPairingUri({ host: "10.0.0.2", port: 50000, pin: "abc_-", serverName: "Ev PC'si" }, "ABCDEFGHJK");
    const parsed = new URL(uri);
    assert.equal(parsed.protocol, "jarvis-pc:");
    assert.equal(parsed.searchParams.get("n"), "Ev PC'si");
    assert.equal(parsed.searchParams.get("k"), "abc_-");
  });
});

describe("network rules", () => {
  test("private and loopback addresses only", () => {
    for (const ip of ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.0.10", "169.254.3.4", "100.64.0.1", "100.127.255.254", "::1", "fd7a:115c:a1e0::1", "fe80::1", "::ffff:192.168.1.4"]) {
      assert.ok(isPrivateAddress(ip), ip);
    }
    for (const ip of ["8.8.8.8", "172.32.0.1", "100.128.0.1", "1.1.1.1", "2001:4860:4860::8888", "::ffff:8.8.8.8", "", "fc"]) {
      assert.ok(!isPrivateAddress(ip), ip);
    }
    assert.equal(normalizeAddress("::ffff:10.0.0.1"), "10.0.0.1");
  });

  test("never binds to a public address; loopback unless LAN mode", () => {
    assert.equal(chooseBindAddress({ lan: false, bindAddress: "8.8.8.8" }), "127.0.0.1");
    assert.throws(() => chooseBindAddress({ lan: true, bindAddress: "8.8.8.8" }));
    assert.equal(chooseBindAddress({ lan: true, bindAddress: "192.168.1.20" }), "192.168.1.20");
  });

  test("failed-login limiter blocks after the limit for the block period", () => {
    const limiter = new RateLimiter(3, 1000, 5000);
    assert.ok(limiter.hit("a", 0));
    assert.ok(limiter.hit("a", 1));
    assert.ok(limiter.hit("a", 2));
    assert.ok(!limiter.hit("a", 3));
    assert.ok(limiter.isBlocked("a", 4000));
    assert.ok(!limiter.isBlocked("a", 6000));
    assert.ok(limiter.hit("b", 3), "other keys are independent");
  });
});

describe("config and schema", () => {
  test("default config shares nothing and listens locally", () => {
    const config = defaultConfig();
    assert.deepEqual(config.roots, []);
    assert.deepEqual(config.commands, []);
    assert.equal(config.network.lan, false);
    assert.deepEqual(checkConfig(config), []);
  });

  test("config check refuses script apps, relative exes and shell metacharacters", () => {
    const config = defaultConfig();
    config.apps = [{ id: "evil", label: "x", exe: "C:\\x\\run.cmd", args: [], pathArg: "none" }];
    config.commands = [
      { id: "test", label: "npm test", exe: "npm.cmd", args: ["test"], shell: true, timeoutSec: 60, needsWriteAccess: true },
      { id: "inject", label: "x", exe: "C:\\x\\npm.cmd", args: ["test & calc"], shell: true, timeoutSec: 60, needsWriteAccess: true },
    ];
    const problems = checkConfig(config).join("\n");
    assert.match(problems, /evil: uygulama bir betik olamaz/);
    assert.match(problems, /test: exe tam bir yol olmalı/);
    assert.match(problems, /inject: shell ile çalışan komutun argümanlarında/);
  });

  test("schema validation rejects wrong types, unknown fields and long values", () => {
    const schema = {
      type: "object" as const,
      additionalProperties: false,
      required: ["path"],
      properties: { path: { type: "string" as const, maxLength: 5 }, n: { type: "integer" as const, minimum: 1 } },
    };
    assert.deepEqual(validate(schema, { path: "abc" }), []);
    assert.equal(validate(schema, {}).length, 1);
    assert.equal(validate(schema, { path: "abcdef" }).length, 1);
    assert.equal(validate(schema, { path: "a", extra: 1 }).length, 1);
    assert.equal(validate(schema, { path: "a", n: 1.5 }).length, 1);
    assert.equal(validate(schema, { path: 3 }).length, 1);
  });
});
