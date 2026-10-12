// TLS identity: an ECDSA P-256 key and a self-signed certificate, made with
// Node's crypto only (no OpenSSL binary). The phone pins the public key, not
// the certificate, so renewing the certificate with the same key keeps the
// pairing valid.
//
// Pin = base64url(SHA-256(uncompressed EC point 04||X||Y)). On iOS this is
// SHA256(SecKeyCopyExternalRepresentation(SecCertificateCopyKey(leaf))).

import { createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign, X509Certificate } from "node:crypto";
import type { KeyObject } from "node:crypto";
import { promises as fs } from "node:fs";
import net from "node:net";
import path from "node:path";
import { base64url, sha256 } from "./util.ts";

// ---- Minimal DER encoder ---------------------------------------------------

function derLength(length: number): Buffer {
  if (length < 0x80) return Buffer.from([length]);
  const bytes: number[] = [];
  for (let n = length; n > 0; n = Math.floor(n / 256)) bytes.unshift(n & 0xff);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}

function tlv(tag: number, content: Buffer): Buffer {
  return Buffer.concat([Buffer.from([tag]), derLength(content.length), content]);
}

const sequence = (...items: Buffer[]): Buffer => tlv(0x30, Buffer.concat(items));
const set = (...items: Buffer[]): Buffer => tlv(0x31, Buffer.concat(items));
const octetString = (content: Buffer): Buffer => tlv(0x04, content);
const utf8String = (text: string): Buffer => tlv(0x0c, Buffer.from(text, "utf8"));
const derBoolean = (value: boolean): Buffer => tlv(0x01, Buffer.from([value ? 0xff : 0x00]));
const explicit = (tagNumber: number, content: Buffer): Buffer => tlv(0xa0 | tagNumber, content);
const bitStringOf = (content: Buffer): Buffer => tlv(0x03, Buffer.concat([Buffer.from([0]), content]));

function unsignedInteger(value: Buffer): Buffer {
  let v = value;
  while (v.length > 1 && v[0] === 0 && (v[1] & 0x80) === 0) v = v.subarray(1);
  if (v[0] & 0x80) v = Buffer.concat([Buffer.from([0]), v]);
  return tlv(0x02, v);
}

function oid(dotted: string): Buffer {
  const parts = dotted.split(".").map((part) => Number(part));
  const bytes = [40 * parts[0] + parts[1]];
  for (const part of parts.slice(2)) {
    const group = [part & 0x7f];
    for (let n = Math.floor(part / 128); n > 0; n = Math.floor(n / 128)) group.unshift((n & 0x7f) | 0x80);
    bytes.push(...group);
  }
  return tlv(0x06, Buffer.from(bytes));
}

function utcTime(date: Date): Buffer {
  const pad = (n: number): string => String(n).padStart(2, "0");
  const text =
    pad(date.getUTCFullYear() % 100) + pad(date.getUTCMonth() + 1) + pad(date.getUTCDate()) +
    pad(date.getUTCHours()) + pad(date.getUTCMinutes()) + pad(date.getUTCSeconds()) + "Z";
  return tlv(0x17, Buffer.from(text, "ascii"));
}

function ipBytes(ip: string): Buffer | undefined {
  if (net.isIPv4(ip)) return Buffer.from(ip.split(".").map((part) => Number(part)));
  if (net.isIPv6(ip)) {
    // Expand "::" and convert to 16 bytes.
    const [head, tailPart] = ip.split("::");
    const headGroups = head ? head.split(":") : [];
    const tailGroups = tailPart !== undefined && tailPart !== "" ? tailPart.split(":") : [];
    if (headGroups.some((g) => g.includes(".")) || tailGroups.some((g) => g.includes("."))) return undefined;
    const missing = 8 - headGroups.length - tailGroups.length;
    const groups = ip.includes("::") ? [...headGroups, ...Array(missing).fill("0"), ...tailGroups] : headGroups;
    if (groups.length !== 8) return undefined;
    const buffer = Buffer.alloc(16);
    groups.forEach((group, index) => buffer.writeUInt16BE(parseInt(group || "0", 16), index * 2));
    return buffer;
  }
  return undefined;
}

// ---- Certificate -----------------------------------------------------------

const ECDSA_WITH_SHA256 = "1.2.840.10045.4.3.2";
const P256_SPKI_PREFIX = Buffer.from("3059301306072a8648ce3d020106082a8648ce3d030107034200", "hex");

export interface CertificateOptions {
  commonName: string;
  dnsNames: string[];
  ipAddresses: string[];
  validDays: number;
  now?: Date;
}

