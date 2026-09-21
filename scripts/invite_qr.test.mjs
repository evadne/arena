import test from "node:test";
import assert from "node:assert/strict";
import { inviteURL, encodeInviteQR, inviteQRSvg } from "../priv/static/assets/invite_qr.mjs";

test("QR and copied invite use the exact current origin and operation", () => {
  assert.equal(inviteURL("https://evadne-arena.fly.dev/", "ABC234"),
    "https://evadne-arena.fly.dev/?lobby=ABC234");
  assert.equal(inviteURL("http://localhost:4000/?lobby=OLD", "NEW567"),
    "http://localhost:4000/?lobby=NEW567");
  assert.equal(inviteURL("https://example.test/breach?mode=night&lobby=OLD#briefing", "MAXCODE12345"),
    "https://example.test/breach?mode=night&lobby=MAXCODE12345#briefing");
});

test("production, local and maximum-length operation invites encode", () => {
  for (const [base, code] of [
    ["https://evadne-arena.fly.dev/", "ABC234"],
    ["https://evadne-arena.fly.dev/", "ABCD23456789"],
    ["http://localhost:4000/", "LOCAL7"],
  ]) {
    const qr = encodeInviteQR(inviteURL(base, code));
    assert.ok(qr.size >= 21 && qr.size <= 177);
    assert.equal((qr.size - 17) % 4, 0);
    assert.equal(qr.getModule(0, 0), true);
    assert.equal(qr.getModule(qr.size, qr.size), false);
  }
});

test("SVG preserves four white modules around every edge and has no URL markup", () => {
  const url = inviteURL("https://example.test/?note=%3Csvg%20onload%3Devil%3E", "ABC234");
  const qr = encodeInviteQR(url);
  const svg = inviteQRSvg(url);
  const extent = qr.size + 8;
  assert.ok(svg.includes(`viewBox="0 0 ${extent} ${extent}"`));
  assert.ok(svg.includes(`<rect width="${extent}" height="${extent}" fill="#fff"/>`));
  assert.ok(svg.includes('fill="#000"'));
  const modules = [...svg.matchAll(/M(\d+),(\d+)h1v1h-1z/g)];
  assert.ok(modules.length > 100);
  for (const [, x, y] of modules) {
    assert.ok(Number(x) >= 4 && Number(x) < extent - 4);
    assert.ok(Number(y) >= 4 && Number(y) < extent - 4);
    assert.equal(qr.getModule(Number(x) - 4, Number(y) - 4), true);
  }
  assert.ok(!svg.includes("onload"));
  assert.ok(!svg.includes("https:"));
});

test("oversized invite reports an encoding failure for UI fallback", () => {
  assert.throws(() => inviteQRSvg(`https://example.test/?extra=${"x".repeat(10000)}`), RangeError);
});
