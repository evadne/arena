# Channel protocol

Connect a Phoenix socket at `/socket` and join `lobby:CODE`, where the code is 4–12 uppercase letters or digits. Join payload: `{name}`. The server assigns a fresh `user_id` per socket and replies with `{user_id, lobby, game}`. `game` is null in staging.

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
- `snapshot`: the viewer-specific game state described below.

Status is `waiting`, `playing`, `won`, or `lost`. First arrival leads. When the leader exits, a random remaining human inherits leadership. When the final human leaves, the process terminates. A new arrival during play takes over a vacant bot slot with its existing position, health and ammunition.

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

Coordinates are world pixels. Maps are 1408×1024, with 32-pixel tiles. Four operators and 16–32 enemies spawn each round. Each connected floorplan contains 8–12 rooms, an irregular perimeter and an external staging area. For living viewers, enemy actors and hostile shot origins are filtered by shared squad vision. The blueprint remains available for navigation. A dead human gets `spectator: true`, all actors, all map tiles and all shots until the next round.

Sound event types are `shot`, `reload`, `hit`, `death` and `round_end`. Event IDs remain stable over their 200 ms retention period; clients deduplicate them. The server filters audible events by the viewer's position and supplies distance gain and wall occlusion. Nearby unseen gunfire is an intentional sound cue, not visual knowledge. Spectators receive the full sound field. Clients synthesize and spatially pan the audio; they never invent combat events from unconfirmed input.

## Engine API

`Arena.Game.new(members, seed, formation \\ "stack")`, `step(game, inputs, dt_ms \\ 50)`, `public(game, user_id \\ nil)` , `disconnect(game, user_id)` and `set_order(game, order, requester_id)`. Inputs map user IDs to atom-keyed intent maps. Internal simulation state stays in the lobby process; PubSub relays it internally to Channels, which sanitize each snapshot for its recipient before JSON serialization.
