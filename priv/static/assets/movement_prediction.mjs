// The same tile-circle collision and X-then-Y substeps as Arena.Game.Map.
export class CollisionMap {
  constructor(map) {
    this.size = map.tile_size;
    this.width = map.width;
    this.height = map.height;
    this.floor = new Set(map.floor_tiles.map(([x, y]) => `${x},${y}`));
  }
  fits({ x, y }) {
    const s = this.size;
    for (let cx = Math.floor((x - 10) / s); cx <= Math.floor((x + 10) / s); cx++) {
      for (let cy = Math.floor((y - 10) / s); cy <= Math.floor((y + 10) / s); cy++) {
        if (cx >= 0 && cy >= 0 && cx * s < this.width && cy * s < this.height && this.floor.has(`${cx},${cy}`)) continue;
        const nx = Math.max(cx * s, Math.min(x, (cx + 1) * s));
        const ny = Math.max(cy * s, Math.min(y, (cy + 1) * s));
        if ((x - nx) ** 2 + (y - ny) ** 2 < 100) return false;
      }
    }
    return true;
  }
  move(position, dx, dy) {
    const count = Math.max(1, Math.ceil(Math.max(Math.abs(dx), Math.abs(dy)) / 6));
    let { x, y } = position;
    for (let i = 0; i < count; i++) {
      if (this.fits({ x: x + dx / count, y })) x += dx / count;
      if (this.fits({ x, y: y + dy / count })) y += dy / count;
    }
    return { x, y };
  }
  safeSegment(a, b) {
    const count = Math.max(1, Math.ceil(Math.hypot(b.x - a.x, b.y - a.y)));
    for (let i = 0; i <= count; i++) {
      if (!this.fits({ x: a.x + (b.x - a.x) * i / count, y: a.y + (b.y - a.y) * i / count })) return false;
    }
    return true;
  }
}

export function movePlayer(map, position, direction, ms) {
  const norm = Math.max(1, Math.hypot(direction.x, direction.y));
  return map.move(position, direction.x / norm * 140 * ms / 1000, direction.y / norm * 140 * ms / 1000);
}

// Sample-and-hold inputs do not acknowledge a duration. Forecast a bounded
// timeline, never replay one movement step per packet. Every render starts from
// the authoritative anchor; partial steps never accumulate into complete ticks.
export class MovementPrediction {
  constructor() { this.reset(); }
  reset() {
    this.actor = null;
    this.epoch = null;
    this.offsets = [];
    this.inputs = [];
    this.direction = { x: 0, y: 0 };
    this.correction = { x: 0, y: 0 };
    this.rtt = 0;
    this.suspended = false;
    this.maxCorrection = 0;
  }
  setRTT(ms) { if (Number.isFinite(ms)) this.rtt = Math.max(0, Math.min(300, ms)); }
  input(direction, now) {
    const resumed = this.suspended;
    this.suspended = false;
    if (!resumed && direction.x === this.direction.x && direction.y === this.direction.y) return;
    this.direction = { ...direction };
    this.inputs.push({ ...direction, at: now });
    this.inputs = this.inputs.filter((entry) => entry.at >= now - 1000).slice(-128);
  }
  suspend() {
    this.suspended = true;
    this.inputs = [];
    this.direction = { x: 0, y: 0 };
    this.correction = { x: 0, y: 0 };
  }
  accept(game, id, now) {
    const actor = game.players.find((p) => p.id === id);
    const epoch = `${game.round_id ?? game.seed}:${id}`;
    if (epoch !== this.epoch || game.elapsed_ms < this.time) {
      const rtt = this.rtt;
      this.reset();
      this.rtt = rtt;
      this.epoch = epoch;
      this.map = new CollisionMap(game.map);
    }
    const previous = this.sample(now);
    this.actor = actor;
    this.active = actor?.hp > 0 && game.status === "playing" && !game.spectator;
    this.time = game.elapsed_ms;
    this.arrival = now;
    this.offsets.push(now - game.elapsed_ms);
    this.offsets = this.offsets.slice(-32);
    // Account for both legs of input->snapshot and half a simulation tick.
    this.anchorAt = game.elapsed_ms + Math.min(...this.offsets) - this.rtt - 25;
    this.control = game.control ?? { x: 0, y: 0 };
    this.correction = { x: 0, y: 0 };
    const next = this.forecast(now);
    if (previous && next && this.active && !this.suspended) {
      const distance = Math.hypot(previous.x - next.x, previous.y - next.y);
      this.maxCorrection = Math.max(this.maxCorrection, distance);
      if (distance <= 24 && this.map.safeSegment(next, previous)) {
        this.correction = { x: previous.x - next.x, y: previous.y - next.y };
        this.correctedAt = now;
      }
    }
    if (!this.active) this.suspend();
  }
  forecast(now) {
    if (!this.actor) return null;
    if (!this.active || this.suspended) return this.actor;
    const end = Math.max(this.anchorAt, Math.min(now, this.anchorAt + Math.min(400, Math.max(200, this.rtt + 100))));
    let position = this.actor;
    let direction = { x: this.control.x || 0, y: this.control.y || 0 };
    let index = 0;
    // Apply transitions at their local times, not retroactively across the whole
    // horizon. Bound every integration interval to the server's 50 ms step.
    for (let at = this.anchorAt; at < end;) {
      while (index < this.inputs.length && this.inputs[index].at <= at) direction = this.inputs[index++];
      const boundary = this.anchorAt + (Math.floor((at - this.anchorAt + 1e-7) / 50) + 1) * 50;
      const until = Math.min(end, boundary, this.inputs[index]?.at ?? Infinity);
      position = movePlayer(this.map, position, direction, until - at);
      at = until;
    }
    return { ...this.actor, ...position };
  }
  sample(now) {
    const actor = this.forecast(now);
    if (!actor || !this.active || this.suspended) return actor;
    const weight = Math.max(0, 1 - (now - (this.correctedAt ?? now)) / 80);
    const rendered = { ...actor, x: actor.x + this.correction.x * weight, y: actor.y + this.correction.y * weight };
    return this.map.safeSegment(actor, rendered) ? rendered : actor;
  }
}
