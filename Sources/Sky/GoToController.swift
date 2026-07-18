import Foundation
import CoreGraphics

// MARK: - GoToController (Plate-solve GoTo, docs/ROADMAP-v3.md #5)
//
// Closes the aiming loop: capture one short frame → detect star centroids
// (the CPUStacker detection path) → `PlateSolver.solve` → convert the solved
// RA/Dec image center to Alt/Az via `SkyEngine` for here-and-now → measure the
// pointing error against the target → if it exceeds the acceptance radius,
// command a velocity-impulse correction through the mount (`MountService.nudge`
// runs `NudgePlanner.impulse` math under the hood), wait for settle, and solve
// again. Up to `Config.maxIterations` solve/correct rounds.
//
// Layering (everything simulator-testable):
//  - `GoToController` — the @MainActor loop driver. It talks to the camera and
//    solver only through injected closures (`GoToController.IO`), so tests
//    script solvable fields and solutions; device builds route through the
//    existing `SessionHooks` capture seam (`SessionEngine.makeGoToIO`).
//  - The mount is any `MountControlling` — the real `MountService` on device,
//    scripted mocks in tests.
//  - Coordinate math (`pointing(of:)` / `equatorial(of:)`) is pure and shared
//    with tests, so scripted solutions round-trip through the REAL sky math
//    rather than a parallel fake.
//
// Failure taxonomy is honest and typed (`Failure`): too few stars (clouds,
// indoors), no solve (pattern unmatched), mount unavailable, did-not-converge.
// Callers fall back — GoTo failing must never end a session.
//
// Safety contract: on ANY throwing exit (including cancellation mid-move) the
// controller calls `mount.stopEverything()`, so an aborted GoTo can never leave
// the gimbal with a live velocity command.
@MainActor
public final class GoToController {

    // MARK: - Failure taxonomy

    public enum Failure: LocalizedError, Equatable {
        /// Not enough centroids to even attempt a solve — clouds or indoor light.
        case tooFewStars(count: Int)
        /// Centroids were plentiful but no verified catalog match — haze, a
        /// star-poor field, or the FOV estimate was off.
        case noSolve
        /// Mount not docked / no motor authority — nothing to correct with.
        case mountUnavailable
        /// Solves kept succeeding but corrections never got inside the
        /// acceptance radius (envelope limit, wind, loose clamp…).
        case didNotConverge(finalErrorDeg: Double)

        public var errorDescription: String? {
            switch self {
            case .tooFewStars(let count):
                return "Only \(count) star\(count == 1 ? "" : "s") visible — clouds or "
                    + "indoor light are hiding the sky."
            case .noSolve:
                return "Couldn't match the stars to the map — the field may be too sparse or hazy."
            case .mountUnavailable:
                return "The gimbal isn't ready for automatic aiming."
            case .didNotConverge(let error):
                return String(format: "Aim refinement stalled %.1f° from the target.", error)
            }
        }

        /// Short clause for session status lines ("Plate-solve aim skipped — …").
        public var fallbackReason: String {
            switch self {
            case .tooFewStars: return "too few stars visible (clouds or indoor light?)."
            case .noSolve: return "the star pattern couldn't be matched."
            case .mountUnavailable: return "the gimbal isn't ready."
            case .didNotConverge: return "corrections didn't converge."
            }
        }
    }

    // MARK: - Types

    /// One detected star field: centroid pixel coordinates (y down,
    /// brightest-first — `CPUStacker.detectStars` order) plus the frame size.
    public struct StarField: Sendable {
        public var centroids: [CGPoint]
        public var imageSize: CGSize
        public init(centroids: [CGPoint], imageSize: CGSize) {
            self.centroids = centroids; self.imageSize = imageSize
        }
    }

    public struct Config: Sendable {
        /// Successful solves per acquire before giving up as `didNotConverge`.
        public var maxIterations = 4
        /// Pointing error at or under this counts as locked on (deg).
        public var acceptableErrorDeg = 0.5
        /// Rough horizontal FOV handed to the solver — the main camera's 73°
        /// (the solver tolerates ±60%, so tele-crop pipelines still pass a hint).
        public var fovEstimateDeg = 73.0
        /// Fewer centroids than this is `tooFewStars` (the solver's own honest
        /// minimum for a verified match).
        public var minCentroids = 6
        /// Consecutive capture/solve failures tolerated before the loop stops
        /// retrying and surfaces the failure (one free retry absorbs a single
        /// bad frame; persistent failure returns to the caller for fallback).
        public var maxConsecutiveSolveFailures = 2
        public init() {}
    }

