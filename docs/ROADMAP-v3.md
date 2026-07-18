# StarFlow Build Campaign — COMPLETE 2026-07-18: 10/10 features certified (dual-review + 2x CI green each)
# (10 features; each: build workflow → 2 review agents → 2× stability check via CI + targeted tests; math via deep-research where flagged)

GOALS: (G1) First clear-night Milky Way image that wows. (G2) Zero-hands sessions: aim, track, stack, deliver. (G3) Honest UX — never fake, always explain. (G4) Every hardware claim bench-verified.

| # | Feature (BASICS-FIRST ORDER per owner 2026-07-18) | Notes | Status |
|---|---------|-------|--------|
| 0 | Color stacking + orientation (in flight wf_814f1db7) | merged | CERTIFIED 2x-green |
| 1 | Sky-condition detection: cloud detector from live frames (star-count + background trend — star detection exists), city/Bortle sanity from measured sky background; Tonight verdict + in-session advice ("clouds — pause?") | basic honesty | CERTIFIED 2x-green |
| 2 | Focus assist: star-FWHM live meter + tap-to-refocus sweep | sharp stars = everything | CERTIFIED 2x-green |
| 3 | Milky Way session polish: exposure auto-tune from measured sky, framing guidance overlay (core position in FOV), live depth meter, cloud-time budget fix (skips extend the session, capped 2×) | THE core experience | CERTIFIED 2x-green |
| 4 | Plate-solve core: triangle-hash matcher + bright-star DB, tele-crop first | MATH via deep-research | CERTIFIED 2x-green |
| 5 | Plate-solve GoTo: slew→shoot→solve→correct (0.25°) | crown jewel; perfects MW aim | CERTIFIED 2x-green |
| 6 | Star-color calibration (SPCC-lite) | | CERTIFIED 2x-green |
| 7 | Offline event calendar + rarity alerts (clean-room data) | | CERTIFIED 2x-green |
| 8 | Timelapse video export | assembler exists | CERTIFIED 2x-green |
| 9 | Landing-report share cards | | CERTIFIED 2x-green |
| 10 | Cityscape dual-phase v1 | | CERTIFIED 2x-green |
| later | Panorama sequencer; multi-night project stacking | after the basics earn trust | |

RULES: never break tested public APIs; simulator tests stay green; SIMULATED badge honesty; device-only code behind #if; each feature merges only after 2 independent review agents pass it and CI green twice (initial + post-review-fix re-run).
