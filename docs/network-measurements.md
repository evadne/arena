# Network verification — 21 September 2026

Application build: `d19c7d3`. Fly image: `deployment-01M32MP309DYWMQW0P4F9NSXGR`. One healthy shared-CPU Machine with 512 MB in `lhr`.

Two WebSocket probes joined the same live lobby concurrently for 12 seconds, one using legacy full snapshots and one using acknowledged deltas. Both observed the same simulation and shared squad vision. The probe counts incoming snapshot/frame JSON bytes, including the initial keyframe but excluding WebSocket/TLS/IP framing, control messages and client traffic.

| Measurement | Legacy protocol 1 | Delta protocol 3 |
| --- | ---: | ---: |
| Delivered snapshots | 238 | 235 |
| Simulation ticks covered | 235 | 234 |
| Snapshot traffic | 275,277 B/s | 9,570 B/s |
| Median message size | 13,881 B | 407 B |
| p95 message size | 14,417 B | 737 B |
| Median arrival interval | 50.6 ms | 50.7 ms |
| p95 arrival interval | 62.8 ms | 60.0 ms |
| Maximum arrival gap | 92.8 ms | 85.1 ms |
| Median heartbeat round trip | 33.6 ms | 31.7 ms |

This sample reduced state traffic by 96.5%, while retaining approximately 20 updates/second. Different rooms, visibility, combat intensity and network conditions will change the numbers. The result demonstrates the bandwidth reduction; it does not establish that the previous network jitter has disappeared. The earlier path sample had a 64.4 ms median RTT and 271.4 ms maximum inter-snapshot gap, so network conditions also changed between measurements.

A separate local probe delayed every acknowledgement by 300 ms. It received 17 frames over five seconds, covering 93 simulation ticks, at a median interval of 301.8 ms. It caught up to recent state without accumulating a frame backlog. Integration tests additionally submit 100 unacknowledged updates and verify that only the latest tick is sent when the acknowledgement arrives. Tests verify viewer-specific removals, spectator reveals, resync, old acknowledgements/timeouts, round resets and the 50 ms minimum send interval.

Verification: 51 ExUnit tests, 17 Node decoder/interpolation tests, full local and production WebSocket smoke suites, and local/production browser checks with no console errors.

## Reproduce

Run these in two terminals at the same time, using the same fresh code and target:

```sh
ARENA_URL=https://evadne-arena.fly.dev ARENA_PROTOCOL=1 PROBE_CODE=FRESHCODE PROBE_SECONDS=12 node scripts/network_probe.mjs
ARENA_URL=https://evadne-arena.fly.dev ARENA_PROTOCOL=3 PROBE_CODE=FRESHCODE PROBE_SECONDS=12 node scripts/network_probe.mjs
```

The first arrival creates and starts the operation; the second joins it. Each probe issues Aggro and leaves automatically. To emulate slow acknowledgement processing:

```sh
ARENA_PROTOCOL=3 PROBE_ACK_DELAY_MS=300 PROBE_SECONDS=5 node scripts/network_probe.mjs
```

## Movement regression follow-up

The initial stop-and-wait policy limited delivery to one frame per acknowledgement round trip. It has been replaced by a four-frame window, still capped at 20 Hz. Deltas chain against the previous sent snapshot over reliable ordered WebSockets, and cumulative acknowledgements free window capacity. Beyond the window, only the newest pending simulation state is kept. Resync and visibility filtering are preserved.

A six-second local test with every acknowledgement deliberately delayed 120 ms delivered 118 frames covering 116 simulation ticks. Median arrival spacing was 51.0 ms, p95 52.3 ms, maximum 54.8 ms, with no gaps over 100 ms. This verifies that acknowledgement delay no longer forces stop-and-wait cadence under those conditions. Earlier follow-up probes ran while the Mac had very high system load, so they are not a controlled before/after performance comparison.

The living local actor now has a separate 50 ms interpolation timeline; remote actors retain 100 ms. Movement direction changes send immediately alongside the regular 30 Hz refresh. Aim uses the displayed local origin, and hidden tabs skip canvas drawing. This is a responsiveness correction, not movement prediction or server rewind. Verification now includes 52 server tests and 24 client tests plus the live socket smoke test.

Fly capacity was increased to two shared CPUs and 1 GB RAM on the same single London Machine. `fly.toml` explicitly persists `shared-cpu-2x` for subsequent releases.

## Local machine responsiveness investigation

A fresh eight-second baseline probe at `11b3aff` measured 157 frames / 156 ticks locally (51.0 ms median arrival, 0.3 ms median RTT), and 157 frames / 155 ticks against Fly (51.0 ms median arrival, 5.2 ms median RTT). Neither sample had a gap over 100 ms. This argues against insufficient tick delivery on this sampled path; it does not exclude intermittent overload or other network paths. The code still imposed a network round trip before local movement and evaluated shots against current targets while drawing remote actors 100 ms in the past.

`scripts/responsiveness_probe.mjs` exercises actual local Phoenix Channels. It delays both outgoing inputs and incoming frames, preserves WebSocket ordering, sends normal keepalives/ACKs, and samples the new predictor alongside the previous 50 ms local interpolation at 60 Hz. The measurement is first displacement greater than one world pixel, not an input-to-photon browser measurement. Each trial moves for 400 ms, releases, and observes another 500 ms.

A run with up to 20 ms additional jitter on each leg produced:

| Added base RTT | Predicted first movement | Previous interpolation | Largest reconciliation difference |
| --- | ---: | ---: | ---: |
| 0 ms | 16.2 ms | 50.2 ms | 5.39 px |
| 60 ms | 17.6 ms | 103.7 ms | 7.00 px |
| 120 ms | 17.6 ms | 151.1 ms | 8.80 px |
| 240 ms | 16.8 ms | 336.8 ms | 6.79 px |

These are individual controlled trials, not population percentiles. Largest differences are between predicted and corrected logical positions before smoothing. The first 200 ms fixed forecast horizon failed the 240 ms RTT trial; the tested version uses `max(200, RTT + 100)` with a 400 ms hard cap. All predicted samples must pass the collision geometry check. Unit tests separately cover long stalls, rapid reversals and different render rates.

Reproduce against the local development instance:

```sh
ARENA_URL=http://127.0.0.1:4107 PROBE_JITTER_MS=20 node scripts/responsiveness_probe.mjs
```

The changed build has not been deployed to Fly. Production baseline measurements and local change verification must not be conflated.
