import test from "node:test";
import assert from "node:assert/strict";
import { FrameDecoder } from "../priv/static/assets/frame_decoder.mjs";

function full(seed = 1) {
  return {
    seed, tick: 1, elapsed_ms: 50, status: "playing", spectator: false,
    map: { width: 128, height: 128, walls: [{ x: 10, y: 0, w: 2, h: 8 }] },
    players: [{ id: "p1", x: 0, y: 4, angle: 0, hp: 100, ammo: 20 },
      { id: "p2", x: 6, y: 4, angle: 0, hp: 100, ammo: 20 }],
    enemies: [{ id: "e1", x: 32, y: 4, angle: 3.14, hp: 90 }],
    visible_tiles: [[0, 0], [1, 0]], explored_tiles: [[0, 0], [1, 0]],
    shots: [{ id: 4 }], events: [{ id: 7, type: "shot" }],
  };
}
function start() {
  const decoder = new FrameDecoder();
  assert.equal(decoder.apply({ seq: 1, base: null, full: full() }).status, "applied");
  return decoder;
}

test("keyframe establishes exact baseline and sequence", () => {
  const decoder = new FrameDecoder();
  const snapshot = full();
  assert.deepEqual(decoder.apply({ seq: 3, base: null, full: snapshot }),
    { status: "applied", seq: 3, snapshot });
  assert.equal(decoder.snapshot, snapshot);
  assert.equal(decoder.seq, 3);
});

test("delta reconstructs scalar fields, sparse actors, visibility and transient events", () => {
  const decoder = start();
  const original = decoder.snapshot;
  const result = decoder.apply({ seq: 2, base: 1,
    changes: { tick: 2, elapsed_ms: 100, spectator: true },
    players: { upsert: [{ id: "p1", x: 3, hp: 0, ammo: 19 }], remove: ["p2"] },
    enemies: { upsert: [{ id: "e2", x: 64, y: 4, angle: 0, hp: 90 }], remove: ["e1"] },
    visible_tiles: { add: [[2, 0]], remove: [[0, 0]] },
    explored_tiles: { add: [[2, 0]], remove: [] },
    shots: [{ id: 5 }], events: [{ id: 8, type: "death" }],
  });
  assert.equal(result.status, "applied");
  assert.deepEqual(result.snapshot, { ...full(), tick: 2, elapsed_ms: 100, spectator: true,
    players: [{ id: "p1", x: 3, y: 4, angle: 0, hp: 0, ammo: 19 }],
    enemies: [{ id: "e2", x: 64, y: 4, angle: 0, hp: 90 }],
    visible_tiles: [[1, 0], [2, 0]], explored_tiles: [[0, 0], [1, 0], [2, 0]],
    shots: [{ id: 5 }], events: [{ id: 8, type: "death" }],
  });
  assert.equal(result.snapshot.map, original.map);
  assert.deepEqual(original, full(), "buffered previous snapshot must remain immutable");
});

test("omitted delta collections persist except transient shots and sound events", () => {
  const decoder = start();
  const previous = decoder.snapshot;
  const { snapshot } = decoder.apply({ seq: 2, base: 1 });
  assert.equal(snapshot.players, previous.players);
  assert.equal(snapshot.enemies, previous.enemies);
  assert.equal(snapshot.visible_tiles, previous.visible_tiles);
  assert.equal(snapshot.map, previous.map);
  assert.deepEqual(snapshot.shots, []);
  assert.deepEqual(snapshot.events, []);
});

test("wrong or missing baseline requests resync without altering authoritative state", () => {
  const decoder = new FrameDecoder();
  assert.equal(decoder.apply({ seq: 2, base: 1, changes: { tick: 2 } }).status, "resync");
  assert.equal(decoder.seq, null);
  decoder.apply({ seq: 3, base: null, full: full() });
  const previous = decoder.snapshot;
  assert.equal(decoder.apply({ seq: 4, base: 2, changes: { spectator: true } }).status, "resync");
  assert.equal(decoder.snapshot, previous);
  assert.equal(decoder.seq, 3);
  assert.equal(decoder.apply({ seq: 5, base: null, full: full(2) }).status, "applied");
  assert.equal(decoder.snapshot.seed, 2);
});

test("duplicate and stale deltas/keyframes are ignored", () => {
  const decoder = start();
  const previous = decoder.snapshot;
  assert.equal(decoder.apply({ seq: 1, base: null, full: full(2) }).status, "stale");
  assert.equal(decoder.apply({ seq: 0, base: 0, changes: { tick: 9 } }).status, "stale");
  assert.equal(decoder.snapshot, previous);
});

test("reset removes baseline and allows restarted channel sequence", () => {
  const decoder = start();
  decoder.apply({ seq: 10, base: 1, changes: { tick: 2 } });
  decoder.reset();
  assert.equal(decoder.seq, null);
  assert.equal(decoder.snapshot, null);
  assert.equal(decoder.apply({ seq: 11, base: 10 }).status, "resync");
  assert.equal(decoder.apply({ seq: 1, base: null, full: full(2) }).status, "applied");
});

test("hidden actors are removed immediately and reappearance starts from full actor data", () => {
  const decoder = start();
  decoder.apply({ seq: 2, base: 1, enemies: { remove: ["e1"] } });
  assert.deepEqual(decoder.snapshot.enemies, []);
  const actor = { id: "e1", x: 77, y: 88, hp: 22, angle: 1.2 };
  decoder.apply({ seq: 3, base: 2, enemies: { upsert: [actor] } });
  assert.deepEqual(decoder.snapshot.enemies, [actor]);
});

test("tile changes have set semantics", () => {
  const decoder = start();
  decoder.apply({ seq: 2, base: 1,
    visible_tiles: { add: [[1, 0], [2, 0], [2, 0]], remove: [[9, 9], [0, 0]] },
  });
  assert.deepEqual(decoder.snapshot.visible_tiles, [[1, 0], [2, 0]]);
});

test("malformed envelope or delta fails atomically", () => {
  const decoder = start();
  const previous = decoder.snapshot;
  for (const bad of [null, { seq: NaN }, { seq: 2, base: null, full: {} },
    { seq: 2, base: 1, changes: { map: {} } },
    { seq: 2, base: 1, players: { upsert: [{ hp: 0 }] } },
    { seq: 2, base: 1, visible_tiles: { add: [null] } },
  ]) {
    assert.equal(decoder.apply(bad).status, "resync");
    assert.equal(decoder.snapshot, previous);
    assert.equal(decoder.seq, 1);
  }
});
