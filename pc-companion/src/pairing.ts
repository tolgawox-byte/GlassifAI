// Pairing: the PC shows a QR code with its address, its key pin and a
// one-time code. The phone connects over TLS, checks the pin, and sends the
// code. The code works once, for a few minutes, and five wrong codes close
// the window. Optionally the person at the PC must also say yes.

import type { AuditLog } from "./audit.ts";
import type { DeviceStore, PublicDevice } from "./devices.ts";
import { CompanionError, randomCode, safeEqual } from "./util.ts";

export const PAIRING_SCHEME = "jarvis-pc";
const MAX_FAILURES = 5;

export interface PairingInfo {
  host: string;
  port: number;
  pin: string;
  serverName: string;
}

export interface PairingWindow {
  code: string;
  expiresAt: number;
  uri: string;
}

/** "ABCDE-FGHJK" → "ABCDEFGHJK"; lenient about spaces, dashes and case for typed codes. */
export function normalizeCode(code: string): string {
  return code.replace(/[\s-]/g, "").toUpperCase();
}

export function formatCode(code: string): string {
  return `${code.slice(0, 5)}-${code.slice(5)}`;
}

export function buildPairingUri(info: PairingInfo, code: string): string {
  const params = new URLSearchParams({
    v: "1",
    h: info.host,
    p: String(info.port),
    k: info.pin,
    c: code,
    n: info.serverName,
  });
  return `${PAIRING_SCHEME}://pair?${params.toString()}`;
}

export type ConfirmPairing = (deviceName: string, address: string) => Promise<boolean>;

export class PairingManager {
  private window: (PairingWindow & { failures: number }) | undefined;
  private readonly devices: DeviceStore;
  private readonly audit: AuditLog;
  private confirm: ConfirmPairing | undefined;
  private busy = false;

  constructor(devices: DeviceStore, audit: AuditLog, confirm?: ConfirmPairing) {
    this.devices = devices;
    this.audit = audit;
    this.confirm = confirm;
  }

  setConfirm(confirm: ConfirmPairing | undefined): void {
    this.confirm = confirm;
  }

  open(info: PairingInfo, ttlSec: number): PairingWindow {
    const code = randomCode(10);
    const window = { code, expiresAt: Date.now() + ttlSec * 1000, uri: buildPairingUri(info, code), failures: 0 };
    this.window = window;
    void this.audit.record("pairing.opened", { ttlSec, host: info.host, port: info.port });
    return { code: window.code, expiresAt: window.expiresAt, uri: window.uri };
  }

  close(reason: string): void {
    if (this.window) void this.audit.record("pairing.closed", { reason });
    this.window = undefined;
  }

  isOpen(): boolean {
    if (this.window && Date.now() > this.window.expiresAt) this.close("expired");
    return this.window !== undefined;
  }

  async pair(code: unknown, deviceName: unknown, address: string): Promise<{ device: PublicDevice; token: string }> {
    if (!this.isOpen() || !this.window) {
      void this.audit.record("pairing.refused", { reason: "closed", address });
      throw new CompanionError("pairing_closed", "Eşleştirme açık değil. Bilgisayarda 'pair' komutunu çalıştır.", { status: 403 });
    }
    if (this.busy) throw new CompanionError("pairing_busy", "Başka bir eşleştirme sürüyor.", { status: 409 });
    if (typeof code !== "string" || typeof deviceName !== "string" || deviceName.trim().length === 0 || deviceName.length > 60) {
      throw new CompanionError("invalid_request", "Kod ve cihaz adı gerekli.", { status: 400 });
    }
    const window = this.window;
    if (!safeEqual(normalizeCode(code), window.code)) {
      window.failures += 1;
      void this.audit.record("pairing.failed", { address, failures: window.failures });
      if (window.failures >= MAX_FAILURES) this.close("too_many_failures");
      throw new CompanionError("pairing_code_invalid", "Eşleştirme kodu yanlış.", { status: 403 });
    }
    this.busy = true;
    try {
      if (this.confirm) {
        const accepted = await this.confirm(deviceName.trim(), address);
        if (!accepted) {
          void this.audit.record("pairing.rejected_at_pc", { address, deviceName });
          this.close("rejected");
          throw new CompanionError("pairing_rejected", "Eşleştirme bilgisayarda reddedildi.", { status: 403 });
        }
      }
      // The code is spent even if the phone never reads the answer.
      this.close("used");
      const result = await this.devices.add(deviceName);
      void this.audit.record("pairing.succeeded", { deviceId: result.device.id, deviceName: result.device.name, address });
      return result;
    } finally {
      this.busy = false;
    }
  }
}
