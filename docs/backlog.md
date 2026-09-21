# Backlog

## Responsiveness follow-up

Local movement forecasting, immediate gun feedback and shared-history hitscan compensation are implemented. See [movement prediction](movement-prediction.md), [hitscan design and Valve review](lag-compensation.md), and [network measurements](network-measurements.md).

- Playtest corner corrections, rapid reversals and sustained fire with multiple humans across real network paths.
- Measure whether the one-second rewind limit should be reduced; it is an initial tuning limit, not a measured requirement.
- Investigate exact input reconciliation only if bounded visual forecasting leaves objectionable corrections.
- Measure nonlinear target motion when snapshot backpressure skips frames; common simulation history and a client's wider interpolation interval can differ during stalls.
