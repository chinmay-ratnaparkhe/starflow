# StarFlow Build Campaign (10 features; each: build workflow → 2 review agents → 2× stability check via CI + targeted tests; math via deep-research where flagged)

GOALS: (G1) First clear-night Milky Way image that wows. (G2) Zero-hands sessions: aim, track, stack, deliver. (G3) Honest UX — never fake, always explain. (G4) Every hardware claim bench-verified.

| # | Feature | Notes | Status |
|---|---------|-------|--------|
| 0 | Color stacking + orientation (in flight wf_814f1db7) | merge when green | building |
| 1 | Plate-solve core: triangle-hash star matcher + embedded bright-star DB (~mag 5.5), solve on 20–30° tele crop first | MATH: verify hash geometry via deep-research | next |
| 2 | Plate-solve GoTo: slew → shoot → solve → correct loop (0.25° class), replaces compass after first solve | crown jewel | |
| 3 | Star-color calibration (SPCC-lite): per-channel gains from matched catalog stars | | |
| 4 | Panorama planner + sequencer: 1×4 row of tracked panels, per-panel stacks | | |
| 5 | Timelapse video export (AVAssetWriter, share sheet) | assembler exists | |
| 6 | Offline event calendar + rarity alerts: meteor showers (IMO-derived, clean-room), eclipse catalog, core-season | | |
| 7 | Cityscape dual-phase v1: bracketed static foreground + sky stack + luminance mask composite | | |
| 8 | Session resume + multi-night project stacking (re-register to saved stack) | | |
| 9 | Landing-report share cards (Flighty-style branded stats image) | | |
| 10 | Focus assist: star-FWHM sweep UI on live frames | | |

RULES: never break tested public APIs; simulator tests stay green; SIMULATED badge honesty; device-only code behind #if; each feature merges only after 2 independent review agents pass it and CI green twice (initial + post-review-fix re-run).
