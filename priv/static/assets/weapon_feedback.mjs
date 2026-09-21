// Cosmetic gun response. Damage and magazine/reload state come from snapshots.
export class WeaponFeedback {
  constructor() { this.reset(); }
  reset() {
    this.epoch = null;
    this.actor = null;
    this.sequence = 0;
    this.nextAt = -Infinity;
    this.pending = new Map();
    this.predicted = new Set();
  }
  accept(game, id, now) {
    const epoch = `${game.round_id ?? game.seed}:${id}`;
    if (epoch !== this.epoch) { this.reset(); this.epoch = epoch; }
    this.actor = game.players.find((p) => p.id === id);
    this.active = game.status === 'playing' && !game.spectator && this.actor?.hp > 0;
    this.arrival = now;
    this.sequence = Math.max(this.sequence, this.actor?.last_effect_id || 0);
    for (const [id, at] of this.pending) {
      if (id <= (this.actor?.last_effect_id || 0) || now - at > 750) this.pending.delete(id);
    }
  }
  fire(now, held, reload = false) {
    if (!held || reload || !this.active || now - this.arrival > 250 || now < this.nextAt ||
        this.actor.reload_ms > 0 || this.actor.ammo - this.pending.size <= 0) return null;
    const id = ++this.sequence;
    this.nextAt = now + 200; // 180 ms authoritative cooldown rounds to four 50 ms ticks.
    this.pending.set(id, now);
    this.predicted.add(id);
    if (this.predicted.size > 128) this.predicted.delete(this.predicted.values().next().value);
    return id;
  }
  echoed(effect) { return effect.local && this.predicted.has(effect.effect_id); }
}

// Stop the immediate tracer at the visible hitbox; this does not predict damage.
export function tracerEnd(origin, angle, wall, targets) {
  const dx = Math.cos(angle), dy = Math.sin(angle);
  let distance = Math.hypot(wall.x - origin.x, wall.y - origin.y);
  for (const target of targets) {
    if (target.hp <= 0) continue;
    const x = target.x - origin.x, y = target.y - origin.y;
    const along = x * dx + y * dy;
    const perpendicular = Math.max(0, x * x + y * y - along * along);
    if (along >= 0 && perpendicular <= 121) distance = Math.min(distance, Math.max(0, along - Math.sqrt(121 - perpendicular)));
  }
  return {x: origin.x + dx * distance, y: origin.y + dy * distance};
}
