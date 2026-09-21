const collectionKeys = new Set([
  "map", "players", "enemies", "visible_tiles", "explored_tiles", "shots", "events",
]);

function mergeActors(previous, change) {
  if (!change) return previous;
  const actors = new Map(previous.map((actor) => [actor.id, actor]));
  for (const id of change.remove || []) actors.delete(id);
  for (const fields of change.upsert || []) {
    if (fields.id == null) throw new Error("Actor delta requires an id");
    actors.set(fields.id, { ...actors.get(fields.id), ...fields });
  }
  return [...actors.values()];
}

function mergeTiles(previous, change) {
  if (!change) return previous;
  const tiles = new Map(previous.map((tile) => [tile.join(","), tile]));
  for (const tile of change.remove || []) tiles.delete(tile.join(","));
  for (const tile of change.add || []) tiles.set(tile.join(","), tile);
  return [...tiles.values()];
}

// A delta is meaningful only against its acknowledged baseline. Do not advance
// the sequence or expose half-applied state if that baseline is unavailable.
export class FrameDecoder {
  constructor() {
    this.reset();
  }

  reset() {
    this.seq = null;
    this.snapshot = null;
  }

  apply(frame) {
    if (!frame || !Number.isSafeInteger(frame.seq) || frame.seq < 0)
      return { status: "resync" };
    if (this.seq !== null && frame.seq <= this.seq)
      return { status: "stale" };

    let next;
    if (frame.base === null) {
      next = frame.full;
      if (!next?.map || !Array.isArray(next.players) || !Array.isArray(next.enemies))
        return { status: "resync" };
    } else {
      if (!this.snapshot || frame.base !== this.seq)
        return { status: "resync" };
      if (Object.keys(frame.changes || {}).some((key) => collectionKeys.has(key)))
        return { status: "resync" };
      try {
        next = {
          ...this.snapshot,
          ...frame.changes,
          players: mergeActors(this.snapshot.players, frame.players),
          enemies: mergeActors(this.snapshot.enemies, frame.enemies),
          visible_tiles: mergeTiles(this.snapshot.visible_tiles || [], frame.visible_tiles),
          explored_tiles: mergeTiles(this.snapshot.explored_tiles || [], frame.explored_tiles),
          // Transient effects are fresh per frame, never carried forward.
          shots: frame.shots || [],
          events: frame.events || [],
        };
      } catch {
        return { status: "resync" };
      }
    }
    this.seq = frame.seq;
    this.snapshot = next;
    return { status: "applied", seq: this.seq, snapshot: next };
  }
}
