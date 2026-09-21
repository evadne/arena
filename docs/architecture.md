# Architecture and reference notes

Breach is a cooperative browser prototype with an authoritative Phoenix server. The browser sends intent (movement, aim, firing and reload); it never supplies actor positions, health, hits or enemy decisions. Phoenix Channels carry lobby actions and snapshots. Phoenix PubSub distributes text chat and lobby/game updates only within the joined lobby topic. Chat is disabled during an active mission.

## Relationship to evadne/snake

The reference was inspected on GitHub, rather than assumed to be installed locally. In [SnakeWeb.SnakeLive](https://github.com/evadne/snake/blob/master/apps/snake_web/lib/snake_web/live/snake_live.ex), creating a game redirects to its identifier, and mounting an existing identifier loads the same game backend. Connected visitors subscribe to that game's backend, a game-specific Phoenix PubSub topic, and Presence. Consequently, a shareable game identifier joins existing state while other identifiers remain isolated.

[Snake.Game.Backend.HordeServer](https://github.com/evadne/snake/blob/master/apps/snake/lib/snake/game/backend/horde_server.ex) starts or locates a GenServer by game identifier and uses that identifier as its registry key. [Snake.Game.State](https://github.com/evadne/snake/blob/master/apps/snake/lib/snake/game/backend/state.ex) owns the board, votes and ticking timer. Snake uses LiveView and provides multiple backend implementations; this prototype adapts its identity/isolation pattern rather than copying its transport or distributed deployment.

Breach uses a local Registry and DynamicSupervisor to locate or create one authoritative lobby GenServer per uppercase lobby code. Each code owns its membership, leader, formation, text history, input buffer and game. A Channels client joins `lobby:CODE`; all actions resolve to that lobby process. This serializes concurrent joins and leadership changes. Four human slots are available, and mission launch fills vacant slots with AI teammates. The first human becomes leader; leadership transfer is authorized against the current leader and an existing member. A departed leader yields leadership to a randomly selected remaining human. A departed operator is replaced by a bot during play. Once the last human leaves, the lobby process terminates immediately and discards the mission.

This is intentionally an in-memory, single-node prototype. Lobby identity is shareable, but it is not an account or a private-room authentication boundary. A restart discards live state. A distributed production version would need ownership coordination or partition routing before running multiple independent registries.

## Simulation and visibility

The server advances the simulation at fixed intervals and broadcasts sanitized snapshots. A seeded generator constructs irregular house or premises floorplans with 8–12 connected, navigable rooms and a distinct squad entry. Room dimensions and openings vary; solid exterior and interior walls define the traversable footprint. Actor movement, navigation, line of sight and hitscan all respect the same wall geometry. Four operators face 16–32 enemies at launch (four to eight times the original hostile count); the public enemy array includes only enemies currently visible to the squad, while `enemies_remaining` is the live mission counter and `enemies_total` records the initial force size. Therefore the array is not a complete enemy census.

Team vision is shared for cooperative usability. The map blueprint remains visible, unexplored space is dimmed, and current visibility is distinguished from explored space. For living operators, hidden enemies and private decision memory are omitted from public snapshots. A dead human becomes a spectator with a personalized fully revealed battlefield while surviving teammates continue playing. At mission completion, only the leader can reset the squad to the lobby and launch the next mission. Aim lasers stop at walls. Clients synthesize spatial gunfire and reload sounds using WebAudio and server events; no downloaded sound assets are required. These are prototype choices inspired by Door Kickers, not a claim of exact reproduction of its proprietary rules.

KillHouse's [Door Kickers Alpha 4 notes](https://inthekillhouse.com/door-kickers-alpha-4/) describe visible trooper FOV bounds, patrol/investigation behavior, and a fix for corner cases where a unit could shoot an opponent it could not see. Those establish useful visibility and fairness targets for this implementation.

## Fair AI design

Daniel Brewer's GDC 2012 [Building Better Baddies slides](https://media.gdcvault.com/gdc2012/slides/Summit_AI/Brewer_Daniel_D2AIPostMortem.pdf), especially pages 3–5, describe cone-based sight, attenuated hearing, remembered positions and delayed reactions. These are primary-source slide notes, not a transcript. We apply the principles as the following design requirements:

- A guard initially patrols or watches its assigned region. It does not receive every human's current coordinates as target knowledge.
- Sight acquisition requires range, facing and unobstructed geometry. A reaction delay gives the player a readable opportunity to respond.
- Audible gunfire may provide an investigation location; it does not justify following a silently moving target through walls.
- Stronger enemy aggression follows actual sightings and audible gunfire. When visual contact breaks, pursuit follows the last observed position for a limited time, then searches or returns to patrol; increased aggression does not provide hidden player coordinates.
- All AI travels continuously through navigable space. No teleporting, wall penetration or hidden relocation is allowed.
- Friendly bots navigate around walls and engage visible targets with the same weapon and reload constraints. Their aim is deliberately imperfect, so human operators retain a meaningful combat role. Any living human may issue Hold, Form up, Aggro or Auto orders during a mission; the shared order is broadcast to the squad. Spectators cannot issue orders. Hold keeps bots at their assigned positions, Form up gathers them around the requesting operator, Aggro advances them through the known premises, and Auto combines normal squad support with autonomous room clearing when no human survives.

The implementation is a compact state machine suitable for this prototype, not the behavior-tree, coordination or collision-avoidance system demonstrated by the GDC speaker. See the engine tests for specific invariants and `docs/protocol.md` for the transport contract.

## Verification

`mix test` checks engine and lobby behavior. With the server running, `node scripts/smoke.mjs` exercises real Phoenix WebSocket connections, lobby isolation, leadership permissions, capacity, formation, chat, launch, movement against generated geometry, wall-clipped firing/reload, shared squad orders, disconnect replacement, combat-chat restrictions, reset permissions, solo launch, late join and immediate empty-lobby cleanup. It requires Node 22 or later for the built-in WebSocket client; it installs no JavaScript dependencies. Override the target using `ARENA_URL=http://localhost:4000`.
