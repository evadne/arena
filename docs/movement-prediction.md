# Movement prediction investigation

Status: prediction design only. Prediction remains unimplemented; transport and interpolation were subsequently adjusted as described below. Findings below come from this repository; there are no new latency measurements or external reference claims.

## Current behavior

- `priv/static/assets/app.js` sends the latest held direction, aim and fire state at 30 Hz. Pointer-down sends an extra input immediately, and release/blur sends a stop. Movement key changes now send immediately as well.
- `ArenaWeb.LobbyChannel.handle_in("input", ...)` clamps direction components to [-1, 1]. It accepts no position or movement duration from the client.
- `Arena.Lobby.handle_cast({:input, ...})` replaces each user's held input. It separately OR-latches shoot/reload so a brief action survives until a simulation tick.
- `Arena.Lobby.handle_info(:tick, ...)` samples that held direction once per 50 ms simulation step. Inputs received at least 250 ms ago become neutral. A direction can be used for zero, one or several ticks. The timer accounts for compute time; an overloaded process can still advance simulation time more slowly than wall time.
- `Arena.Game.step/3` moves a living human at 140 pixels/second, normalizes diagonal direction, and calls `Arena.Game.Map.move/3` with the tick displacement. Human movement is followed by authoritative shooting and enemy actions.
- Protocol 3 now permits at most four unacknowledged snapshot frames, retaining only the newest pending simulation state beyond that bounded window. Its frame sequence acknowledges decoding, not input processing. With nontrivial round-trip delay, update frequency is bounded by acknowledgement turnaround as well as the 50 ms minimum send interval. Simulation and incoming input continue independently.
- The client now interpolates local actor positions approximately 50 ms behind snapshot simulation time, with remote actors at 100 ms. Local aim responds immediately from the displayed local origin.

## Why sequence-only command replay is incorrect here

Suppose right-moving input 10 and left-moving input 11 both arrive before the same tick. Only 11 drives that tick. Replaying both as 33 ms movement adds movement the server never performed. Conversely, input 12 can drive several 50 ms ticks during a packet gap; treating its acknowledgement as exactly one command loses movement time.

Adding `last_input_seq` usefully identifies which direction was selected, but says neither how long it was used nor when an overwritten command was discarded. Do not sum packet durations or replay one movement step per outstanding packet. Frame sequence, input sequence and simulation tick must remain distinct concepts.

## Recommended incremental path

First implement a pure local movement model and cross-language collision fixtures. Keep it unused in gameplay until parity passes. Then introduce prediction for the living local player only, leaving remote actors on the existing interpolation buffer. Keep health, visibility, ammo, hits and actual shot/audio events authoritative.

For the smallest gameplay change, retain the present server sample-and-hold semantics and implement **bounded visual forecasting** from each authoritative local state. Simulate held direction for a bounded estimate of the time ahead of that snapshot; reconcile on every accepted snapshot. Input sequence plus the server's actual selected direction/tick can improve this estimate, but do not describe it as exact command replay. This yields immediate response without changing server movement rules, at the cost of corrections around fast reversals and variable input arrival.

For predictable reconciliation with a well-defined input history, use **tick-addressed movement intents** as a separate protocol version:

1. Inputs include a round/session identity, monotonically increasing `input_seq`, desired direction and a proposed `target_tick`. Repeated keepalives may update aim/fire without manufacturing movement time. Send direction changes immediately, plus a bounded keepalive frequency.
2. The server owns the 50 ms tick schedule. Maintain a small bounded map of future movement intents per player. Clamp late intents to the next unprocessed tick; accept only a small allowed lead (for example, at most four ticks); reject stale sequence/round identities. For each target tick, keep the latest sequence. Limit queue size and accepted message rate. Never execute extra simulation steps because more inputs arrive.
3. At each server tick, apply at most one selected movement state for exactly that tick's duration. If no intent is due, hold the previous state subject to the existing 250 ms receipt-age timeout. Preserve the separate one-shot reload/fire latch; movement history must not replay weapon effects.
4. A personalized snapshot carries the authoritative position at tick T and local control metadata: selected input sequence, selected direction, and whether the input timeout forced neutral. Include the epoch/round identity. Publish the values actually consumed by `Game.step`, not merely the newest message received after that step.
5. The client reconciles from the authoritative position at T. Retain only unacknowledged local changes, schedule those into predicted future ticks, and simulate each tick T+1 through a bounded predicted-present tick exactly once. A late unacknowledged change whose proposed tick is already past may be optimistically reassigned to T+1; the next authoritative snapshot resolves that uncertainty. An acknowledgement means a selected state became authoritative, not that all old packets each earned movement duration.
6. A partial final visual tick may be calculated from a copy of the last complete predicted tick. Never feed that partial result back into the next full simulation tick. This avoids changing collision outcomes merely because the display runs at 60 or 144 Hz.