    /// Result of a successful acquire.
    public struct Outcome: Equatable, Sendable {
        /// Measured residual pointing error at lock (deg).
        public var finalErrorDeg: Double
        /// Solve iterations used (1 = first solve was already inside the radius).
        public var iterations: Int
        /// Corrective mount moves commanded.
        public var corrections: Int
        public init(finalErrorDeg: Double, iterations: Int, corrections: Int) {
            self.finalErrorDeg = finalErrorDeg; self.iterations = iterations
            self.corrections = corrections
        }
    }

    /// Result of a mid-session drift cross-check.
    public struct DriftOutcome: Equatable, Sendable {
        /// Measured pointing error when the check ran (deg).
        public var driftDeg: Double
        /// True when the drift exceeded tolerance and a correction was commanded.
        public var corrected: Bool
        public init(driftDeg: Double, corrected: Bool) {
            self.driftDeg = driftDeg; self.corrected = corrected
        }
    }

    /// The world seams. Tests script these; `SessionEngine` routes them through
    /// the existing `SessionHooks` capture path so no device-camera code is
    /// reachable from simulator tests.
    public struct IO {
        /// Capture one short (~1 s) frame and detect its star centroids.
        public var captureField: @MainActor () async throws -> StarField
        /// Plate-solve a field given a rough horizontal FOV estimate (deg).
        public var solve: @MainActor (StarField, Double) -> PlateSolver.Solution?
        /// Clock seam (tests fix it; the RA/Dec → Alt/Az conversion needs "now").
        public var now: @MainActor () -> Date

        public init(captureField: @escaping @MainActor () async throws -> StarField,
                    solve: @escaping @MainActor (StarField, Double) -> PlateSolver.Solution? = { field, fovDeg in
                        PlateSolver.shared.solve(centroids: field.centroids,
                                                 imageSize: field.imageSize,
                                                 fovEstimateDeg: fovDeg)
                    },
                    now: @escaping @MainActor () -> Date = { Date() }) {
            self.captureField = captureField
            self.solve = solve
            self.now = now
        }
    }

    // MARK: - Dependencies

    private let sky: SkyComputing
    private let config: Config

    public init(sky: SkyComputing = SkyEngine(), config: Config = Config()) {
        self.sky = sky
        self.config = config
    }

    // MARK: - Acquire (the closed loop)

