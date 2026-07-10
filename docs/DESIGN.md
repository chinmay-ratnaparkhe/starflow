# StarFlow — Design Spec (v0.1, 2026-07-10)

Turn the Insta360 Flow 2 Pro into a star-photography system. Premium UX: **Flighty × Night Sky**
(session = flight: live status cards, timelines, landing report; immersive sky atmosphere).

## Measured hardware truths (from bench runs — NON-NEGOTIABLE design inputs)
- Third-party exposure cap: 1 s. All "long exposure" = stacking 1 s Bayer RAW subs (95–100% duty measured).
- Control law: **velocity impulses only** (setOrientation dead-bands <1.5° AND flaps the session).
  Impulse: angle = rate × time; 0.5° ≈ 0.05 rad/s × 175 ms; open-loop σ ≈ 0.15°; settle ~1 s.
- Velocity commands expire after ~2.6 s → sustained slews re-issue every ≤2.0 s.
- Velocity floor ≈ 1e-3 rad/s. Sidereal continuous impossible → step-and-shoot nudges every 90–120 s.
- Authority gate: `StateChange.trackingButtonEnabled` readable; trigger squeeze enables; auto-restores after re-docks.
- Flapping: sessions can drop/re-dock (~10 s) under idle motors; keepalive micro-pulse every 15 s during long gaps; on re-dock: re-verify pointing.
- Encoder: 4 Hz, 0.00716°/tick. DockKit pitch envelope −38.4°..+27.5°. Roll inert → software derotation.
- Re-dock may recenter gimbal (+22° pitch jump observed) → never assume pointing continuity.

## Modules & interfaces (protocols in Sources/Core/Models.swift — DO NOT change signatures; extend only)
- **Core**: Theme (design system), Models (shared types/protocols), GimbalConstants (measured values).
- **Sky** (`SkyComputing`): pure-math ephemeris — GMST, sun/moon rise-set + phase, RA/Dec→Alt/Az,
  Milky Way core position/season, twilight, tonight verdict. No network, no deps. Unit-tested vs known values.
- **Mount** (`MountControlling`): DockKit behind `#if canImport(DockKit)`; velocity-impulse controller,
  slew (re-issued ≤2 s), nudge scheduler (drift feed-forward), keepalive, authority/flap state machine.
  Logic classes (ImpulseCalculator, NudgePlanner, DriftModel) are pure Swift — unit-tested.
- **Capture** (`CaptureEngineing`): 1 s custom-exposure Bayer RAW loop (bench-proven pattern), pacing
  synchronized with mount (never capture during motion), thermal/battery backoff hooks.
- **Stacking** (`Stacking`): v1 CPU pipeline — star centroid detection, translation+rotation registration
  (procrustes on matched centroids), running mean + kappa-sigma accumulate, asinh stretch preview.
  Works on CGImage/pixel buffers. Unit-tested with synthetic gaussian starfields.
- **Modes**: ShotMode registry — MilkyWayStack, StarTrails, Lunar, ISSPass, MotionTimelapse, Cityscape,
  Aurora, MeteorShower, Conjunction. Each: recipe (exposure/ISO/cadence/gimbal plan), feasibility gate
  (city/dark sky, season, altitude), tutorial content, expectation copy.
- **UI**: Tonight (verdict + shot cards + sky strip), Session (Flighty-style live: phase timeline,
  integration meter, telemetry chips, guardian alerts, landing report), Onboarding (intro pager,
  gimbal setup incl. trigger/authority teaching, permissions), NightMode red theme toggle, Settings.

## UX principles
- Tonight screen is the front door: one verdict headline, 3 shot cards, one "Set up this shot" button each.
- Session screen = boarding pass + flight tracker: phases (Connect → Aim → Calibrate → Capture → Develop),
  live integration minutes (tabular numerals), sub count, gimbal battery, phone battery/thermal, star count.
- Landing report: stacked result, session stats, share card. Honest expectation copy everywhere.
- Red night mode (single toggle, persists): pure red-on-black palette swap.
- Tutorials: every mode has a 3–5 step intro (what/why/how + expectation image slot); first-run intro pager.

## Edge cases the session engine MUST handle (state machine)
authority=false at start (guided trigger prompt) · mid-session undock (debounce 15 s, pause capture,
auto-resume on re-dock, forced re-aim check) · re-dock recenter (pointing invalidated) · thermal
.serious (cadence backoff) / .critical (graceful stop + save) · battery floor 30% (warn) 20% (stop+save) ·
storage low · zenith/pitch-envelope target refusal · permission denials · gimbal battery low ·
app backgrounded (zero velocity, pause, resume state) · clouds/no-stars detected (advise) ·
Free Tilt collar warning · cable-wrap budget (net pan tracking ±360°).

## Testing (CI, no hardware)
- Build: device archive (unsigned IPA artifact) — must stay green.
- Test: `xcodebuild test` on iOS Simulator — SkyEngine vs known ephemeris values (±0.5°/±2 min),
  stacker on synthetic starfields (alignment residual <0.5 px), NudgePlanner drift math,
  session state machine transitions (mock mount), mode feasibility gates.

## Workflow build rounds
1. Foundation: all modules compile + tests green; Tonight/Session/Onboarding functional with mock data path.
2. Features & stability: full edge-case matrix, settings, storage manager, more modes, review pass.
3. Content & polish: tutorials/intros for all modes, learn/glossary, animation/haptics polish, a11y, final review.
