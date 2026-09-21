# Backlog

## Hitscan lag compensation

Status: deferred; not implemented.

Shots currently intersect actors at their current authoritative server positions. The client displays buffered snapshots, so a shot aimed at a moving enemy's visible position can miss its server hitbox under latency.

- Retain a bounded, per-round server history of actor positions and hitboxes. Resolve eligible shots against the historical state corresponding to what the shooter was viewing, accounting for remote interpolation delay.
- Derive and validate shot timing from server-observed timing and snapshot metadata. Cap rewind duration and reject stale, duplicate, future or previous-round requests; never trust client-reported hits or arbitrary timestamps.
- Define fairness rules for cover, visibility, shooter origin and targets already dead in the current state. Preserve wall occlusion and avoid revealing hidden enemies. Apply damage once to the current authoritative state without rewinding the live simulation.
- Preserve fire-rate, ammo and reload authority. Clear history on round changes and bound memory and work per shot.
- Verify moving-target hits and misses under controlled latency and jitter, cover transitions, death/round boundaries and invalid timing claims. Measure the benefit and maximum rewind before choosing the production cap.

This is separate from the proposed [local movement prediction and reconciliation](movement-prediction.md). Neither feature is currently enabled.
