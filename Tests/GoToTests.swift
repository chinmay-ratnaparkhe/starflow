import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - Test doubles (file-private; names prefixed to avoid target-wide collisions)

@MainActor
private final class GoToMockMount: MountControlling {
    var connection: MountConnection = .docked(name: "MockFlow")
    var authority: MountAuthority = .granted
    var telemetry: MountTelemetry? = MountTelemetry(pitchDeg: 5, yawDeg: 120,
                                                    speedDegPerSec: 0, batteryPercent: 90)
    var nudges: [(pitch: Double, yaw: Double)] = []
    var stopCount = 0
    var nudgeStarted = false
    /// When > 0, `nudge` sleeps this long first — lets tests cancel mid-move.
    var nudgeDelayNanos: UInt64 = 0
    /// Called after each completed nudge — scripted convergence lives here.
    var onNudge: (@MainActor (_ deltaPitchDeg: Double, _ deltaYawDeg: Double) -> Void)?

    func start() {}
    func stopEverything() async { stopCount += 1 }
    func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {
        nudgeStarted = true
        if nudgeDelayNanos > 0 { try await Task.sleep(nanoseconds: nudgeDelayNanos) }
        nudges.append((deltaPitchDeg, deltaYawDeg))
        onNudge?(deltaPitchDeg, deltaYawDeg)
    }
    func waitSettled() async -> Bool { true }
    func keepalivePulse() async {}
}

private final class GoToMockStacker: Stacking {
    var added = 0
    private let tiny: CGImage? = {
        guard let ctx = CGContext(data: nil, width: 8, height: 8,
                                  bitsPerComponent: 8, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()
    }()
    func reset(width: Int, height: Int) { added = 0 }
    func add(frame: SubFrame) -> Bool { added += 1; return true }
    func currentResult() -> StackResult {
        StackResult(accepted: added, rejected: 0, integrationSeconds: Double(added), preview: tiny)
    }
    func finalImage() -> CGImage? { tiny }
}

private final class GoToBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private struct GoToTestTimeout: Error {}

// MARK: - Tests

/// Plate-solve GoTo (feature 5): the closed slew→shoot→solve→correct loop.
///
/// All fields and solutions are scripted through `GoToController.IO`, but the
/// scripted solutions are built with `GoToController.equatorial` — the inverse
/// of the REAL `SkyEngine.altAz` — so every pointing round-trips through the
/// production coordinate math rather than a parallel fake.
@MainActor
final class GoToTests: XCTestCase {

    private let sky = SkyEngine()
    private let boulder = GeoLocation(latitude: 40.0, longitude: -105.25)
    /// Fixed mid-2026 instant (UTC) so ephemeris output is fully deterministic.
    private let fixedDate = Date(timeIntervalSince1970: 1_783_231_200)

    // MARK: Fixtures

    /// A plate solution whose image center sits at `pointing` for this
    /// observer/instant — what a real solver would return if the camera were
    /// aimed exactly there.
    private func solution(for pointing: HorizontalCoord, at date: Date) -> PlateSolver.Solution {
        let eq = GoToController.equatorial(of: pointing, at: boulder, date: date, sky: sky)
        return PlateSolver.Solution(centerRADeg: eq.raHours * 15.0, centerDecDeg: eq.decDeg,
                                    rollDeg: 0, plateScalePxPerDeg: 25,
                                    matchedCount: 12, residualPx: 0.6)
    }

    private func starField(_ count: Int = 12) -> GoToController.StarField {
        GoToController.StarField(
            centroids: (0..<count).map {
                CGPoint(x: Double($0) * 40 + 20, y: Double($0 % 5) * 60 + 30)
            },
            imageSize: CGSize(width: 1920, height: 1440))
    }

    /// IO whose solver always reports the camera at `pointing.value`.
    private func scriptedIO(pointing: GoToBox<HorizontalCoord>,
                            captures: GoToBox<Int>? = nil) -> GoToController.IO {
        GoToController.IO(
            captureField: { [self] in
                captures?.value += 1
                return starField()
            },
            solve: { [self] _, _ in solution(for: pointing.value, at: fixedDate) },
            now: { [self] in fixedDate })
    }