export function createSelfSignedCertificate(privateKey: KeyObject, publicKey: KeyObject, options: CertificateOptions): string {
  const now = options.now ?? new Date();
  const notBefore = new Date(now.getTime() - 5 * 60 * 1000); // tolerate a slightly slow phone clock
  const notAfter = new Date(now.getTime() + options.validDays * 24 * 60 * 60 * 1000);
  const serial = randomBytes(16);
  serial[0] &= 0x7f;

  const name = sequence(set(sequence(oid("2.5.4.3"), utf8String(options.commonName))));
  const algorithm = sequence(oid(ECDSA_WITH_SHA256));
  const spki = publicKey.export({ type: "spki", format: "der" }) as Buffer;

  const altNames: Buffer[] = [];
  for (const dns of options.dnsNames) altNames.push(tlv(0x82, Buffer.from(dns, "ascii")));
  for (const ip of options.ipAddresses) {
    const bytes = ipBytes(ip);
    if (bytes) altNames.push(tlv(0x87, bytes));
  }

  const extensions = [
    // basicConstraints: critical, CA:FALSE
    sequence(oid("2.5.29.19"), derBoolean(true), octetString(sequence())),
    // keyUsage: critical, digitalSignature (bit 0 set, 7 unused bits)
    sequence(oid("2.5.29.15"), derBoolean(true), octetString(tlv(0x03, Buffer.from([0x07, 0x80])))),
    // extKeyUsage: serverAuth
    sequence(oid("2.5.29.37"), octetString(sequence(oid("1.3.6.1.5.5.7.3.1")))),
  ];
  if (altNames.length > 0) extensions.push(sequence(oid("2.5.29.17"), octetString(sequence(...altNames))));

  const tbs = sequence(
    explicit(0, unsignedInteger(Buffer.from([2]))), // v3
    unsignedInteger(serial),
    algorithm,
    name,
    sequence(utcTime(notBefore), utcTime(notAfter)),
    name,
    spki,
    explicit(3, sequence(...extensions)),
  );
  const signature = sign("sha256", tbs, privateKey); // DER-encoded ECDSA-Sig-Value
  const certificate = sequence(tbs, algorithm, bitStringOf(signature));
  return toPem(certificate, "CERTIFICATE");
}

function toPem(der: Buffer, label: string): string {
  const body = der.toString("base64").replace(/(.{64})/g, "$1\n").replace(/\n$/, "");
  return `-----BEGIN ${label}-----\n${body}\n-----END ${label}-----\n`;
}

/** The pin the phone checks: SHA-256 of the uncompressed P-256 public point. */
export function publicKeyPin(publicKey: KeyObject): string {
  const spki = publicKey.export({ type: "spki", format: "der" }) as Buffer;
  if (spki.length !== 91 || !spki.subarray(0, 26).equals(P256_SPKI_PREFIX)) {
    throw new Error("Only ECDSA P-256 keys are supported.");
  }
  return base64url(sha256(spki.subarray(26)));
}

export function pinOfCertificate(certPem: string): string {
  return publicKeyPin(new X509Certificate(certPem).publicKey);
}

// ---- Identity on disk ------------------------------------------------------

export interface Identity {
  keyPem: string;
  certPem: string;
  pin: string;
  notAfter: Date;
}

export interface IdentityOptions {
  dir: string;
  commonName: string;
  dnsNames: string[];
  ipAddresses: string[];
  renewWithinDays?: number;
  validDays?: number;
}

/** Loads the key and certificate, creating them on first run and renewing the certificate (same key) when it nears expiry or misses an address. */
export async function loadOrCreateIdentity(options: IdentityOptions): Promise<Identity> {
  const keyFile = path.join(options.dir, "key.pem");
  const certFile = path.join(options.dir, "cert.pem");
  await fs.mkdir(options.dir, { recursive: true });

  let privateKey: KeyObject;
  let keyPem: string;
  try {
    keyPem = await fs.readFile(keyFile, "utf8");
    privateKey = createPrivateKey(keyPem);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    const pair = generateKeyPairSync("ec", { namedCurve: "P-256" });
    privateKey = pair.privateKey;
    keyPem = privateKey.export({ type: "pkcs8", format: "pem" }) as string;
    await fs.writeFile(keyFile, keyPem, { encoding: "utf8", mode: 0o600, flag: "wx" });
  }
  const publicKey = createPublicKey(privateKey);
  const pin = publicKeyPin(publicKey);

  const renewWithin = (options.renewWithinDays ?? 30) * 24 * 60 * 60 * 1000;
  let certPem: string | undefined;
  try {
    certPem = await fs.readFile(certFile, "utf8");
    const cert = new X509Certificate(certPem);
    const expiresSoon = new Date(cert.validTo).getTime() - Date.now() < renewWithin;
    const wrongKey = pinOfCertificate(certPem) !== pin;
    const missingAddress = options.ipAddresses.some((ip) => !cert.checkIP(ip));
    if (expiresSoon || wrongKey || missingAddress) certPem = undefined;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") certPem = undefined;
    else certPem = undefined;
  }
  if (!certPem) {
    certPem = createSelfSignedCertificate(privateKey, publicKey, {
      commonName: options.commonName,
      dnsNames: options.dnsNames,
      ipAddresses: options.ipAddresses,
      validDays: options.validDays ?? 397,
    });
    await fs.writeFile(certFile, certPem, { encoding: "utf8", mode: 0o600 });
  }
  const notAfter = new Date(new X509Certificate(certPem).validTo);
  return { keyPem, certPem, pin, notAfter };
}
