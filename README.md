# BREACH

**Play: [evadne-arena.fly.dev](https://evadne-arena.fly.dev)** — one Fly.io Machine in London (`lhr`).

A browser-based, real-time cooperative room-clearing prototype. One to four humans, four operators, and 12–20 hostiles. Phoenix Channels carry input and snapshots; each lobby runs its own authoritative Elixir simulation.

## Run

Requires Elixir 1.19+ and Erlang/OTP 28. The checked-in `.tool-versions` selects installed compatible versions. No database, Node build step, or external service is required.

```sh
mix deps.get
mix phx.server
```

Open **http://localhost:4000**. Enter a callsign and choose **Create lobby**, or use **Join lobby** with an invite code. The lobby lists each squad member above the formation choices and **Deploy Squad** button; chat sits below deployment. Share the invite link or lobby code with teammates, or have them scan the QR code. An invitation makes joining the primary action. A keyboard and mouse are needed to play. QR codes are generated locally and disappear during gameplay. The first connected player leads and can deploy solo or with friends; AI fills the remaining slots in the four-person squad. Guests see who will deploy and can choose an empty slot.

The landing page requests fresh facility geometry from the backend on every load and shows a slowly rotating 3D preview. Reduced-motion preferences stop the rotation. This is an independent preview; the shared mission map is generated when the leader deploys.

For another machine on your LAN, use the host machine's LAN address and port 4000 in the invitation. `localhost` links only work on the same machine. The development server binds all interfaces. Fly.io deployment is configured in [fly.toml](fly.toml); see the [deployment guide](docs/deployment.md).

## Controls

- Open **Controls** to change movement, reload and squad-order keys. Select a binding, press a key and choose **Save controls**. Bindings are saved in this browser's Local Storage; defaults are listed below. Existing EDSF preferences are retained on upgrade. The dialog stops your input but does not pause the mission.
- **WASD** movement by default. Bindings use physical keyboard positions.
- **Mouse** aim. Your laser stays visible and stops at walls.
- **Left mouse button** fire; hold for repeated shots.
- **R** reload a 20-round magazine. Reserve ammunition is unlimited. An amber progress ring and RELOAD label mark reloading operators.
- **1 / Hold**, **2 / Form up**, **3 / Aggro**, **4 / Auto** give the AI teammates general orders. Any living human can issue orders; bots defend themselves and reposition under fire.
- Chat is available in staging and after the round, and disabled during missions. Sound starts after your first interaction and can be muted in the interface.

Each mission grows a connected, irregular 8–12-room house, office or workshop with an exterior staging area and marked entry. All walls remain solid; destructible terrain is not included.

Your movement and gun feedback respond locally. Shared server history compensates hitscan timing against displayed targets; damage stays consistent across the squad. Audio is generated locally, with stereo positioning and distance attenuation.

Living operators share current line of sight. The blueprint remains visible as a navigation aid; unexplored and out-of-sight areas are dimmed. For living operators, hostiles are only transmitted while visible. When you die, you become a spectator with full visibility of all actors until the next round. Walls block movement, vision, and hitscan shots. There is no friendly fire. Clear every hostile to win; losing all four operators ends the mission. The leader can then return to staging for a newly generated map. Bots have reaction delays and imperfect aim; enemies only pursue seen or heard threats, with expiring memory.

AI teammates draw unique human names from a shared lobby repertoire (for example, Jason (AI)); names stay consistent when deploying. Each connected member can select a free squad slot in staging. The leader can transfer command to another connected member from the lobby. If the leader disconnects, a randomly selected remaining member leads. A disconnected operator becomes a bot, and a new arrival can take over a free bot slot during play, retaining its position and condition.

## Verification

```sh
mix test
mix format --check-formatted
# With the server running; requires Node 24:
node scripts/smoke.mjs
node --test scripts/*.test.mjs
ARENA_PROTOCOL=3 node scripts/network_probe.mjs
# Controlled input/frame delays against a local server:
ARENA_URL=http://localhost:4000 node scripts/responsiveness_probe.mjs
```

See [architecture and design sources](docs/architecture.md) the [wire protocol](docs/protocol.md), and [measured network results](docs/network-measurements.md). The [movement prediction investigation](docs/movement-prediction.md) describes the enabled local forecasting and reconciliation.

See the [hitscan design and Valve review](docs/lag-compensation.md) and [remaining playtest work](docs/backlog.md).

## Deployment notes and limits

This is a desktop-keyboard prototype, with in-memory lobbies on one BEAM node. Server restarts discard sessions; lobbies close when their last human leaves. It does not include account authentication, persistent progress, distributed lobby ownership, matchmaking, or a production abuse-prevention layer. Room codes are invitations, not secrets. The Phoenix browser client is vendored with its MIT license in `priv/static/assets`; update it alongside the locked Phoenix dependency.

For a production build, provide a long random `SECRET_KEY_BASE` and your public `HOST` (and optionally `PORT`, default 4000):

```sh
MIX_ENV=prod mix compile
MIX_ENV=prod mix release
SECRET_KEY_BASE=... HOST=your-host.example PORT=4000 _build/prod/rel/arena/bin/arena start
```

Put HTTPS/WSS termination in front of the release. Production origin checks use `HOST`; the development origin check is permissive for LAN play. Use `mix phx.gen.secret` to generate a secret. This is an original prototype inspired by the room-clearing genre, not an official Door Kickers product.