    private func wrap360(_ deg: Double) -> Double {
        let r = deg.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    private func waitUntil(timeout: TimeInterval = 10, _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw GoToTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Coordinate math

    /// `equatorial(of:)` must be the exact inverse of `SkyEngine.altAz` —
    /// the trust anchor for every scripted solution in this suite.
    func testEquatorialInverseRoundTripsThroughAltAz() {
        let cases: [(alt: Double, az: Double)] = [
            (20, 180), (45, 90), (5, 350), (60, 10), (33, 200), (75, 270),
        ]
        for c in cases {
            let pointing = HorizontalCoord(altitudeDeg: c.alt, azimuthDeg: c.az)
            let eq = GoToController.equatorial(of: pointing, at: boulder,
                                               date: fixedDate, sky: sky)
            let back = sky.altAz(of: eq, at: boulder, date: fixedDate)
            XCTAssertEqual(back.altitudeDeg, c.alt, accuracy: 1e-6, "alt for \(c)")
            let azError = abs(CableWrapAccumulator.shortestDeltaDeg(from: back.azimuthDeg,
                                                                    to: c.az))
            XCTAssertLessThan(azError, 1e-6, "az for \(c)")
        }
    }

    // MARK: Convergence

    /// From ~8° of initial pointing error, with deliberately imperfect
    /// impulses (90% of the commanded angle lands), the loop must lock on
    /// within 4 solve iterations and finish inside the 0.5° radius.
    func testConvergesFromEightDegreeErrorWithinFourIterations() async throws {
        let mount = GoToMockMount()
        let target = HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180)
        // 8.5° of azimuth error ≈ 8.0° of sky arc at alt 20°.
        let pointing = GoToBox(HorizontalCoord(altitudeDeg: 20, azimuthDeg: 188.5))
        mount.onNudge = { [self] pitch, yaw in
            pointing.value.altitudeDeg += pitch * 0.9
            pointing.value.azimuthDeg = wrap360(pointing.value.azimuthDeg + yaw * 0.9)
        }
        var statuses: [String] = []
        let outcome = try await GoToController(sky: sky).acquire(
            target: target, location: boulder, mount: mount,
            io: scriptedIO(pointing: pointing)) { statuses.append($0) }

        XCTAssertLessThanOrEqual(outcome.iterations, 4)
        XCTAssertLessThanOrEqual(outcome.finalErrorDeg, 0.5)
        XCTAssertEqual(outcome.corrections, mount.nudges.count)
        XCTAssertGreaterThanOrEqual(mount.nudges.count, 1)
        // Honest narration: read → solved-with-direction → locked.
        XCTAssertTrue(statuses.contains { $0.hasPrefix("Reading the stars") })
        XCTAssertTrue(statuses.contains { $0.hasPrefix("Solved: aimed") && $0.contains("right") },
                      "camera east of target must narrate as aimed right: \(statuses)")
        XCTAssertTrue(statuses.contains { $0.hasPrefix("Locked on:") })
        // The scripted sky must actually be back on target.
        let residual = abs(CableWrapAccumulator.shortestDeltaDeg(
            from: pointing.value.azimuthDeg, to: target.azimuthDeg))
        XCTAssertLessThan(residual, 0.6)
    }

    /// A first solve already inside the acceptance radius: locked with zero
    /// corrections, no mount motion.
    func testFirstSolveInsideRadiusLocksWithoutMoving() async throws {
        let mount = GoToMockMount()
        let target = HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180)
        let pointing = GoToBox(HorizontalCoord(altitudeDeg: 20.2, azimuthDeg: 180.1))
        let outcome = try await GoToController(sky: sky).acquire(
            target: target, location: boulder, mount: mount,
            io: scriptedIO(pointing: pointing))
        XCTAssertEqual(outcome.iterations, 1)
        XCTAssertEqual(outcome.corrections, 0)
        XCTAssertTrue(mount.nudges.isEmpty)
    }

    // MARK: Failure taxonomy

    /// Persistent no-solve (sparse/hazy field): one free retry, then a clean
    /// typed give-up — no mount motion, velocity zeroed on the way out.
    func testGivesUpCleanlyOnPersistentNoSolve() async throws {
        let mount = GoToMockMount()
        let captures = GoToBox(0)
        let io = GoToController.IO(
            captureField: { [self] in captures.value += 1; return starField() },
            solve: { _, _ in nil },
            now: { [self] in fixedDate })
        do {
            _ = try await GoToController(sky: sky).acquire(
                target: HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180),
                location: boulder, mount: mount, io: io)
            XCTFail("persistent noSolve must throw")
        } catch let failure as GoToController.Failure {
            XCTAssertEqual(failure, .noSolve)
        } catch {
            XCTFail("expected GoToController.Failure.noSolve, got \(error)")
        }
        XCTAssertEqual(captures.value, 2, "one retry, then the honest give-up")
        XCTAssertTrue(mount.nudges.isEmpty, "no correction may fire without a solve")
        XCTAssertGreaterThanOrEqual(mount.stopCount, 1,
                                    "velocity must be zeroed on the failure exit")
    }

