// Paired phones. Each gets a random 256-bit token; only its SHA-256 is stored,
// so a copy of devices.json cannot be used to impersonate the phone.
// Authentication (who is this?) lives here; authorization (may they do this?)
// lives in the task manager's policy check.

import { randomBytes } from "node:crypto";
import { base64url, nowIso, randomId, readJsonFile, safeEqual, sha256Hex, writeJsonFileAtomic } from "./util.ts";

export type Scope = "files:read" | "files:write" | "apps:launch" | "commands:run" | "tasks:approve";
export const ALL_SCOPES: readonly Scope[] = ["files:read", "files:write", "apps:launch", "commands:run", "tasks:approve"];

export interface DeviceRecord {
  id: string;
  name: string;
  tokenHash: string;
  scopes: Scope[];
  createdAt: string;
  lastSeenAt: string | null;
  lastAddress: string | null;
  revokedAt: string | null;
}

export type PublicDevice = Omit<DeviceRecord, "tokenHash">;

interface DeviceFile {
  version: 1;
  devices: DeviceRecord[];
}

const TOUCH_INTERVAL_MS = 60_000;

export class DeviceStore {
  private readonly file: string;
  private devices: DeviceRecord[] = [];
  private lastPersistedTouch = new Map<string, number>();

  private constructor(file: string) {
    this.file = file;
  }

  static async open(file: string): Promise<DeviceStore> {
    const store = new DeviceStore(file);
    const saved = await readJsonFile<DeviceFile>(file);
    store.devices = Array.isArray(saved?.devices) ? saved.devices : [];
    return store;
  }

  list(): PublicDevice[] {
    return this.devices.map(({ tokenHash: _hash, ...device }) => device);
  }

  active(): PublicDevice[] {
    return this.list().filter((device) => device.revokedAt === null);
  }

  /** Creates a device and returns its token once; the token is never stored. */
  async add(name: string, scopes: readonly Scope[] = ALL_SCOPES): Promise<{ device: PublicDevice; token: string }> {
    const token = `jpc_${base64url(randomBytes(32))}`;
    const record: DeviceRecord = {
      id: randomId("d", 10),
      name: name.trim().slice(0, 60) || "iPhone",
      tokenHash: sha256Hex(token),
      scopes: [...scopes],
      createdAt: nowIso(),
      lastSeenAt: null,
      lastAddress: null,
      revokedAt: null,
    };
    this.devices.push(record);
    await this.persist();
    const { tokenHash: _hash, ...device } = record;
    return { device, token };
  }

  /** Finds the active device for a bearer token, comparing hashes in constant time. */
  authenticate(token: string | undefined): PublicDevice | undefined {
    if (!token || !/^jpc_[A-Za-z0-9_-]{43}$/.test(token)) return undefined;
    const hash = sha256Hex(token);
    let found: DeviceRecord | undefined;
    for (const device of this.devices) {
      // Compare against every device so timing does not reveal how many exist.
      if (safeEqual(device.tokenHash, hash) && device.revokedAt === null) found = device;
    }
    if (!found) return undefined;
    const { tokenHash: _hash, ...device } = found;
    return device;
  }

  async touch(id: string, address: string): Promise<void> {
    const device = this.devices.find((d) => d.id === id);
    if (!device) return;
    device.lastSeenAt = nowIso();
    device.lastAddress = address;
    const last = this.lastPersistedTouch.get(id) ?? 0;
    if (Date.now() - last > TOUCH_INTERVAL_MS) {
      this.lastPersistedTouch.set(id, Date.now());
      await this.persist();
    }
  }

  async revoke(id: string): Promise<boolean> {
    const device = this.devices.find((d) => d.id === id && d.revokedAt === null);
    if (!device) return false;
    device.revokedAt = nowIso();
    await this.persist();
    return true;
  }

  private async persist(): Promise<void> {
    const data: DeviceFile = { version: 1, devices: this.devices };
    await writeJsonFileAtomic(this.file, data);
  }
}
