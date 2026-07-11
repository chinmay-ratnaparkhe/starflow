# StarFlow

Turn an iPhone docked on an **Insta360 Flow 2 Pro** into a star-photography system.

StarFlow drives the gimbal over Apple's **DockKit**, captures 1-second night-sky
exposures with a custom AVFoundation pipeline, registers and stacks them live on the
CPU, and wraps the whole session in a Flighty-style flight tracker: phases, live
integration minutes, guardian alerts, and a landing report. First-party frameworks
only — no third-party dependencies, no network calls.

- **Platform:** iOS 18+, SwiftUI, Swift 5.10
- **Hardware:** iPhone + Insta360 Flow 2 Pro (the whole app also runs in the
  simulator against a simulated gimbal and a synthetic starfield)
- **Version:** 0.2.0

## The measured-hardware story

Everything about how StarFlow moves the gimbal and paces the camera comes from bench
runs against a real Flow 2 Pro (firmware 5.50.80) — not from the DockKit
documentation. Two constraints shape the entire design:

1. **Third-party apps cannot expose longer than 1 second.** "Long exposure" therefore
   means stacking 1 s subs. The bench-proven capture loop achieves 1.00–1.05 s per
   frame (95–100 % duty), so integration time is roughly wall-clock time.
2. **The gimbal only responds usefully to velocity impulses.** `setOrientation`
   dead-bands below ~1.5° and destabilizes the session, so every move is
   `angle = rate × time`. Continuous sidereal tracking is impossible — the velocity
   floor is ~27× sidereal rate — so StarFlow tracks the sky by *step-and-shoot*:
   park, stack, nudge, repeat.

The measured constants live in `Sources/Core/Models.swift` (`GimbalConstants`) and
are treated as non-negotiable design inputs:

| Constant | Measured value | Consequence in code |
| --- | --- | --- |
| Exposure cap (third-party) | 1 s hard | `CaptureRecipe` clamps exposure; modes stack subs |
| Capture duty | 1.00–1.05 s/frame | Integration ≈ wall clock; sequential capture chained from `didFinishCapture` |
| Control law | velocity impulses only | `MountService` never calls `setOrientation` |
| Impulse anchor | 0.5° ≈ 0.05 rad/s × 175 ms | `NudgePlanner.impulse` solver |
| Open-loop impulse accuracy | σ ≈ 0.15° | Calibration settle check; closed-loop slew corrects residuals |
| Velocity command lifetime | ~2.6 s firmware watchdog | Sustained slews re-issue every 0.2 s (budget ≤ 2.0 s) |
| Velocity floor | ~2×10⁻³ rad/s | Below it motors don't move; impulse rates are clamped above it |
| Sidereal drift (worst case) | 0.2507°/min | Framing nudge of ~0.5° every ~110 s |
| Encoder feed | 4 Hz, 0.00716°/tick | Settle detection needs 3 fresh samples below threshold |
| Pitch envelope | −38.4° … +27.5° | Out-of-envelope targets are refused, never clamped mid-session |
| Roll axis | inert to commands | Field derotation must happen in software (roadmap) |
| Motor authority | trigger squeeze → `trackingButtonEnabled` | Session engine gates on authority, guides the user to squeeze |
| Undock/re-dock ("flap") | recovery ~10 s; re-dock can jump pitch +22° | 15 s debounce, auto-resume, pointing always re-verified |
| Firmware inactivity sleep | idles during long gaps | Net-zero keepalive micro-pulse (~0.003°, under half a tick) every 15 s |

## Architecture

```
                 ┌─────────────────────────── UI ───────────────────────────┐
                 │  Tonight · Session (flight tracker) · Onboarding ·        │
                 │  Modes gallery · Logbook · Learn · Settings · Night mode  │
                 └────────────────────────────┬──────────────────────────────┘
                                              │ observes
                              ┌───────────────▼───────────────┐
                              │     SessionEngine (Modes)      │
                              │  Connect → Aim → Calibrate →   │
                              │  Capture → Develop → Complete  │
                              └──┬───────────┬───────────┬────┘
                      MountControlling   SessionHooks   Stacking
                              │               │              │
                     ┌────────▼──────┐ ┌──────▼──────┐ ┌────▼─────────┐
                     │ Mount          │ │ Capture      │ │ Stacking      │
                     │ MountService   │ │ CaptureEngine│ │ CPUStacker    │
                     │ NudgePlanner   │ │ ExposurePlanner│ TrailsBlender │
                     └────────┬──────┘ └─────────────┘ └──────────────┘
                              │ #if canImport(DockKit)
                     ┌────────▼──────┐        ┌───────────────┐
                     │ DockKit / sim  │        │ Sky (SkyEngine)│ ← pure math,
                     └───────────────┘        └───────────────┘   feeds Tonight + gates
```

Module boundaries are protocols in `Sources/Core/Models.swift` (`SkyComputing`,
`MountControlling`, `Stacking`) — hardware-facing classes sit behind them, and all the
planning/decision logic (`NudgePlanner`, `ExposurePlanner`, `StorageBudget`,
feasibility gates, the session state machine) is pure Swift so it unit-tests on any
platform. DockKit and AVFoundation code is fenced with `#if` so the simulator runs
the complete app against a physics stand-in gimbal and a synthetic drifting starfield.

## Modules

