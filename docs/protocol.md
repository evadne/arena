# Channel protocol

Connect a Phoenix socket at `/socket` and join `lobby:CODE`, where the code is 4–12 uppercase letters or digits. Join payload: `{name, protocol: 3}`. The server assigns a fresh `user_id` per socket and replies with `{user_id, lobby, game}`. `game` is null in staging.

## Client events

| Event | Payload | Access |
| --- | --- | --- |
| `input` | `{x, y, aim, shoot, reload, round_id, effect_id, shot_aim, aim_point, view_ms, seen_tick}` | Living operator during play; no reply |
| `ping` | `{}` | Connection RTT probe; replies `ok` |
| `chat` | `{text}` | Connected member outside active play |
| `start` | `{}` | Leader in staging |
| `order` | `{order}` | Living human during play; hold, form_up, aggro or auto |
| `reset` | `{}` | Leader after won/lost; returns to staging |

Input axes are clamped to −1…1 and normalized server-side. Aim is radians. Shoot/reload are booleans. Clients send intent at 30 Hz; the server simulates at 20 Hz and stops stale movement/fire after 250 ms without fresh input. Fire/reload presses are latched across updates so a quick press and release between ticks is not lost. Other actions reply `ok` or `error` with `{reason}`.

## Server events

- `lobby`: `{code, leader_id, members: [{id, name, slot}], bot_names: [name, name, name, name], status, chat}`.
- `chat`: `{id, name, text, at}`; text only, at most 280 characters. History retains the last 60 messages.
- `frame`: an acknowledged keyframe or delta, described below.
- `snapshot`: legacy viewer-specific game state (protocols 1 and 2).

Status is `waiting`, `playing`, `won`, or `lost`. Staging slots follow join order from zero, with bots filling the remainder. Departures close gaps while waiting, and each new player joins at the end. The first arrival leads; when they leave, the oldest remaining player succeeds them. Manual `slot`, `transfer` and `formation` events are rejected. Deployment uses the default arrangement; `order` selects the in-game AI disposition. When the final human leaves, the process terminates. A new arrival during play takes over a vacant bot slot with its existing position, health and ammunition. During a round, existing slot numbers stay stable; `reset` restores join-order slots for the next briefing.

## Acknowledged delta frames (protocol 3)

The first frame of a round contains `{seq, base: null, full: snapshot}`. The full snapshot includes the floorplan. Subsequent frames describe changes against the immediately previous sent frame. WebSocket delivery is reliable and ordered, so the receiver has that baseline when it processes the next frame:

```js
{
  seq: 12, base: 11,
  changes: {tick: 48, elapsed_ms: 2400},
  players: {upsert: [{id: "operator-id", x: 112.5, angle: 0.7}]},
  enemies: {remove: ["hostile-4"]},
  visible_tiles: {add: [[4, 7]], remove: [[3, 7]]},
  events: [{id: 19, type: "shot", x: 112.5, y: 200, team: "friendly", volume: 0.9, occluded: false}]
}
```

Empty fields are omitted. `players` and `enemies` have sparse `upsert` records and `remove` IDs; newly visible actors get complete records. `visible_tiles` and `explored_tiles` are set additions/removals. `changes` contains changed scalar snapshot fields only. Names, unchanged health/ammunition and geometry are not repeated. Positions are authoritative absolute coordinates; timestamps and the browser's position history supply interpolation, so no redundant velocity fields are sent. Shots/events include only newly encountered IDs and are empty when absent. They are cosmetic and may be skipped after a long stall; persistent state always catches up.

After reconstructing a frame, send `frame_ack` with `{seq}` (no reply). Acknowledgements are cumulative and valid only for actually outstanding frame numbers. The server permits at most four unacknowledged frames per Channel, with a 50 ms minimum send interval. This small pipeline sustains 20 updates/second through ordinary round-trip delay instead of stopping after every frame to wait for a reply. When the window is full, incoming ticks replace a single pending state before visibility filtering or JSON encoding. An acknowledgement frees space for the newest pending state; old pending ticks are not queued. Very slow clients still adapt down, and memory/transport backlog remain bounded.

Deltas form a chain against the last sent baseline; `frame_ack` controls the send window, not which snapshot supplies the next delta baseline. A missing baseline still triggers a full resync. Remote actors use a 100 ms interpolation buffer that clamps to the newest state. The local player forecasts against the shared collision geometry, with a latency-dependent horizon capped at 400 ms and bounded visual correction. Movement direction changes are sent immediately, in addition to 30 Hz held-input refreshes. The local player uses bounded movement forecasting and reconciliation; human hitscan uses shared server history.