The first option is the smaller, safer incremental delivery. The tick-addressed option is a protocol and simulation-input change that should follow separately if the remaining corrections warrant it. Neither requires accepting client position, client-computed hits, arbitrary client `dt`, or client-requested catch-up ticks.

## Collision parity is mandatory

The module is `Arena.Game.Map` (aliased as `World` in the game), not a `Wall` module. Its collision geometry is the full solid tile grid. Public `walls` contains only solid tiles near a walkable cell for rendering, so it is not the complete collision grid. Build the client collision set from the complement of `floor_tiles` within map bounds; all out-of-bounds cells are solid.

Exact rules to port:

- Tile size is currently 32 pixels. Use the map's transmitted `tile_size` and dimensions.
- Actor radius is 10. For every tile overlapping the actor's axis-aligned radius bounds, find the nearest point on that tile's rectangle. A solid tile permits the position only when squared distance is **greater than or equal to** 100; exact tangency is allowed.
- Tile coordinates use mathematical floor, including negative coordinates.
- Normalize input with `max(1, sqrt(x*x + y*y))`; speed is 140 pixels/second.
- A move uses `max(1, ceil(max(abs(dx), abs(dy)) / 6))` substeps.
- Every substep attempts X first, then attempts Y from the accepted X. Do not replace this with independent-axis checks from the old position, a center-point ray, circle-vs-rendered-walls logic, or one combined diagonal test.
- Full prediction steps must use the same 50 ms segmentation as the server. Splitting a movement into arbitrary animation-frame lengths can produce different results at corners despite identical total displacement.

## Bounds, correction and lifecycle

Start with a conservative forecast horizon of 100–150 ms, and measure correction distances before expanding it. This is a proposed setting, not a measured requirement. Bound prediction relative to the latest authoritative simulation tick, not by the number of received packets. If a slow client has no new state, stop advancing at the cap instead of walking indefinitely into unknown outcomes. Reset the estimate after long stalls or tab visibility changes; do not simulate a large accumulated animation `dt`.

Bounded-window snapshot backpressure means a slow connection may have snapshots further apart than the interpolation delay. Local prediction should not be coupled to sending a frame acknowledgement, and should not remove that backpressure. The horizon deliberately limits how far a client can look smooth while authoritative state is unavailable; remote actors continue to hold at their newest known state. Under serious network delay, some correction or holding is preferable to unconstrained invention.

Keep logical predicted position separate from a small decaying visual correction offset. Apply authoritative corrections immediately to logical state. Smooth only small safe visual differences; check that the rendered center still fits and that the correction path is safe. Snap on blocked corrections, large displacements, deaths, teleport-like round spawns or epoch changes. Linear smoothing across a concave corner can visually cut through walls even if both endpoints fit.

The local aim calculation and laser originate from the predicted/rendered local position so mouse targeting remains coherent. Send that aim angle to the server; actual hitscan still originates at the authoritative actor position. Do not promise predicted laser and authoritative shot agree during a correction. Do not predict damage or reveal enemies/tiles based on the forecast origin.

Clear pending intents, prediction accumulator, clock estimate and smoothing offset on disconnect/rejoin, lobby waiting, round/seed/epoch change, local actor identity change, death and spectator transition. Stop immediately on authoritative round end. Blur/hidden/document focus changes send neutral input and clear held prediction. An authoritative dead actor always bypasses local movement prediction.

## Implementation hooks and verification

- `priv/static/assets/app.js`: unify interval, pointer and release input emission; capture direction changes immediately; manage predictor reset; use predicted local position for local drawing and `updateAim()`. Continue iterating the latest authoritative enemy list.
- New pure `priv/static/assets/movement_prediction.mjs`: collision geometry, fixed-step movement and bounded reconciliation, independent of DOM/network.
- `lib/arena_web/lobby_channel.ex`: validate/version movement metadata; never confuse `frame_ack` with input acknowledgement.
- `lib/arena/lobby.ex`: record the actual selected input metadata with each tick, or own the bounded future-intent queue if adopting that option. Preserve the timeout and action latches.
- `lib/arena/game.ex`: expose personalized local movement metadata associated with the actual stepped state. Prefer one localized metadata field over leaking other players' command histories.
- `lib/arena_web/snapshot_delta.ex` and `frame_decoder.mjs`: ensure the personalized control metadata is transmitted and reconstructed correctly; existing scalar replacement supports a small whole metadata object.

Tests should include shared Elixir/JavaScript golden positions for straight movement, diagonal normalization, tangency, sliding, concave corners, narrow doors, negative/out-of-bounds positions and long-displacement substeps. Compare tolerance explicitly. Test held input over several ticks, two or more updates within one tick, rapid reversals, input expiry, duplicate/stale sequences, late/future intents, snapshot tick skips from backpressure, reconnect/round/death resets, hidden actors remaining hidden, and forecast stopping at its cap. Run identical intent traces at 30/60/144 Hz render schedules and require identical completed-tick positions. Flooded input and malicious `target_tick`/duration values must never increase server displacement beyond one normalized 140 px/s movement step per authoritative tick.
