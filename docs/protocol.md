# Channel protocol

Connect a Phoenix socket at `/socket` and join `lobby:CODE`, where the code is 4–12 uppercase letters or digits. Join payload: `{name, protocol: 3}`. The server assigns a fresh `user_id` per socket and replies with `{user_id, lobby, game}`. `game` is null in staging.

## Client events

| Event | Payload | Access |
| --- | --- | --- |
| `input` | `{x, y, aim, shoot, reload}` | Living operator during play; no reply |
| `chat` | `{text}` | Connected member outside active play |
| `start` | `{}` | Leader in staging |
| `transfer` | `{user_id}` | Leader; recipient must be connected |
| `slot` | `{slot}` | Member in staging; free slot 0–3 |
| `order` | `{order}` | Living human during play; hold, form_up, aggro or auto |
| `formation` | `{formation}` | Leader in staging; stack, wedge or line |
| `reset` | `{}` | Leader after won/lost; returns to staging |

Input axes are clamped to −1…1 and normalized server-side. Aim is radians. Shoot/reload are booleans. Clients send intent at 30 Hz; the server simulates at 20 Hz and stops stale movement/fire after 250 ms without fresh input. Fire/reload presses are latched across updates so a quick press and release between ticks is not lost. Other actions reply `ok` or `error` with `{reason}`.

## Server events

- `lobby`: `{code, leader_id, members: [{id, name, slot}], bot_names: [name, name, name, name], formation, status, chat}`.
- `chat`: `{id, name, text, at}`; text only, at most 280 characters. History retains the last 60 messages.
- `frame`: an acknowledged keyframe or delta, described below.
- `snapshot`: legacy viewer-specific game state (protocols 1 and 2).

Status is `waiting`, `playing`, `won`, or `lost`. First arrival leads. When the leader exits, a random remaining human inherits leadership. When the final human leaves, the process terminates. A new arrival during play takes over a vacant bot slot with its existing position, health and ammunition.

## Acknowledged delta frames (protocol 3)

The first frame of a round contains `{seq, base: null, full: snapshot}`. The full snapshot includes the floorplan. Subsequent frames describe changes against the last acknowledged frame:

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

After reconstructing a frame, send `frame_ack` with `{seq}` (no reply). The server permits one unacknowledged frame per Channel. While waiting, incoming ticks replace a single pending state, before visibility filtering or JSON encoding. On acknowledgement the newest state is sent, subject to a 50 ms minimum send interval. Thus the maximum is 20 updates/second, and slow clients adapt down to their acknowledgement rate without accumulating snapshot history. Rendering uses a bounded 100 ms interpolation buffer, clamps to the newest position and never extrapolates through walls. There is no client movement prediction or lag-compensated shooting yet.

A missing/wrong baseline triggers `frame_resync` with `{}` (no reply): the next frame is full. Resync requests are limited to once per second. Frame numbers stay monotonic across rounds within a Channel; old acknowledgements/timers are ignored. A client that fails to acknowledge for 15 seconds loses its Channel; Phoenix rejoins automatically with fresh state. Other players and the simulation continue independently. A new socket identity can only reclaim an available bot slot. As with all departures, an empty lobby closes.

Visibility filtering happens **before** delta comparison, independently for each viewer. Removal records hide actors that leave team sight. A dead player's transition to spectator adds the newly revealed actors and tiles. Private AI state never enters a frame.

Join replies retain a full `game` for immediate late-join display; the first streamed keyframe establishes the acknowledgement baseline. Protocol 2 omits the map after the first snapshot of a seed. Protocol 1 (including joins without a protocol) remains compatible with existing tabs by sending full snapshots. Refresh existing tabs to enable protocol 3.

## Game snapshot

```text
{
  seed, status, tick, elapsed_ms, spectator, order,
  map: {width, height, tile_size, archetype, entry: {x,y,label},
        floor_tiles: [[column,row]], exterior_tiles: [[column,row]], walls: [{x,y,w,h}],
        rooms: [{x,y,w,h,label}], spawn: {x,y}},
  players: [{id,name,slot,x,y,angle,hp,ammo,reload_ms,bot}],
  enemies: [{id,x,y,angle,hp,state}], enemies_remaining, enemies_total,
  shots: [{id,x1,y1,x2,y2,team}],
  events: [{id,type,x,y,team,volume,occluded}],
  visible_tiles: [[column,row]], explored_tiles: [[column,row]]
}
```

Coordinates are world pixels. Maps are 1408×1024, with 32-pixel tiles. Four operators and 12–20 enemies spawn each round. Each connected floorplan contains 8–12 rooms, an irregular perimeter and an external staging area. For living viewers, enemy actors and hostile shot origins are filtered by shared squad vision. The blueprint remains available for navigation. A dead human gets `spectator: true`, all actors, all map tiles and all shots until the next round.

Sound event types are `shot`, `reload`, `hit`, `death` and `round_end`. Event IDs remain stable over their 200 ms retention period; clients deduplicate them. The server filters audible events by the viewer's position and supplies distance gain and wall occlusion. Nearby unseen gunfire is an intentional sound cue, not visual knowledge. Spectators receive the full sound field. Clients synthesize and spatially pan the audio; they never invent combat events from unconfirmed input.

## Engine API

`Arena.Game.new(members, seed, formation \\ "stack")`, `step(game, inputs, dt_ms \\ 50)`, `public(game, user_id \\ nil)` , `disconnect(game, user_id)` and `set_order(game, order, requester_id)`. Inputs map user IDs to atom-keyed intent maps. Internal simulation state stays in the lobby process; PubSub relays it internally to Channels, which sanitize each snapshot for its recipient before JSON serialization.
