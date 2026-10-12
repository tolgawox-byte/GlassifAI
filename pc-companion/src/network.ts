// Which addresses the companion listens on and accepts connections from.
// It never listens on a public address, and refuses peers outside private ranges.

import net from "node:net";
import os from "node:os";

function ipv4ToNumber(ip: string): number {
  return ip.split(".").reduce((acc, part) => acc * 256 + Number(part), 0);
}

function inRange(ip: string, base: string, bits: number): boolean {
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return ((ipv4ToNumber(ip) & mask) >>> 0) === ((ipv4ToNumber(base) & mask) >>> 0);
}

/** Strips the IPv4-mapped IPv6 prefix ("::ffff:192.168.1.5"). */
export function normalizeAddress(address: string | undefined): string {
  if (!address) return "";
  return address.startsWith("::ffff:") && net.isIPv4(address.slice(7)) ? address.slice(7) : address;
}

export function isLoopback(address: string): boolean {
  const ip = normalizeAddress(address);
  return ip === "::1" || (net.isIPv4(ip) && inRange(ip, "127.0.0.0", 8));
}

/** Loopback, RFC 1918, link-local and carrier-grade NAT (Tailscale's 100.64.0.0/10); IPv6 ULA and link-local. */
export function isPrivateAddress(address: string): boolean {
  const ip = normalizeAddress(address);
  if (net.isIPv4(ip)) {
    return (
      inRange(ip, "127.0.0.0", 8) ||
      inRange(ip, "10.0.0.0", 8) ||
      inRange(ip, "172.16.0.0", 12) ||
      inRange(ip, "192.168.0.0", 16) ||
      inRange(ip, "169.254.0.0", 16) ||
      inRange(ip, "100.64.0.0", 10)
    );
  }
  if (net.isIPv6(ip)) {
    const lowered = ip.toLowerCase();
    return lowered === "::1" || /^f[cd][0-9a-f]{2}:/.test(lowered) || /^fe[89ab][0-9a-f]:/.test(lowered);
  }
  return false;
}

export interface LocalAddress {
  name: string;
  address: string;
}

/** Private IPv4 addresses of this PC's network adapters (Wi-Fi, Ethernet, Tailscale …). */
export function privateIPv4Addresses(): LocalAddress[] {
  const result: LocalAddress[] = [];
  const interfaces = os.networkInterfaces();
  for (const [name, entries] of Object.entries(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.family !== "IPv4" || entry.internal) continue;
      if (!isPrivateAddress(entry.address) || entry.address.startsWith("169.254.")) continue;
      result.push({ name, address: entry.address });
    }
  }
  // Prefer home-network ranges over virtual adapters such as Hyper-V or WSL (172.16/12).
  const rank = (ip: string): number => (ip.startsWith("192.168.") ? 0 : ip.startsWith("10.") ? 1 : ip.startsWith("100.") ? 2 : 3);
  return result.sort((a, b) => rank(a.address) - rank(b.address));
}

/** The address to listen on: loopback unless LAN mode is on, and never a public address. */
export function chooseBindAddress(options: { lan: boolean; bindAddress: string | null }): string {
  if (!options.lan) return "127.0.0.1";
  if (options.bindAddress) {
    if (!isPrivateAddress(options.bindAddress)) {
      throw new Error(`${options.bindAddress} özel (yerel ağ) bir adres değil; companion yalnızca yerel ağda dinler.`);
    }
    return options.bindAddress;
  }
  const first = privateIPv4Addresses()[0];
  if (!first) throw new Error("Yerel ağ adresi bulunamadı. Wi-Fi veya Ethernet bağlı mı?");
  return first.address;
}