    /// Too few centroids (clouds / indoors) surfaces as `tooFewStars` with the
    /// measured count — the caller's copy depends on it.
    func testTooFewStarsFailsHonestly() async throws {
        let mount = GoToMockMount()
        let io = GoToController.IO(
            captureField: { [self] in starField(3) },
            solve: { _, _ in XCTFail("must not solve a 3-star field"); return nil },
            now: { [self] in fixedDate })
        do {
            _ = try await GoToController(sky: sky).acquire(
                target: HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180),
                location: boulder, mount: mount, io: io)
            XCTFail("3 centroids must throw tooFewStars")
        } catch let failure as GoToController.Failure {
            XCTAssertEqual(failure, .tooFewStars(count: 3))
        } catch {
            XCTFail("expected tooFewStars, got \(error)")
        }
    }

    /// No dock / no authority: `mountUnavailable` before any frame is shot.
    func testMountUnavailableWhenUndockedOrNoAuthority() async throws {
        for setup in ["undocked", "denied"] {
            let mount = GoToMockMount()
            if setup == "undocked" { mount.connection = .undocked }
            else { mount.authority = .denied }
            let captures = GoToBox(0)
            let pointing = GoToBox(HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180))
            do {
                _ = try await GoToController(sky: sky).acquire(
                    target: HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180),
                    location: boulder, mount: mount,
                    io: scriptedIO(pointing: pointing, captures: captures))
                XCTFail("\(setup): must throw mountUnavailable")
            } catch let failure as GoToController.Failure {
                XCTAssertEqual(failure, .mountUnavailable, setup)
            } catch {
                XCTFail("\(setup): expected mountUnavailable, got \(error)")
            }
            XCTAssertEqual(captures.value, 0, "\(setup): no frame without a usable mount")
        }
    }

    // MARK: Drift cross-check

    /// 1.5° of measured drift (over the 1° tolerance) gets exactly one
    /// corrective impulse, narrated, and the frame lands back on target.
    func testDriftCheckCorrectsMeasuredDrift() async throws {
        let mount = GoToMockMount()
        let target = HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180)
        // 1.5° of sky-arc drift purely in azimuth: 1.5 / cos(20°) of raw azimuth.
        let driftAz = 1.5 / cos(20.0 * .pi / 180.0)
        let pointing = GoToBox(HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180 + driftAz))
        mount.onNudge = { [self] pitch, yaw in
            pointing.value.altitudeDeg += pitch
            pointing.value.azimuthDeg = wrap360(pointing.value.azimuthDeg + yaw)
        }
        var statuses: [String] = []
        let controller = GoToController(sky: sky)
        let io = scriptedIO(pointing: pointing)

        let outcome = try await controller.driftCheck(
            target: target, location: boulder, mount: mount, io: io) { statuses.append($0) }
        XCTAssertEqual(outcome.driftDeg, 1.5, accuracy: 0.01)
        XCTAssertTrue(outcome.corrected)
        XCTAssertEqual(mount.nudges.count, 1)
        XCTAssertTrue(statuses.contains { $0.contains("off target — correcting") },
                      "correction must be narrated: \(statuses)")

        // Second check right after the correction: on target, no motion.
        let second = try await controller.driftCheck(
            target: target, location: boulder, mount: mount, io: io) { statuses.append($0) }
        XCTAssertFalse(second.corrected)
        XCTAssertLessThan(second.driftDeg, 0.1)
        XCTAssertEqual(mount.nudges.count, 1, "small drift must be left alone")
        XCTAssertTrue(statuses.contains { $0.contains("on target") })
    }

    // MARK: Abort safety

    /// Cancelling mid-correction must surface CancellationError AND zero the
    /// mount's velocity (`stopEverything`) — an aborted GoTo can never leave
    /// the head with a live velocity command.
    func testAbortMidGoToZeroesVelocity() async throws {
        let mount = GoToMockMount()
        mount.nudgeDelayNanos = 2_000_000_000   // cancel lands mid-move
        let pointing = GoToBox(HorizontalCoord(altitudeDeg: 20, azimuthDeg: 188))
        let io = scriptedIO(pointing: pointing)
        let controller = GoToController(sky: sky)
        let task = Task { @MainActor in
            try await controller.acquire(
                target: HorizontalCoord(altitudeDeg: 20, azimuthDeg: 180),
                location: boulder, mount: mount, io: io)
        }
        try await waitUntil("nudge in flight") { mount.nudgeStarted }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled acquire must throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        XCTAssertGreaterThanOrEqual(mount.stopCount, 1,
                                    "stopEverything must run on the abort exit")
    }

    // MARK: - SessionEngine integration

    /// A shot that supports GoTo: gimbal + Milky Way target + registered stack.
    private func makeGoToShot(subs: Int) -> ShotModeItem {
        ShotModeItem(
            id: "goto-test", name: "GoTo Test", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: subs,
                                  nudgeTracking: false, intervalSeconds: 0),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: true,
            stackingStyle: .registered, celestialTarget: .milkyWayCore,
            feasibility: { _, _ in .great })
    }

    /// First instant (30-min steps from `fixedDate`) with the galactic core
    /// usefully above the horizon at Boulder — deterministic, and safely in the
    /// past relative to any real test-run clock (flap debounce math stays put).
    private func coreUpDate() throws -> Date {
        var t = fixedDate
        for _ in 0..<96 {
            if sky.milkyWayCorePosition(at: boulder, date: t).altitudeDeg > 12 { return t }
            t = t.addingTimeInterval(1800)
        }
        throw GoToTestTimeout()
    }

    /// Fast engine hooks with a FIXED clock (GoTo's target resolution and the
    /// scripted solutions must agree on "now").
    private func makeEngineHooks(now: Date) -> SessionHooks {
        SessionHooks(
            prepareCapture: { _ in (8, 8) },
            captureSub: { recipe, index in
                try await Task.sleep(nanoseconds: 2_000_000)
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                                pixelData: nil)
            },
            endCapture: {},
            thermalState: { .nominal },
            batteryPercent: { 80 },
            freeDiskBytes: { 64_000_000_000 },
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0.5) },
            now: { now },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })
    }

    /// Flap recovery must invalidate pointing AND trigger a fresh GoTo
    /// re-acquire before capture resumes; a successful re-acquire clears the
    /// pointing-invalidated flag because the solve has re-verified it.
    func testFlapRecoveryTriggersGoToReacquire() async throws {
        let when = try coreUpDate()
        AppLocation.shared.current = boulder
        defer { AppLocation.shared.current = nil }

        let mount = GoToMockMount()
        let solveCalls = GoToBox(0)
        var hooks = makeEngineHooks(now: when)
        hooks.detectStarField = { [self] _ in starField() }
        hooks.solveStarField = { [self] _, _ in
            solveCalls.value += 1
            // Camera exactly on the core: every acquire locks on iteration 1.
            let target = sky.milkyWayCorePosition(at: boulder, date: when)
            return solution(for: target, at: when)
        }
        let engine = SessionEngine(mount: mount, stacker: GoToMockStacker(), hooks: hooks)

        engine.start(shot: makeGoToShot(subs: 60))
        try await waitUntil("some subs captured") { engine.stats.subsAccepted >= 5 }
        XCTAssertGreaterThanOrEqual(solveCalls.value, 1,
                                    "initial acquire must have solved at capture start")
        XCTAssertFalse(engine.pointingInvalidated)
        let solvesBeforeFlap = solveCalls.value

        mount.connection = .flapping(since: Date())
        try await waitUntil("gimbalFlapping interruption") {
            engine.interruption == .gimbalFlapping
        }
        mount.connection = .docked(name: "MockFlow")
        try await waitUntil("re-acquire solve after re-dock") {
            solveCalls.value > solvesBeforeFlap
        }
        try await waitUntil("pointing re-verified by the solve") {
            !engine.pointingInvalidated
        }
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        XCTAssertEqual(engine.stats.flapsRecovered, 1)
    }

    /// A solver that never solves must fall back to the AimAssist-only flow:
    /// the session runs to completion on the coarse aim, GoTo frames never
    /// consume the capture plan, and no correction is ever commanded.
    func testSolverFailureFallsBackToAimAssistFlow() async throws {
        let when = try coreUpDate()
        AppLocation.shared.current = boulder
        defer { AppLocation.shared.current = nil }

        let mount = GoToMockMount()
        let solveCalls = GoToBox(0)
        var hooks = makeEngineHooks(now: when)
        hooks.detectStarField = { [self] _ in starField() }
        hooks.solveStarField = { _, _ in solveCalls.value += 1; return nil }
        let engine = SessionEngine(mount: mount, stacker: GoToMockStacker(), hooks: hooks)

        engine.start(shot: makeGoToShot(subs: 8))
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(engine.stats.subsAccepted, 8,
                       "the plan must complete on the coarse aim")
        XCTAssertEqual(solveCalls.value, 2, "one solve retry, then honest fallback")
        XCTAssertTrue(mount.nudges.isEmpty,
                      "no correction may fire when nothing ever solved")
        XCTAssertEqual(engine.stats.driftCorrections, 0)
    }
}
