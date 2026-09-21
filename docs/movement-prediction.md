# Local movement prediction

The local living operator now uses bounded visual forecasting, enabled in gameplay. Other actors retain the 100 ms interpolation buffer. The simulation remains authoritative at 20 Hz; held direction refreshes at 30 Hz and changes send immediately.

`movement_prediction.mjs` reconstructs collision from the complete transmitted floor tile set, with solid out-of-bounds cells. Its radius-10 circle, exact tangency, diagonal normalisation, 140 px/s speed, displacement substeps and X-then-Y movement match `Arena.Game.Map`. The Node suite compares positions directly against fixtures produced by the current Elixir implementation across three generated maps.

Snapshots include the actual consumed local direction and a unique round identity. A one-second Channel ping measures round-trip delay. Forecasting anchors the snapshot on the least-delayed recent arrival timeline, allowing the measured input/snapshot round trip plus half a simulation tick. Local direction transitions apply at their actual timestamps; repeated input packets grant no movement time. Forecast intervals are at most 50 ms and a partial interval never feeds into another render. This is an estimate for the existing sample-and-hold server, not exact command replay.

Forecasting stops at a horizon of `max(200, RTT + 100)` ms beyond the authoritative anchor, capped at 400 ms. The added margin was required by the controlled 240 ms RTT test; a fixed 200 ms cap delayed fresh local input. Small corrections (up to 24 px) decay over 80 ms only when the complete radius-10 path fits. Large or blocked corrections snap. Death, end of round, new round, identity change and disconnect reset prediction; blur and hidden tabs suspend it. Aim and the laser use the displayed local origin. Vision, health and mission outcomes remain authoritative.

`node --test scripts/movement_prediction.test.mjs` checks collision parity, immediate response at 0/60/120/240 ms RTT, stops and reversals, identical results at 30/60/144 Hz, bounded stalls and lifecycle resets. It invokes `mix run --no-start scripts/movement_fixtures.exs`, so both toolchains must be installed.

A future tick-addressed input protocol could provide exact reconciliation, but changing simulation input semantics is unnecessary for this first responsiveness improvement. Under severe delay the bounded forecast still holds or corrects; it cannot hide an indefinitely stalled server.
