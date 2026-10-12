// Minimal ZIP reader for Office documents (.docx, .xlsx, .pptx, .odt).
// Stored and deflated entries only; ZIP64 and encrypted entries are refused.
// Every entry is inflated with a hard output limit, so a zip bomb cannot
// exhaust memory.

import { inflateRawSync } from "node:zlib";
import { CompanionError } from "../util.ts";

export interface ZipEntry {
  name: string;
  method: number;
  encrypted: boolean;
  compressedSize: number;
  size: number;
  localHeaderOffset: number;
}

const EOCD = 0x06054b50;
const CENTRAL = 0x02014b50;
const LOCAL = 0x04034b50;
const MAX_ENTRIES = 5000;

export function readZipDirectory(buffer: Buffer): ZipEntry[] {
  const minimum = Math.max(0, buffer.length - 22 - 0xffff);
  let eocd = -1;
  for (let i = buffer.length - 22; i >= minimum; i--) {
    if (buffer.readUInt32LE(i) === EOCD) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new CompanionError("bad_document", "Dosya geçerli bir ZIP/Office belgesi değil.");
  const count = buffer.readUInt16LE(eocd + 10);
  const size = buffer.readUInt32LE(eocd + 12);
  const offset = buffer.readUInt32LE(eocd + 16);
  if (count === 0xffff || size === 0xffffffff || offset === 0xffffffff) {
    throw new CompanionError("unsupported_document", "ZIP64 belgeleri desteklenmiyor.");
  }
  if (count > MAX_ENTRIES) throw new CompanionError("bad_document", "Belgede çok fazla parça var.");
  if (offset + size > buffer.length) throw new CompanionError("bad_document", "Belge bozuk (dizin dosyanın dışında).");

  const entries: ZipEntry[] = [];
  let pointer = offset;
  for (let i = 0; i < count; i++) {
    if (pointer + 46 > buffer.length || buffer.readUInt32LE(pointer) !== CENTRAL) {
      throw new CompanionError("bad_document", "Belge bozuk (dizin kaydı).");
    }
    const flags = buffer.readUInt16LE(pointer + 8);
    const method = buffer.readUInt16LE(pointer + 10);
    const compressedSize = buffer.readUInt32LE(pointer + 20);
    const uncompressedSize = buffer.readUInt32LE(pointer + 24);
    const nameLength = buffer.readUInt16LE(pointer + 28);
    const extraLength = buffer.readUInt16LE(pointer + 30);
    const commentLength = buffer.readUInt16LE(pointer + 32);
    const localHeaderOffset = buffer.readUInt32LE(pointer + 42);
    const name = buffer.toString((flags & 0x800) !== 0 ? "utf8" : "latin1", pointer + 46, pointer + 46 + nameLength);
    entries.push({ name, method, encrypted: (flags & 1) !== 0, compressedSize, size: uncompressedSize, localHeaderOffset });
    pointer += 46 + nameLength + extraLength + commentLength;
  }
  return entries;
}

export function extractEntry(buffer: Buffer, entry: ZipEntry, maxBytes: number): Buffer {
  if (entry.encrypted) throw new CompanionError("encrypted_document", "Belge parolayla korunuyor.");
  const at = entry.localHeaderOffset;
  if (at + 30 > buffer.length || buffer.readUInt32LE(at) !== LOCAL) throw new CompanionError("bad_document", "Belge bozuk (yerel başlık).");
  const nameLength = buffer.readUInt16LE(at + 26);
  const extraLength = buffer.readUInt16LE(at + 28);
  const start = at + 30 + nameLength + extraLength;
  const end = start + entry.compressedSize;
  if (end > buffer.length) throw new CompanionError("bad_document", "Belge bozuk (veri dosyanın dışında).");
  const data = buffer.subarray(start, end);
  if (entry.method === 0) {
    if (data.length > maxBytes) throw new CompanionError("too_large", "Belgenin bir parçası çok büyük.");
    return data;
  }
  if (entry.method === 8) {
    try {
      return inflateRawSync(data, { maxOutputLength: maxBytes });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ERR_BUFFER_TOO_LARGE" || error instanceof RangeError) {
        throw new CompanionError("too_large", "Belgenin bir parçası açıldığında çok büyük (ZIP bombası olabilir).");
      }
      throw new CompanionError("bad_document", "Belge parçası açılamadı.");
    }
  }
  throw new CompanionError("unsupported_document", `Desteklenmeyen sıkıştırma yöntemi (${entry.method}).`);
}

export class ZipReader {
  readonly entries: ZipEntry[];
  private readonly buffer: Buffer;
  private readonly maxEntryBytes: number;
  private totalOut = 0;
  private readonly maxTotalBytes: number;

  constructor(buffer: Buffer, limits: { maxEntryBytes: number; maxTotalBytes: number }) {
    this.buffer = buffer;
    this.entries = readZipDirectory(buffer);
    this.maxEntryBytes = limits.maxEntryBytes;
    this.maxTotalBytes = limits.maxTotalBytes;
  }

  has(name: string): boolean {
    return this.entries.some((entry) => entry.name === name);
  }

  names(): string[] {
    return this.entries.map((entry) => entry.name);
  }

  text(name: string): string | undefined {
    const entry = this.entries.find((e) => e.name === name);
    if (!entry) return undefined;
    const data = extractEntry(this.buffer, entry, this.maxEntryBytes);
    this.totalOut += data.length;
    if (this.totalOut > this.maxTotalBytes) throw new CompanionError("too_large", "Belge açıldığında çok büyük.");
    return data.toString("utf8");
  }
}
