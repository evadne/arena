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
