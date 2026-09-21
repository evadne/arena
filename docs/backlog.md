# Backlog

## Controls and staging usability

Execute in this order; keep the README aligned with the shipped behaviour.

- [x] Audit README claims; replace the movement preset selector with a keybindings dialog saved to Local Storage.
- [x] Audit confusing UI labels, states and actions; make the next step clear for hosts, guests and reconnecting players.
- [x] Show reloading operators with a visible circular indicator.
- [x] Remove standby fireteam and inactive chat from the initial page.
- [x] Generate a fresh landing-page map on the backend for every load; display a very slowly rotating angled 3D preview.
- [x] Integrate a vertical fireteam list above Deploy Squad in the lobby.
- [x] Place chat below the fireteam list and deployment controls.

Validation: 61 server tests, 38 client tests and the live socket smoke suite pass. Browser checks cover saved bindings and duplicate-key rejection, desktop and narrow-screen staging, invitations, peer chat, leadership transfer, deployment, keyboard squad orders and the visible reload ring. Production deployment is separate from this local usability work.

## Responsiveness follow-up

Local movement forecasting, immediate gun feedback and shared-history hitscan compensation are implemented. See [movement prediction](movement-prediction.md), [hitscan design and Valve review](lag-compensation.md), and [network measurements](network-measurements.md).

- Playtest corner corrections, rapid reversals and sustained fire with multiple humans across real network paths.
- Measure whether the one-second rewind limit should be reduced; it is an initial tuning limit, not a measured requirement.
- Investigate exact input reconciliation only if bounded visual forecasting leaves objectionable corrections.
- Measure nonlinear target motion when snapshot backpressure skips frames; common simulation history and a client's wider interpolation interval can differ during stalls.