    /// Slew→shoot→solve→correct until the measured pointing error is at or
    /// under `Config.acceptableErrorDeg`, up to `Config.maxIterations` solves.
    ///
    /// `target` is the celestial target's CURRENT horizon position (from
    /// `AimAssist.resolve` / `SkyEngine`), resolved at (or near) `io.now()`;
    /// `location` is the observer. The sky keeps moving while the loop runs
    /// (up to ~0.25°/min — commensurate with the 0.5° acceptance radius over a
    /// multi-exposure acquire), so the target is frozen as a FIXED equatorial
    /// point at entry and its horizon position is re-derived at each solve's
    /// instant: the error is always measured against where the target is NOW,
    /// never where it was when the acquire started.
    /// Statuses stream through `onStatus` ("Reading the stars…" /
    /// "Solved: aimed 3.2° right of target — correcting…" / "Locked on: 0.3°…").
    ///
    /// Throws `Failure` (typed, honest — callers fall back to compass aim) or
    /// rethrows capture errors / cancellation. Velocity is zeroed via
    /// `mount.stopEverything()` on every throwing exit.
    @discardableResult
    public func acquire(target: HorizontalCoord, location: GeoLocation,
                        mount: MountControlling, io: IO,
                        onStatus: (@MainActor (String) -> Void)? = nil) async throws -> Outcome {
        guard case .docked = mount.connection, mount.authority == .granted else {
            throw Failure.mountUnavailable
        }
        // Diurnal tracking across the loop: `target` was resolved at (or near)
        // entry, so invert it to the fixed sky point it names and follow THAT.
        // (The Moon's own equatorial motion is ~0.01°/min — negligible over an
        // acquire; diurnal motion, 25× faster, is what this compensates.)
        let targetEquatorial = Self.equatorial(of: target, at: location,
                                               date: io.now(), sky: sky)
        do {
            var solves = 0
            var corrections = 0
            var consecutiveFailures = 0
            while true {
                try Task.checkCancellation()
                onStatus?("Reading the stars…")
                let field = try await io.captureField()

                var solution: PlateSolver.Solution?
                let failure: Failure?
                if field.centroids.count < config.minCentroids {
                    failure = .tooFewStars(count: field.centroids.count)
                } else if let solved = io.solve(field, config.fovEstimateDeg) {
                    solution = solved
                    failure = nil
                } else {
                    failure = .noSolve
                }
                if let failure {
                    consecutiveFailures += 1
                    guard consecutiveFailures < config.maxConsecutiveSolveFailures else {
                        throw failure
                    }
                    onStatus?("Couldn't read that frame — trying once more…")
                    continue
                }
                consecutiveFailures = 0
                solves += 1
                guard let solution else { throw Failure.noSolve }   // unreachable

                // Pointing AND target both evaluated at the same "now": the
                // solve is a J2000 fix, the target a fixed sky point — both
                // rotate through the identical Alt/Az conversion.
                let now = io.now()
                let pointing = Self.pointing(of: solution, at: location,
                                             date: now, sky: sky)
                let currentTarget = sky.altAz(of: targetEquatorial, at: location, date: now)
                let offset = FramingGuide.offset(cameraAzimuthDeg: pointing.azimuthDeg,
                                                 cameraAltitudeDeg: pointing.altitudeDeg,
                                                 target: currentTarget)
                let errorDeg = offset.separationDeg
                if errorDeg <= config.acceptableErrorDeg {
                    onStatus?(String(format: "Locked on: %.1f° from target.", errorDeg))
                    return Outcome(finalErrorDeg: errorDeg, iterations: solves,
                                   corrections: corrections)
                }
                guard solves < config.maxIterations else {
                    throw Failure.didNotConverge(finalErrorDeg: errorDeg)
                }
                onStatus?("Solved: aimed \(Self.missDescription(offset)) of target — correcting…")
                try await correct(pointing: pointing, target: currentTarget, mount: mount)
                corrections += 1
                _ = await mount.waitSettled()
            }
        } catch {
            // Abort/cancel/failure mid-GoTo must never leave a live velocity
            // command on the head.
            await mount.stopEverything()
            throw error
        }
    }

    // MARK: - Mid-session drift cross-check

    /// One capture + solve to measure how far the frame has drifted off the
    /// target. Drift at or under `toleranceDeg` is narrated and left alone
    /// (the nudge cadence handles it); larger drift gets one corrective
    /// impulse. Throws the same `Failure` taxonomy — a failed check is benign
    /// for the caller (skip and rely on feed-forward), never fatal.
    @discardableResult
    public func driftCheck(target: HorizontalCoord, location: GeoLocation,
                           mount: MountControlling, io: IO,
                           toleranceDeg: Double = 1.0,
                           onStatus: (@MainActor (String) -> Void)? = nil) async throws -> DriftOutcome {
        guard case .docked = mount.connection, mount.authority == .granted else {
            throw Failure.mountUnavailable
        }
        // Same diurnal tracking as `acquire`: the capture takes a full exposure,
        // so re-derive the target's horizon position at the solve's instant.
        let targetEquatorial = Self.equatorial(of: target, at: location,
                                               date: io.now(), sky: sky)
        do {
            let field = try await io.captureField()
            guard field.centroids.count >= config.minCentroids else {
                throw Failure.tooFewStars(count: field.centroids.count)
            }
            guard let solution = io.solve(field, config.fovEstimateDeg) else {
                throw Failure.noSolve
            }
            let now = io.now()
            let pointing = Self.pointing(of: solution, at: location,
                                         date: now, sky: sky)
            let currentTarget = sky.altAz(of: targetEquatorial, at: location, date: now)
            let offset = FramingGuide.offset(cameraAzimuthDeg: pointing.azimuthDeg,
                                             cameraAltitudeDeg: pointing.altitudeDeg,
                                             target: currentTarget)
            let driftDeg = offset.separationDeg
            guard driftDeg > toleranceDeg else {
                onStatus?(String(format: "Drift check: on target (%.1f°).", driftDeg))
                return DriftOutcome(driftDeg: driftDeg, corrected: false)
            }
            onStatus?(String(format: "Drift check: %.1f° off target — correcting.", driftDeg))
            try await correct(pointing: pointing, target: currentTarget, mount: mount)
            _ = await mount.waitSettled()
            return DriftOutcome(driftDeg: driftDeg, corrected: true)
        } catch {
            await mount.stopEverything()
            throw error
        }
    }

