import { QrCode } from "./qrcodegen.mjs";

// Preserve the actual origin/path; local development links stay local.
export function inviteURL(currentHref, lobbyCode) {
  const url = new URL(currentHref);
  url.searchParams.set("lobby", lobbyCode);
  return url.href;
}

export function encodeInviteQR(url) {
  return QrCode.encodeText(url, QrCode.Ecc.MEDIUM);
}

export function inviteQRSvg(url) {
  const qr = encodeInviteQR(url);
  const border = 4;
  const extent = qr.size + border * 2;
  const paths = [];
  for (let y = 0; y < qr.size; y++) {
    for (let x = 0; x < qr.size; x++) {
      if (qr.getModule(x, y)) paths.push(`M${x + border},${y + border}h1v1h-1z`);
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${extent} ${extent}" shape-rendering="crispEdges"><rect width="${extent}" height="${extent}" fill="#fff"/><path d="${paths.join("")}" fill="#000"/></svg>`;
}
