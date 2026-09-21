# Hitscan timing and shared history

## Valve review

Valve's [Source SDK lag-compensation manager](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/player_lagcompensation.cpp) records actor histories once per simulation update, independently of recipients. `StartLagCompensation` computes correction from network latency plus interpolation, clamps it to `sv_maxunlag` (default one second), and starts with the command tick minus interpolation ticks. If that time differs from the latency estimate by over 200 ms, it uses the estimate. It excludes the shooter, finds bracketing history records and interpolates without extrapolation. Death and teleport discontinuities invalidate rewind. The implementation temporarily moves targets, executes the shot, then restores them.

The [player eligibility check](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/player.cpp) excludes teammates when friendly fire is disabled, and excludes entities not transmitted to that client. The [shared weapon effects code](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/shared/sdk/sdk_fx_shared.cpp) separates predicted firing effects from server lag compensation and damage.

Human reaction time is not an additional backdating allowance. The relevant time is the displayed battlefield when the trigger was pulled, including its interpolation delay. Bernier's [original paper](https://www.gamedevs.org/uploads/latency-compensation-in-client-server-protocols.pdf) explains why presentation and connection delay both matter.

## Breach implementation

`Arena.Game.LagCompensation` retains one common buffer per round: at most 21 records spanning 1,000 ms at 20 Hz. A record contains enemy IDs, positions, health and shared squad visibility. It contains no map or full snapshots. History stays in the authoritative game; it is removed before internal PubSub delivery to Channels and never enters the wire protocol. A fresh round has a new identity even if its map seed repeats.

The client freezes its render simulation time, latest received tick, cursor aim point and a monotonic effect ID at each trigger. Keepalives and release cannot change an already submitted shot. Each connection tracks recent snapshot-ACK round trips and its ordinary last-sent delta baseline, with no separate actor-history buffer. The server verifies the round and that the referenced tick is no newer than one it sent.

Our browser anchors remote playback to snapshot arrival, rather than Source's synchronised command clock. Consequently the expected age of a rendered target at execution is **frame travel out + input travel back + 100 ms interpolation + server queue time**. The first two terms are estimated from server-observed ACK RTT; using half that RTT would under-compensate this particular clock design. The client reports render time directly, so interpolation is not subtracted twice. Claims outside the one-second window, in the future, or more than 200 ms from this estimate use the measured fallback. This adapts Valve's validation pattern; it does not claim identical engine clocks or transport semantics.

Targets are sampled from bracketing records in the common buffer, with no extrapolation across missing history, death or jumps over 64 pixels. The client's latest received tick supplies shared visibility membership. Newly visible targets use their latest visible position, as the renderer does. A spectator cannot fire. This is target reconstruction for human shots only; AI operates in present simulation time, and there is no friendly fire.

The shooter remains at its current authoritative position. For this top-down game the ray points from there to the world-space cursor captured on the trigger, avoiding an angle error caused by a small local prediction correction. Client origins and hit claims are not accepted. Static walls clip the ray. Damage applies once to the current living target; its position, AI, timers and the world are never temporarily mutated. An enemy may be hit at a historical exposed position after reaching cover, within the validated window; the historical ray must still be unobstructed.

Local gun sound and a wall/visible-hitbox-clipped tracer play immediately. Effect IDs reserve cosmetic ammunition, suppress the shooter's echoed sound/tracer and prevent repeated commands firing twice. The server still owns fire cadence, magazine, reload, damage and outcomes. Other players hear the authoritative shot. No damage or kill is predicted locally.

## Verification and limits

Tests cover a moving target missed by current-state raycasts but hit by rewind; fractional interpolation; current health/position preservation; cover, visibility, death and discontinuities; duplicate commands; command expiry and round reset; invalid-time fallback; shot metadata surviving keepalive/release; actual Channel ACK timing; and bounded shared storage. Client tests cover immediate effects, ammo reservations, echo deduplication, reload, stalls and resets.

The one-second limit is an explicit initial tuning limit, not a measured optimum for Breach. RTT cannot identify asymmetric one-way delays. Under heavy backpressure the browser may interpolate across skipped snapshots while the server has intermediate records; a nonlinear turn can then differ from reconstructed display. Do not claim pixel-exact matching on arbitrarily stalled connections. The bounded movement forecast is likewise an estimate, not exact tick-addressed input replay. Neither limitation is addressed by simply increasing simulation frequency.