A missing/wrong baseline triggers `frame_resync` with `{}` (no reply): the next frame is full. Resync requests are limited to once per second. Frame numbers stay monotonic across rounds within a Channel; old acknowledgements/timers are ignored. A client that fails to acknowledge for 15 seconds loses its Channel; Phoenix rejoins automatically with fresh state. Other players and the simulation continue independently. A new socket identity can only reclaim an available bot slot. As with all departures, an empty lobby closes.

Visibility filtering happens **before** delta comparison, independently for each viewer. Removal records hide actors that leave team sight. A dead player's transition to spectator adds the newly revealed actors and tiles. Private AI state never enters a frame.

Join replies retain a full `game` for immediate late-join display; the first streamed keyframe establishes the acknowledgement baseline. Protocol 2 omits the map after the first snapshot of a seed. Protocol 1 (including joins without a protocol) remains compatible with existing tabs by sending full snapshots. Refresh existing tabs to enable protocol 3.

## Game snapshot

```text
{
  seed, round_id, status, tick, elapsed_ms, spectator, order, control: {x,y},
  map: {width, height, tile_size, archetype, entry: {x,y,label},
        floor_tiles: [[column,row]], exterior_tiles: [[column,row]], walls: [{x,y,w,h}],
        rooms: [{x,y,w,h,label}], spawn: {x,y}},
  players: [{id,name,slot,x,y,angle,hp,ammo,reload_ms,bot,last_effect_id}],
  enemies: [{id,x,y,angle,hp,state}], enemies_remaining, enemies_total,
  shots: [{id,x1,y1,x2,y2,team,local,effect_id}],
  events: [{id,type,x,y,team,volume,occluded,local,effect_id}],
  visible_tiles: [[column,row]], explored_tiles: [[column,row]]
}
```

Coordinates are world pixels. Maps are 1408×1024, with 32-pixel tiles. Four operators and 12–20 enemies spawn each round. Each connected floorplan contains 8–12 rooms, an irregular perimeter and an external staging area. For living viewers, enemy actors and hostile shot origins are filtered by shared squad vision. The blueprint remains available for navigation. A dead human gets `spectator: true`, all actors, all map tiles and all shots until the next round.

Sound event types are `shot`, `reload`, `hit`, `death` and `round_end`. Event IDs remain stable over their 200 ms retention period; clients deduplicate them. The server filters audible events by the viewer's position and supplies distance gain and wall occlusion. Nearby unseen gunfire is an intentional sound cue, not visual knowledge. Spectators receive the full sound field. Clients synthesize and spatially pan the audio. Their own gun sound and tracer play immediately; matching `local`/`effect_id` echoes are suppressed. Damage, hits, death and reload outcomes remain authoritative.

## Engine API

`Arena.Game.new(members, seed, bot_names \\ nil)`, `step(game, inputs, dt_ms \\ 50)`, `public(game, user_id \\ nil)` , `disconnect(game, user_id)` and `set_order(game, order, requester_id)`. Inputs map user IDs to atom-keyed intent maps. Internal simulation state stays in the lobby process; PubSub relays current state without the shared history internally to Channels, which sanitize each snapshot for its recipient before JSON serialization.

## Predicted controls and compensated shots

`round_id` identifies a simulation round independently of the map seed. The personalized `control` field contains the movement direction actually consumed in the snapshot tick; it acknowledges no duration or packet count. Stale-round input is ignored. Legacy inputs without the new metadata remain supported.

Each predicted shot has a positive increasing `effect_id` (at most 2,147,483,647), a captured `shot_aim` angle and optional `{x,y}` world cursor `aim_point`, `view_ms` (rendered simulation time) and `seen_tick` (latest received snapshot tick). No client origin or hit/target claim is accepted. Metadata freezes on the first submission of that ID, survives trigger release and cannot produce more than one shot. Subsequent IDs still obey server cooldown/ammunition/reload.

ACKs also measure connection RTT using the outstanding frame's server send time. The Channel validates shot tick/round metadata; the shared game history validates rewind time against RTT plus the fixed 100 ms remote interpolation and queue time, with a one-second cap and a 200 ms discrepancy fallback. Human reaction time adds no allowance. History contains one common set of enemy transforms and shared visibility per simulation tick. It is neither duplicated per connection nor exposed in frames. See [the full compensation rules](lag-compensation.md).
