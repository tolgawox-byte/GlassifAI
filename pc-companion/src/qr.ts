// Pairing QR code: drawn in the terminal (dark modules on a white background,
// two rows per text line) and saved as an SVG that can be opened full-size.

import { Ecc, QrCode } from "./vendor/qrcodegen.ts";

export function encodeQr(text: string): QrCode {
  return QrCode.encodeText(text, Ecc.MEDIUM);
}

/** Terminal rendering with ANSI colours so the code is dark-on-light even in a dark terminal. */
export function renderQrForTerminal(qr: QrCode, quiet = 2): string {
  const size = qr.size;
  const dark = (x: number, y: number): boolean => x >= 0 && y >= 0 && x < size && y < size && qr.getModule(x, y);
  const lines: string[] = [];
  for (let y = -quiet; y < size + quiet; y += 2) {
    let line = "\x1b[30;47m";
    for (let x = -quiet; x < size + quiet; x++) {
      const top = dark(x, y);
      const bottom = dark(x, y + 1);
      line += top && bottom ? "█" : top ? "▀" : bottom ? "▄" : " ";
    }
    lines.push(line + "\x1b[0m");
  }
  return lines.join("\n");
}

export function renderQrSvg(qr: QrCode, quiet = 4, scale = 8): string {
  const size = qr.size + quiet * 2;
  const parts: string[] = [];
  for (let y = 0; y < qr.size; y++) {
    for (let x = 0; x < qr.size; x++) {
      if (qr.getModule(x, y)) parts.push(`M${x + quiet},${y + quiet}h1v1h-1z`);
    }
  }
  return (
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size} ${size}" width="${size * scale}" height="${size * scale}" shape-rendering="crispEdges">` +
    `<rect width="100%" height="100%" fill="#ffffff"/><path d="${parts.join("")}" fill="#000000"/></svg>\n`
  );
}
