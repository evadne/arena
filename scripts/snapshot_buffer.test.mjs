import test from "node:test";
import assert from "node:assert/strict";
import { SnapshotBuffer, mergeSnapshotMap, interpolateActor } from "../priv/static/assets/snapshot_buffer.mjs";

const actor = (id, x, extra = {}) => ({ id, x, y: 0, angle: 0, hp: 100, ...extra });
const frame = (time, extra = {}) => ({ seed: 1, elapsed_ms: time,
  players: [actor("player", time / 10)], enemies: [actor("enemy", time / 10)], ...extra });
const position = (buffer, now, latest = frame(200).players[0]) =>
  interpolateActor(latest, buffer.sample(now), "players").x;

test("uneven delivery plays smoothly across several server snapshots", () => {
  const buffer = new SnapshotBuffer();
  buffer.push(frame(0), 1000);
  buffer.push(frame(50), 1060);
  buffer.push(frame(100), 1140);
  assert.equal(position(buffer, 1140), 4);
  assert.equal(position(buffer, 1160), 6);
  buffer.push(frame(150), 1190);
  assert.equal(position(buffer, 1190), 9);
  assert.equal(position(buffer, 1200), 10);
  buffer.push(frame(200), 1200);
  assert.equal(position(buffer, 1210), 11);
});

test("long packet gap holds newest position without extrapolation", () => {
  const buffer = new SnapshotBuffer();
  buffer.push(frame(0), 1000);
  buffer.push(frame(50), 1050);
  assert.equal(position(buffer, 1200), 5);
  assert.equal(position(buffer, 9000), 5);
  buffer.push(frame(100), 9001);
  assert.equal(position(buffer, 9001), 10);
});

test("window and timeline remain bounded without moving playback backwards", () => {
  const buffer = new SnapshotBuffer(100, 4);
  buffer.push(frame(0), 1000);
  buffer.push(frame(50), 1050);
  assert.equal(position(buffer, 1200), 5);
  for (let i = 2; i < 40; i++) buffer.push(frame(i * 50), 1200 + i * 50);
  assert.equal(buffer.frames.length, 4);
  assert.equal(buffer.offsets.length, 4);
  const first = buffer.sample(4000);
  const second = buffer.sample(3900);
  assert.equal(first.to.time, second.to.time);
});

test("new round and explicit reconnect clear historical positions", () => {
  const buffer = new SnapshotBuffer();
  buffer.push(frame(100), 1000);
  buffer.push(frame(0, { seed: 2, players: [actor("player", 75)] }), 1100);
  assert.equal(position(buffer, 1100), 75);
  assert.equal(buffer.frames.length, 1);
  buffer.clear();
  assert.equal(buffer.sample(1200), null);
});

test("latest authoritative death and other state are never delayed", () => {
  const buffer = new SnapshotBuffer();
  buffer.push(frame(0), 1000);
  buffer.push(frame(50), 1050);
  const dead = actor("player", 20, { hp: 0, ammo: 4 });
  assert.deepEqual(interpolateActor(dead, buffer.sample(1100), "players"), dead);
  const alive = actor("player", 20, { hp: 42, ammo: 3 });
  const rendered = interpolateActor(alive, buffer.sample(1100), "players");
  assert.equal(rendered.hp, 42);
  assert.equal(rendered.ammo, 3);
});

test("hidden enemies never reappear from buffered snapshots", () => {
  const buffer = new SnapshotBuffer();
  buffer.push(frame(0), 1000);
  buffer.push(frame(50), 1050);
  const latest = frame(100, { enemies: [] });
  buffer.push(latest, 1100);
  const rendered = latest.enemies.map((enemy) => interpolateActor(enemy, buffer.sample(1120), "enemies"));
  assert.deepEqual(rendered, []);
  // A newly visible actor must not interpolate from an unrelated older position.
  const newcomer = actor("new-enemy", 900);
  assert.deepEqual(interpolateActor(newcomer, buffer.sample(1120), "enemies"), newcomer);
});

test("angles interpolate across wrap through the short arc", () => {
  const buffer = new SnapshotBuffer();
  buffer.push(frame(0, { players: [actor("player", 0, { angle: 3.1 })] }), 1000);
  buffer.push(frame(50, { players: [actor("player", 5, { angle: -3.1 })] }), 1050);
  const rendered = interpolateActor(actor("player", 5), buffer.sample(1125), "players");
  assert.ok(Math.abs(rendered.angle - Math.PI) < 1e-8);
});

test("static map is reused only within the same operation", () => {
  const current = { ...frame(0), map: { walls: [1] } };
  assert.equal(mergeSnapshotMap(frame(50), current).map, current.map);
  assert.equal(mergeSnapshotMap(frame(0, { seed: 2 }), current), null);
  assert.equal(mergeSnapshotMap(frame(50), null), null);
  const full = { ...frame(0, { seed: 2 }), map: { walls: [2] } };
  assert.equal(mergeSnapshotMap(full, current), full);
});
