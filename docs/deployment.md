# Fly.io deployment

Live application: [evadne-arena.fly.dev](https://evadne-arena.fly.dev). The initial deployment was verified with one healthy application Machine in `lhr` and the full WebSocket smoke suite.

The production image is a Phoenix release built with Elixir 1.19.5 and Erlang/OTP 28.3.3 on Debian Bookworm. The smaller runtime image runs as an unprivileged user. Browser assets are already in `priv/static`; no Node build, database, volume, or distributed Erlang cluster is required.

`fly.toml` targets one Machine with two shared CPUs and 1 GB RAM in London (`lhr`). The app name is `evadne-arena` in the personal organization. To deploy another instance, change both `app` and `[env].HOST`. The hostname must match the browser's HTTPS origin for Phoenix Channels.

## First deployment

Authenticate to the intended Fly.io account and create the app in the intended organization:

```sh
fly auth login
fly apps create evadne-arena --org YOUR_ORGANIZATION
fly config validate --strict
```

Generate the Phoenix secret directly into Fly's standard-input import. This avoids putting the value in shell history, command arguments, or repository files. The Elixir command prints only into the pipe; do not run it separately or enable shell tracing around secrets.

```sh
elixir -e 'IO.puts("SECRET_KEY_BASE=" <> Base.encode64(:crypto.strong_rand_bytes(64)))' | fly secrets import --stage --app evadne-arena
fly deploy --remote-only --ha=false --app evadne-arena
fly scale count 1 --region lhr --app evadne-arena
```

The remote builder does not require a local Docker daemon. `--ha=false` prevents Fly from provisioning an extra spare Machine. Keep the explicit scale count at one, including after any manual operations. A single live instance is necessary because the lobby registry, game state, and PubSub are in memory on that instance. Fly documents these controls in [app availability](https://fly.io/docs/apps/app-availability/) and [scaling Machine count](https://fly.io/docs/launch/scale-count/).

## Verify the release

```sh
fly status --app evadne-arena
fly checks list --app evadne-arena
fly machine list --app evadne-arena
curl --fail https://evadne-arena.fly.dev/health
```

Confirm exactly one application Machine is running in `lhr`, with the configured two shared CPUs and 1 GB memory. Open [the application](https://evadne-arena.fly.dev) in two browser sessions, join the same lobby, and verify team membership, lobby chat, game start, movement, and a second round. A second distinct lobby should remain isolated. The `/health` check verifies HTTP availability; the two-session check verifies Phoenix WebSocket behavior.

## Subsequent releases and operations

```sh
fly deploy --remote-only --ha=false --app evadne-arena
fly scale count 1 --region lhr --app evadne-arena
fly logs --app evadne-arena
```

Autostop is disabled, so idle lobbies keep their running server. The immediate deployment strategy intentionally replaces the single server without running a second lobby owner. Deployments, crashes, and restarts end all active in-memory lobbies and games. Plan updates between sessions; persistent recovery and horizontal scaling are outside this prototype's design.

`SECRET_KEY_BASE` is the only required secret. `HOST`, `PORT=4000`, and disabled release distribution are ordinary environment settings in `fly.toml`. Fly terminates HTTPS and proxies HTTP/WebSockets to port 4000. No extra public Erlang ports are exposed. See [Fly configuration](https://fly.io/docs/reference/configuration/) and [secrets](https://fly.io/docs/apps/secrets/) for the platform settings.

## Local image verification

When Docker is running, build and boot the same production image with a temporary secret in the environment:

```sh
docker build -t arena:local .
export SECRET_KEY_BASE="$(elixir -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(64)))')"
docker run --rm -p 4000:4000 -e SECRET_KEY_BASE -e HOST=localhost arena:local
```

In another terminal, check `curl --fail http://localhost:4000/health`. The production socket origin configuration assumes HTTPS, so use the normal development server for browser gameplay on plain localhost, or provide a local HTTPS proxy for a complete production-origin test. Run `unset SECRET_KEY_BASE` after stopping the container.

## Responsiveness release — 21 September 2026

`flyctl apps list` confirmed `evadne-arena` in the personal organisation. Strict configuration validation passed and `SECRET_KEY_BASE` is deployed. The production target remains one Machine, `84ed543c26ed78`, in `lhr`, using `shared-cpu-2x:1024MB`.

The responsiveness changes at source commit `c01c8c02740475351fd8c6b13ae48a0e55c89fc3` were built remotely with flyctl and pushed using `--build-only --push`. The 35 MB image includes the production Elixir release and carries the source revision as an OCI label:

- Tag: `registry.fly.io/evadne-arena:commit-c01c8c027404`
- Immutable image: `registry.fly.io/evadne-arena@sha256:dddc2e6acd5df59b8d48b4141a2f93987da6748630cc1be3db471edf0287ce08`

The image was deployed with operator approval at 22:36 UTC as Fly release 7. Machine `84ed543c26ed78` runs the exact digest above; exactly one application Machine remains in London with its health check passing and public `/health` returning `ok`. Source verification before preparation passed 60 server tests, 35 client tests and the local socket smoke suite.

All production Phoenix Channels smoke checks passed after rollout, including lobby isolation, chat, leadership, launch, movement, shooting, reloads, disconnect replacement, reset and late join. A twelve-second protocol 3 probe received 236 frames, with median arrival interval 51.0 ms, maximum gap 55.4 ms and no gaps above 100 ms; median measured RTT was 4.7 ms. This short sample verifies delivery from this machine, not sustained latency or subjective play feel for every player.

Redeploy the same image without rebuilding:

```sh
flyctl deploy --app evadne-arena --ha=false \
  --image registry.fly.io/evadne-arena@sha256:dddc2e6acd5df59b8d48b4141a2f93987da6748630cc1be3db471edf0287ce08
flyctl machine list --app evadne-arena
flyctl checks list --app evadne-arena
ARENA_URL=https://evadne-arena.fly.dev node scripts/smoke.mjs
ARENA_URL=https://evadne-arena.fly.dev ARENA_PROTOCOL=3 node scripts/network_probe.mjs
```

The configured immediate deployment replaces the sole lobby owner and ends active in-memory sessions. Refresh browser tabs after rollout to load the new prediction and weapon-feedback code.

If rollback is required, the previously running image is:

```sh
flyctl deploy --app evadne-arena --ha=false \
  --image registry.fly.io/evadne-arena:deployment-01M32PEBVC2K3CQE1W1G8Q2BCY
```
