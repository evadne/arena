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
