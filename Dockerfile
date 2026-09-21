# Both image tags and multi-architecture digests were verified on Docker Hub.
ARG BUILDER_IMAGE=hexpm/elixir:1.19.5-erlang-28.3.3-debian-bookworm-20260824-slim@sha256:f17c768c30991fa399e500d1504c76e365463ec7aa8cb41c36a426d4004cf5af
ARG RUNNER_IMAGE=debian:bookworm-20260824-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile

COPY config/runtime.exs config/
RUN mix release

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 libncurses6 openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 arena

WORKDIR /app
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    PORT=4000 \
    RELEASE_DISTRIBUTION=none

COPY --from=builder --chown=arena:arena /app/_build/prod/rel/arena ./

USER arena
EXPOSE 4000
CMD ["/app/bin/arena", "start"]
