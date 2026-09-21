# Backlog

## Controls and staging usability

Execute in this order; keep the README aligned with the shipped behaviour.

- [x] Audit README claims; replace the movement preset selector with a keybindings dialog saved to Local Storage.
- [x] Audit confusing UI labels, states and actions; make the next step clear for hosts, guests and reconnecting players.
- [ ] Show reloading operators with a visible circular indicator.
- [ ] Remove standby fireteam and inactive chat from the initial page.
- [ ] Generate a fresh landing-page map on the backend for every load; display a very slowly rotating angled 3D preview.
- [ ] Integrate a vertical fireteam list above Deploy Squad in the lobby.
- [ ] Place chat below the fireteam list and deployment controls.

Verify saved controls, mission input, landing/loading states, lobby leadership, responsive layouts and the reload indicator before closing these items.

## Responsiveness follow-up

Local movement forecasting, immediate gun feedback and shared-history hitscan compensation are implemented. See [movement prediction](movement-prediction.md), [hitscan design and Valve review](lag-compensation.md), and [network measurements](network-measurements.md).

- Playtest corner corrections, rapid reversals and sustained fire with multiple humans across real network paths.
- Measure whether the one-second rewind limit should be reduced; it is an initial tuning limit, not a measured requirement.
- Investigate exact input reconciliation only if bounded visual forecasting leaves objectionable corrections.
- Measure nonlinear target motion when snapshot backpressure skips frames; common simulation history and a client's wider interpolation interval can differ during stalls.