- **Core** — `Theme` (Flighty × Night Sky design system with a global red night
  mode), `Models` (shared types and the cross-module protocols), `GimbalConstants`
  (the measured values above), `SessionStore` (logbook persistence).
- **Sky** — `SkyEngine`: dependency-free ephemeris (USNO GMST, Meeus low-precision
  sun/moon series, RA/Dec→Alt/Az, Milky Way core position, twilight and darkness
  windows, tonight verdict). Accuracy ≈ 0.01° sun / 0.3° moon — far tighter than the
  gimbal's 0.15° impulse σ.
- **Mount** — `MountService`: the velocity-impulse controller (closed-loop slews,
  open-loop nudges, settle detection, keepalive, flap/authority state machine,
  cable-wrap accounting) with a simulated gimbal on non-DockKit platforms.
  `NudgePlanner`: pure-math impulse solver, drift feed-forward, pitch envelope,
  cable-wrap accumulator.
- **Capture** — `CaptureEngine`: the bench-proven 1 s custom-exposure loop (Bayer RAW
  requested alongside processed frames, focus locked at infinity, ZSL off,
  sequential pacing), plus focus-drift telemetry. `ExposurePlanner` adapts recipes to
  sky quality; `StorageBudget` pre-flights disk usage; `TimelapseAssembler` builds
  motion-timelapse output.
- **Stacking** — `CPUStacker`: star detection, translation + rotation registration
  (Procrustes on matched centroids), running mean with kappa-sigma clipping, asinh
  preview. Honest scope: a monochrome luminance stack for live progress and the
  landing report, not a color-calibrated final image. `TrailsBlender`:
  brightest-pixel blending for star trails.
- **Modes** — `ShotModeRegistry`: nine shot modes (Milky Way Stack, Star Trails,
  Lunar, ISS Pass, Motion Timelapse, Cityscape, Aurora, Meteor Shower, Conjunction),
  each with a recipe, feasibility gate, tutorial, setup checklist, and honest
  expectation copy. `SessionEngine`: the flight computer — walks a shot through its
  phases and survives the full edge-case matrix (authority gating, mid-session
  undock/re-dock with pointing invalidation, thermal backoff and critical stop,
  battery and storage guardians, backgrounding with zeroed motors, abort from
  anywhere).
- **UI** — Tonight (verdict + shot cards), Session (phase timeline, live integration
  meter, telemetry chips, guardian alerts, landing report), Onboarding (including
  trigger/authority teaching), Modes gallery, Logbook, Learn, Settings. Everything
  renders through `Theme`/`Appearance`, so the red night mode is a single toggle.

## Building

The Xcode project is generated — `project.yml` is the source of truth.

```sh
brew install xcodegen
xcodegen generate
open StarFlow.xcodeproj
```

Run the `StarFlow` scheme on an iOS 18+ simulator for the full app with simulated
hardware, or on a device for the real DockKit + camera paths.

**CI** (`.github/workflows/build.yml`) runs on every push to `main`: it generates the
project, runs the unit-test suite on an iOS simulator, builds an unsigned Release
device archive, and uploads `StarFlow.ipa` as a workflow artifact.

**Installing without a paid developer account:** download the `StarFlow-ipa` artifact
from the latest green Actions run and sideload it with
[Sideloadly](https://sideloadly.io) (works from Windows or macOS, signs with a free
Apple ID; free-account installs expire after 7 days and need re-sideloading).

## Tests

`xcodebuild test` on a simulator, no hardware required — the same suite CI runs:

- **SkyEngineTests** — ephemeris output against known almanac values (sidereal time,
  sun/moon positions, rise/set and darkness windows, within ±0.5° / ±2 min).
- **NudgePlannerTests** — impulse solver bounds (velocity floor, watchdog cap,
  minimum pulse), drift feed-forward math, cable-wrap accumulator, pitch envelope.
- **StackerTests** — registration and stacking on synthetic gaussian starfields;
  alignment residual under 0.5 px, cloud/misalignment rejection.
- **TrailsBlenderTests** — brightest-pixel blending behavior.
- **SessionEngineTests** — the session state machine against a mock mount and fast
  fake hooks: happy path, authority gate, mid-capture flap with auto-resume and
  pointing invalidation, thermal-critical graceful stop, abort with partial data,
  plus mode-registry integrity and feasibility gates.
- **ExposurePlannerTests** — recipe adaptation and storage-budget verdicts.

## Roadmap

- **Plate solving** — match detected star centroids against a bundled catalog to
  verify pointing after re-docks and to guide aim, replacing the current
  "re-check your framing" prompt with a measurement.
- **Metal stacker** — move registration and accumulation to the GPU for full-
  resolution color stacks (the CPU pipeline is the correctness reference).
- **Cityscape processing** — dedicated skyline/light-trail treatment for the
  city-viable modes rather than the generic stacking path.
- **Panorama** — use the gimbal's repeatable slews to shoot stitched night
  panoramas, including a Milky Way arch program.

## Honest expectations

StarFlow is deliberately candid in-app about what a phone on a consumer gimbal can
and cannot do: a stacked Milky Way from a dark site is a strong phone image, not a
tracked-DSLR poster; the Milky Way does not exist from a city; star trails are the
city hero shot. The same tone applies here — if the bench says the hardware can't do
it, the app doesn't promise it.