    // MARK: - Correction (velocity impulses through the mount)

    /// One corrective move from a solved pointing toward the target. Planned
    /// with `AimAssist.plan` (shortest yaw path, pitch pre-clamped into the
    /// DockKit envelope) and executed as chained velocity impulses by
    /// `mount.nudge` — `NudgePlanner.impulse` solves each pulse's rate ×
    /// duration against the measured floor/watchdog.
    private func correct(pointing: HorizontalCoord, target: HorizontalCoord,
                         mount: MountControlling) async throws {
        let plan = AimAssist.plan(currentAzimuthDeg: pointing.azimuthDeg,
                                  currentAltitudeDeg: pointing.altitudeDeg,
                                  mountPitchDeg: mount.telemetry?.pitchDeg ?? 0,
                                  target: target)
        do {
            try await mount.nudge(deltaPitchDeg: plan.deltaPitchDeg,
                                  deltaYawDeg: plan.deltaYawDeg)
        } catch MountError.notConnected, MountError.noAuthority {
            throw Failure.mountUnavailable
        }
    }

    // MARK: - Pointing math (pure; shared with tests)

    /// Where the camera is ACTUALLY pointing, from a plate solution: the solved
    /// J2000 image center converted to horizon coordinates for this observer
    /// and instant.
    public static func pointing(of solution: PlateSolver.Solution, at location: GeoLocation,
                                date: Date, sky: SkyComputing) -> HorizontalCoord {
        sky.altAz(of: solution.center, at: location, date: date)
    }

    /// Inverse of `SkyEngine.altAz`: horizon coordinates (0 = N, 90 = E) back
    /// to equatorial for this observer and instant. Standard spherical trig in
    /// atan2 form (no tan singularities):
    ///   sin δ = sin φ sin a + cos φ cos a cos A
    ///   H = atan2(−cos a · sin A, cos φ sin a − sin φ cos a cos A),  α = LST − H
    /// Tests use it to script solver solutions from a desired pointing, so the
    /// scripted values round-trip through the REAL forward conversion.
    public static func equatorial(of pointing: HorizontalCoord, at location: GeoLocation,
                                  date: Date, sky: SkyComputing) -> EquatorialCoord {
        let lstHours = SkyEngine.wrap(
            sky.greenwichMeanSiderealTime(date: date) + location.longitude / 15.0, to: 24.0)
        let alt = pointing.altitudeDeg * .pi / 180.0
        let az = pointing.azimuthDeg * .pi / 180.0
        let phi = location.latitude * .pi / 180.0
        let sinDec = sin(phi) * sin(alt) + cos(phi) * cos(alt) * cos(az)
        let dec = asin(min(1.0, max(-1.0, sinDec)))
        let ha = atan2(-cos(alt) * sin(az),
                       cos(phi) * sin(alt) - sin(phi) * cos(alt) * cos(az))
        let raHours = SkyEngine.wrap(lstHours - ha * 180.0 / .pi / 15.0, to: 24.0)
        return EquatorialCoord(raHours: raHours, decDeg: dec * 180.0 / .pi)
    }

    /// Human description of where the CAMERA is aimed relative to the target —
    /// the mirror of `FramingGuide.offset` (which says where the target sits
    /// relative to the frame): target left of center means the camera is aimed
    /// right of the target.
    static func missDescription(_ offset: FramingGuide.Offset) -> String {
        var parts: [String] = []
        if abs(offset.rightDeg) >= 0.05 {
            parts.append(String(format: "%.1f° %@", abs(offset.rightDeg),
                                offset.rightDeg >= 0 ? "left" : "right"))
        }
        if abs(offset.upDeg) >= 0.05 {
            parts.append(String(format: "%.1f° %@", abs(offset.upDeg),
                                offset.upDeg >= 0 ? "low" : "high"))
        }
        return parts.isEmpty ? "on target" : parts.joined(separator: ", ")
    }
}
