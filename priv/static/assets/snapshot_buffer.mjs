// Render positions behind the server clock so uneven packet arrival does not
// restart a 50 ms animation on every message. Never predict through a wall.
export class SnapshotBuffer {
  constructor(delayMs = 100, capacity = 32) {
    this.delayMs = delayMs;
    this.capacity = capacity;
    this.clear();
  }

  clear() {
    this.frames = [];
    this.offsets = [];
    this.renderTime = -Infinity;
    this.seed = null;
  }

  push(snapshot, arrivalMs) {
    const time = snapshot.elapsed_ms;
    const previous = this.frames.at(-1);
    if (snapshot.seed !== this.seed || (previous && time < previous.time))
      this.clear();
    this.seed = snapshot.seed;
    const frame = {
      time,
      players: new Map(snapshot.players.map((actor) => [actor.id, actor])),
      enemies: new Map((snapshot.enemies || []).map((actor) => [actor.id, actor])),
    };
    if (this.frames.at(-1)?.time === time) this.frames.pop();
    this.frames.push(frame);
    this.offsets.push(arrivalMs - time);
    if (this.frames.length > this.capacity) this.frames.shift();
    if (this.offsets.length > this.capacity) this.offsets.shift();
  }

  sample(nowMs) {
    if (!this.frames.length) return null;
    const newest = this.frames.at(-1);
    // The least delayed recent packet is our clock anchor; a late packet must
    // not reset playback or move actors backwards. Bound at the newest sample.
    const target = nowMs - Math.min(...this.offsets) - this.delayMs;
    this.renderTime = Math.max(this.renderTime, Math.min(newest.time, target));
    let from = this.frames[0];
    for (const to of this.frames) {
      if (to.time >= this.renderTime) {
        const span = to.time - from.time;
        return { from, to, t: span ? Math.max(0, (this.renderTime - from.time) / span) : 1 };
      }
      from = to;
    }
    return { from: newest, to: newest, t: 1 };
  }
}

export function mergeSnapshotMap(snapshot, current) {
  if (snapshot.map) return snapshot;
  if (current?.seed === snapshot.seed && current.map)
    return { ...snapshot, map: current.map };
  // Never draw a new operation using a previous operation's geometry.
  return null;
}

export function interpolateActor(latest, sample, kind) {
  if (!sample || latest.hp <= 0) return latest;
  const from = sample.from[kind].get(latest.id);
  const to = sample.to[kind].get(latest.id);
  if (!from || !to || from.hp <= 0 || to.hp <= 0) return latest;
  const delta = Math.atan2(Math.sin(to.angle - from.angle), Math.cos(to.angle - from.angle));
  return {
    ...latest,
    x: from.x + (to.x - from.x) * sample.t,
    y: from.y + (to.y - from.y) * sample.t,
    angle: from.angle + delta * sample.t,
  };
}

// Use the same visual origin as the local operator/laser, including while its
// position is interpolating between server ticks and the mouse stays still.
export function aimAt(actor, mouse, fallback = 0) {
  return actor && mouse
    ? Math.atan2(mouse.y - actor.y, mouse.x - actor.x)
    : fallback;
}
