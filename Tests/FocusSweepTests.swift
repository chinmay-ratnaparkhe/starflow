import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - FocusSweepPlanTests
//
// Pure sweep math: ladder generation (bounds, spacing, degenerate inputs) and
// best-position picking on synthetic score curves — clean, noisy, flat, and
// broken. No camera, no hardware; everything passes on the iOS Simulator.

final class FocusSweepPlanTests: XCTestCase {

    private func gauss(_ position: Double, peak: Double,
                       sigma: Double = 0.03, base: Double = 50,
                       gain: Double = 400) -> Double {
        let d = position - peak
        return base + gain * exp(-(d * d) / (2 * sigma * sigma))
    }

    // MARK: Ladder generation

    func testCoarseLadderSpansBoundsEvenlyDescending() {
        let plan = FocusSweepPlan()
        let positions = plan.coarsePositions
        XCTAssertEqual(positions.count, 6)
        XCTAssertEqual(positions.first ?? 0, 1.0, accuracy: 1e-12,
                       "The ladder must start at the infinity lock")
        XCTAssertEqual(positions.last ?? 0, 0.85, accuracy: 1e-12)
        XCTAssertTrue(zip(positions, positions.dropFirst()).allSatisfy { $0 > $1 },
                      "The ladder must be strictly descending")
        let step = (1.0 - 0.85) / 5
        for (i, value) in positions.enumerated() {
            XCTAssertEqual(value, 1.0 - Double(i) * step, accuracy: 1e-12,
                           "Rung \(i) must be evenly spaced")
        }
        XCTAssertTrue(positions.allSatisfy { $0 >= plan.lowerBound && $0 <= plan.upperBound })
    }

    func testFineLadderCentersAndClampsToBounds() {
        let plan = FocusSweepPlan()

        let mid = plan.finePositions(around: 0.92)
        XCTAssertEqual(mid.count, 5)
        XCTAssertEqual(mid.first ?? 0, 0.94, accuracy: 1e-9)
        XCTAssertEqual(mid.last ?? 0, 0.90, accuracy: 1e-9)
        XCTAssertTrue(zip(mid, mid.dropFirst()).allSatisfy { $0 > $1 })

        let nearInfinity = plan.finePositions(around: 1.0)
        XCTAssertTrue(nearInfinity.allSatisfy { $0 <= 1.0 },
                      "Fine ladder must never exceed the infinity end of travel")
        XCTAssertEqual(nearInfinity.first ?? 0, 1.0, accuracy: 1e-9)

        let nearFloor = plan.finePositions(around: 0.85)
        XCTAssertTrue(nearFloor.allSatisfy { $0 >= 0.85 },
                      "Fine ladder must respect the sweep's lower bound")
    }

    func testDegenerateLaddersAndInitSanitization() {
        XCTAssertEqual(FocusSweepPlan(coarseSteps: 1).coarsePositions, [1.0])
        XCTAssertTrue(FocusSweepPlan(fineSteps: 0).finePositions(around: 0.9).isEmpty)

        let weird = FocusSweepPlan(upperBound: 2.0, lowerBound: -1.0,
                                   coarseSteps: 0, framesPerStep: 0)
        XCTAssertEqual(weird.upperBound, 1.0, accuracy: 1e-12,
                       "Upper bound must clamp into lens travel")
        XCTAssertEqual(weird.lowerBound, 0.0, accuracy: 1e-12)
        XCTAssertEqual(weird.coarseSteps, 1, "At least one position is always tried")
        XCTAssertEqual(weird.framesPerStep, 1, "At least one frame per position")

        let inverted = FocusSweepPlan(upperBound: 0.5, lowerBound: 0.9)
        XCTAssertLessThanOrEqual(inverted.lowerBound, inverted.upperBound,
                                 "Bounds must never invert")
    }

    // MARK: Peak picking

    func testCleanCurvePicksThePeakDecisively() {
        let plan = FocusSweepPlan()
        let positions = plan.coarsePositions
        let scores = positions.map { gauss($0, peak: 0.91) }
        let pick = plan.bestPosition(positions: positions, scores: scores)
        XCTAssertTrue(pick.decisive)
        XCTAssertEqual(pick.position, 0.91, accuracy: 1e-9)
    }

    func testNoisyCurveStillPicksNearTheTruePeak() {
        let plan = FocusSweepPlan()
        // Dense ladder + deterministic ±3% noise: the pick must land on the
        // true peak's rung despite the jitter.
        let positions = (0..<16).map { 1.0 - Double($0) * 0.01 }
        let noise = [1.02, 0.98, 1.03, 0.97, 1.01, 0.99, 1.02, 0.98,
                     1.00, 1.03, 0.97, 1.01, 0.99, 1.02, 0.98, 1.00]
        let scores = positions.enumerated().map { index, position in
            gauss(position, peak: 0.92, sigma: 0.02) * noise[index]
        }
        let pick = plan.bestPosition(positions: positions, scores: scores)
        XCTAssertTrue(pick.decisive)
        XCTAssertEqual(pick.position, 0.92, accuracy: 0.0101,
                       "Noise must not move the pick more than one rung off the peak")
    }

    func testFlatCurveKeepsTheInfinityDefault() {
        let plan = FocusSweepPlan()
        let positions = plan.coarsePositions

        let dead = plan.bestPosition(positions: positions,
                                     scores: positions.map { _ in 100.0 })
        XCTAssertFalse(dead.decisive, "A perfectly flat curve has no peak")
        XCTAssertEqual(dead.position, 1.0, accuracy: 1e-12,
                       "No peak → keep the 1.0 infinity default")

        // Flat-with-jitter (±2%, under the 15% contrast gate) must also fall back.
        let jitter = [1.00, 1.02, 0.99, 1.01, 0.98, 1.00]
        let noisy = plan.bestPosition(positions: positions,
                                      scores: jitter.map { 100 * $0 })
        XCTAssertFalse(noisy.decisive)
        XCTAssertEqual(noisy.position, 1.0, accuracy: 1e-12)
    }

    func testDeadRungCannotMakeAFlatCurveDecisive() {
        let plan = FocusSweepPlan()
        let positions = plan.coarsePositions

        // Flat curve except one rung whose frames were all unusable (score 0):
        // the contrast gate must compare against the weakest MEASURED rung — a
        // dead rung carries no information and must not fake a peak.
        var flat = positions.map { _ in 100.0 }
        flat[2] = 0
        let pick = plan.bestPosition(positions: positions, scores: flat)
        XCTAssertFalse(pick.decisive,
                       "A dead rung must not let a flat curve pass the contrast gate")
        XCTAssertEqual(pick.position, 1.0, accuracy: 1e-12)

        // A real peak with a dead rung elsewhere must still be decisive.
        var peaked = positions.map { gauss($0, peak: 0.91) }
        peaked[0] = 0
        let peakPick = plan.bestPosition(positions: positions, scores: peaked)
        XCTAssertTrue(peakPick.decisive,
                      "A dead rung must not veto a genuine peak either")
        XCTAssertEqual(peakPick.position, 0.91, accuracy: 1e-9)
    }

    func testDegenerateScoreInputsFallBackToInfinity() {
        let plan = FocusSweepPlan()
        let positions = plan.coarsePositions

        let cases: [(String, [Double], [Double])] = [
            ("empty", [], []),
            ("mismatched counts", positions, [1, 2, 3]),
            ("all zero", positions, positions.map { _ in 0 }),
            ("NaN score", positions, [10, 20, Double.nan, 20, 10, 5]),
            ("negative score", positions, [10, 20, -5, 20, 10, 5]),
        ]
        for (name, p, s) in cases {
            let pick = plan.bestPosition(positions: p, scores: s)
            XCTAssertFalse(pick.decisive, "\(name) must not be decisive")
            XCTAssertEqual(pick.position, 1.0, accuracy: 1e-12,
                           "\(name) must fall back to the infinity default")
        }
    }
}

// MARK: - FocusSweepRunTests
//
// The coarse→fine driver against scripted lens models: it must lock the model's
// peak, leave the lens there, and restore the infinity lock on a flat curve.

@MainActor
final class FocusSweepRunTests: XCTestCase {

    /// Scripted lens + sharpness model standing in for the real camera.
    private final class LensModel {
        var lens: Double = 1.0
        var setCalls: [Double] = []
        var score: (Double) -> Double
        init(score: @escaping (Double) -> Double) { self.score = score }
    }

    private func makeIO(model: LensModel,
                        steps: FocusSweepStepLog? = nil) -> FocusSweep.IO {
        FocusSweep.IO(
            setLens: { position in
                model.lens = position
                model.setCalls.append(position)
            },
            captureFrame: {
                SubFrame(index: 0, timestamp: Date(),
                         exposureSeconds: 1.0, iso: 800, pixelData: nil)
            },
            score: { _ in model.score(model.lens) },
            onStep: { step, planned in steps?.entries.append((step, planned)) })
    }

    func testSweepLocksTheModelPeakAndLeavesTheLensThere() async throws {
        let model = LensModel { lens in
            50 + 400 * exp(-pow(lens - 0.93, 2) / (2 * 0.03 * 0.03))
        }
        let steps = FocusSweepStepLog()
        let plan = FocusSweepPlan()

        let outcome = try await FocusSweep.run(plan: plan, io: makeIO(model: model, steps: steps))

        XCTAssertTrue(outcome.decisive)
        XCTAssertEqual(outcome.position, 0.93, accuracy: 0.011,
                       "The lock must land within one fine rung of the true peak")
        XCTAssertEqual(model.setCalls.last ?? -1, outcome.position, accuracy: 1e-12,
                       "The lens must be left at the locked position")
        XCTAssertEqual(outcome.positionsTried, plan.coarseSteps + plan.fineSteps)
        XCTAssertEqual(steps.entries.count, outcome.positionsTried)
        XCTAssertEqual(steps.entries.last?.0, outcome.positionsTried,
                       "Progress steps must be 1-based and complete")
        XCTAssertTrue(steps.entries.allSatisfy { $0.1 == plan.plannedPositions })
    }

    func testFlatModelRestoresTheInfinityLock() async throws {
        let model = LensModel { _ in 120 }
        let plan = FocusSweepPlan()

        let outcome = try await FocusSweep.run(plan: plan, io: makeIO(model: model))

        XCTAssertFalse(outcome.decisive)
        XCTAssertEqual(outcome.position, 1.0, accuracy: 1e-12)
        XCTAssertEqual(model.setCalls.last ?? -1, 1.0, accuracy: 1e-12,
                       "A flat curve must put the lens back on the infinity stop")
        XCTAssertEqual(outcome.positionsTried, plan.coarseSteps,
                       "A flat coarse pass must skip the fine pass entirely")
    }

    /// Models the real capture pipeline's latency: the frame delivered right
    /// after a lens move was exposed at the PREVIOUS position (that exposure
    /// was already in flight when the lens travelled). `FocusSweep.run` must
    /// burn the settle frame so every scored frame genuinely saw its own rung —
    /// without the discard, neighbouring rungs smear together and the pick can
    /// land off-peak.
    func testSettleDiscardShieldsScoresFromInFlightFrames() async throws {
        final class Pipeline {
            var lens = 1.0                 // where the lens is now
            var exposedLens = 1.0          // position the NEXT delivered frame saw
            var captures = 0
            var scoredLenses: [Double] = []
        }
        let pipe = Pipeline()
        let io = FocusSweep.IO(
            setLens: { position in pipe.lens = position },
            captureFrame: {
                pipe.captures += 1
                let sawLens = pipe.exposedLens
                pipe.exposedLens = pipe.lens   // the following frame sees the current lens
                return SubFrame(index: 0, timestamp: Date(),
                                exposureSeconds: sawLens,   // smuggle the exposed position
                                iso: 800, pixelData: nil)
            },
            score: { frame in
                pipe.scoredLenses.append(frame.exposureSeconds)
                let d = frame.exposureSeconds - 0.93
                return 50 + 400 * exp(-(d * d) / (2 * 0.03 * 0.03))
            })
        let plan = FocusSweepPlan()

        let outcome = try await FocusSweep.run(plan: plan, io: io)

        XCTAssertTrue(outcome.decisive)
        XCTAssertEqual(outcome.position, 0.93, accuracy: 1e-9,
                       "With the settle discard, the pick must land exactly on the peak rung")
        XCTAssertEqual(pipe.captures,
                       outcome.positionsTried * (plan.settleFramesPerStep + plan.framesPerStep),
                       "Each rung must spend settle + scored frames, nothing more")
        // Every scored frame must have been exposed at the rung being measured —
        // never at the previous one.
        let expectedRungs = plan.coarsePositions + plan.finePositions(around: 0.94)
        XCTAssertEqual(pipe.scoredLenses.count, expectedRungs.count * plan.framesPerStep)
        for (i, lens) in pipe.scoredLenses.enumerated() {
            XCTAssertEqual(lens, expectedRungs[i / plan.framesPerStep], accuracy: 1e-12,
                           "Scored frame \(i) must be exposed at its own rung")
        }
    }

    func testSimulatorModelSweepsToItsBuiltInPeak() async throws {
        // The simulator path simulates a peak (synthetic frames never defocus):
        // the sweep must find FocusSweepSimulator's built-in best position.
        let sim = FocusSweepSimulator()
        let io = FocusSweep.IO(
            setLens: { position in sim.setLens(position) },
            captureFrame: {
                SubFrame(index: 0, timestamp: Date(),
                         exposureSeconds: 1.0, iso: 800, pixelData: nil)
            },
            score: { _ in sim.score() })
        let outcome = try await FocusSweep.run(plan: FocusSweepPlan(), io: io)
        XCTAssertTrue(outcome.decisive)
        XCTAssertEqual(outcome.position, sim.peakPosition, accuracy: 0.011)
        XCTAssertEqual(sim.lensPosition, outcome.position, accuracy: 1e-12)
    }
}

/// Reference box for progress entries (closures can't capture inout test state).
private final class FocusSweepStepLog {
    var entries: [(Int, Int)] = []
}

// MARK: - FocusDriftAlarmTests
//
// Drift-alarm thresholds on the rolling sharpness window the focus chip uses:
// the alarm fires when the newest frame falls 30% below the rolling mean, and
// only once there are enough samples for an opinion.

final class FocusDriftAlarmTests: XCTestCase {

    private func window(recording samples: [Double]) -> RollingSharpness {
        var rolling = RollingSharpness(window: 10)
        for s in samples { rolling.record(s) }
        return rolling
    }

    func testAlarmNeedsAtLeastThreeSamples() {
        XCTAssertFalse(window(recording: []).isDegraded())
        XCTAssertFalse(window(recording: [100]).isDegraded())
        XCTAssertFalse(window(recording: [100, 40]).isDegraded(),
                       "Two samples are not enough for a drift opinion")
        XCTAssertTrue(window(recording: [100, 100, 40]).isDegraded(),
                      "Three samples are enough")
    }

    func testSteadySharpnessStaysQuiet() {
        XCTAssertFalse(window(recording: Array(repeating: 100, count: 8)).isDegraded())
    }

    func testCollapseBelowThresholdTripsTheAlarm() {
        // [100 ×5, 50]: mean ≈ 91.7, threshold 0.7 × mean ≈ 64.2 > 50 → alarm.
        XCTAssertTrue(window(recording: [100, 100, 100, 100, 100, 50]).isDegraded())
    }

    func testMildDipStaysBelowTheAlarmThreshold() {
        // [100 ×5, 80]: mean ≈ 96.7, threshold ≈ 67.7 < 80 → no alarm.
        XCTAssertFalse(window(recording: [100, 100, 100, 100, 100, 80]).isDegraded())
    }

    func testCustomFractionMovesTheThreshold() {
        let rolling = window(recording: [100, 100, 100, 100, 100, 85])
        XCTAssertFalse(rolling.isDegraded(by: 0.3))
        XCTAssertTrue(rolling.isDegraded(by: 0.1),
                      "A tighter fraction must fire on a smaller dip")
    }
}

// MARK: - FocusSweepSessionTests
//
// SessionEngine integration: the sweep stage runs for registered star stacks,
// locks the injected model's peak, skips for trails style / disabled setting /
// weak signal, and never costs stacked frames.

@MainActor
private final class FocusMockMount: MountControlling {
    var connection: MountConnection = .docked(name: "MockFlow")
    var authority: MountAuthority = .granted
    var telemetry: MountTelemetry?
    func start() {}
    func stopEverything() async {}
    func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func waitSettled() async -> Bool { true }
    func keepalivePulse() async {}
}

private final class FocusMockStacker: Stacking {
    var added = 0
    func reset(width: Int, height: Int) { added = 0 }
    func add(frame: SubFrame) -> Bool { added += 1; return true }
    func currentResult() -> StackResult {
        StackResult(accepted: added, rejected: 0,
                    integrationSeconds: Double(added), preview: nil)
    }
    func finalImage() -> CGImage? { nil }
}

/// Lens model shared between the injected focus hooks.
private final class FocusLensBox {
    var lens: Double = 1.0
    var sets: [Double] = []
}

private struct FocusTestTimeout: Error {}

@MainActor
final class FocusSweepSessionTests: XCTestCase {

    /// The engine consults the UserDefaults key "autoFocusSweep" (the Settings
    /// veto, unset means on). Pin it to "unset" for these tests so a test host
    /// whose Settings toggle was ever flipped can't switch the sweep off
    /// underneath them — and restore whatever was there afterwards.
    private var savedAutoFocusSweep: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedAutoFocusSweep = UserDefaults.standard.object(forKey: "autoFocusSweep")
        UserDefaults.standard.removeObject(forKey: "autoFocusSweep")
    }

    override func tearDown() async throws {
        if let saved = savedAutoFocusSweep {
            UserDefaults.standard.set(saved, forKey: "autoFocusSweep")
        } else {
            UserDefaults.standard.removeObject(forKey: "autoFocusSweep")
        }
        savedAutoFocusSweep = nil
        try await super.tearDown()
    }

    private func makeShot(subs: Int, style: StackingStyle = .registered) -> ShotModeItem {
        ShotModeItem(
            id: "focus-test", name: "Focus Test", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: subs,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            stackingStyle: style,
            feasibility: { _, _ in .great })
    }

    private func makeHooks() -> SessionHooks {
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
            now: { Date() },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })
    }

    /// Hooks whose focus seams model a sharpness peak at `peak`.
    private func makeFocusModelHooks(peak: Double, lens: FocusLensBox) -> SessionHooks {
        var hooks = makeHooks()
        hooks.setLensPosition = { position in
            lens.lens = Double(position)
            lens.sets.append(Double(position))
        }
        hooks.focusScore = { _ in
            50 + 400 * exp(-pow(lens.lens - peak, 2) / (2 * 0.03 * 0.03))
        }
        return hooks
    }

    private func waitUntil(timeout: TimeInterval = 10,
                           _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw FocusTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testRegisteredSessionSweepsAndLocksTheModelPeak() async throws {
        let lens = FocusLensBox()
        let stacker = FocusMockStacker()
        let engine = SessionEngine(mount: FocusMockMount(), stacker: stacker,
                                   hooks: makeFocusModelHooks(peak: 0.91, lens: lens))

        engine.start(shot: makeShot(subs: 8))
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        guard case .locked(let position, let decisive) = engine.focusSweepStatus else {
            XCTFail("Expected a locked focus verdict, got \(engine.focusSweepStatus)")
            return
        }
        XCTAssertTrue(decisive, "A clear model peak must be a decisive lock")
        XCTAssertEqual(position, 0.91, accuracy: 0.011)
        // The engine drives the lens through Float (AVFoundation's currency),
        // so the recorded position is Float-precise, not Double-precise.
        XCTAssertEqual(lens.sets.last ?? -1, position, accuracy: 1e-6,
                       "The lens must be left at the locked position for the whole stack")
        XCTAssertEqual(engine.stats.subsAccepted, 8,
                       "Sweep frames must never count as stacked subs")
        XCTAssertEqual(stacker.added, 8,
                       "Sweep frames must never reach the stacker")
    }

    func testTrailsStyleNeverSweeps() async throws {
        let lens = FocusLensBox()
        let engine = SessionEngine(mount: FocusMockMount(), stacker: FocusMockStacker(),
                                   hooks: makeFocusModelHooks(peak: 0.91, lens: lens))

        engine.start(shot: makeShot(subs: 6, style: .trails))
        try await waitUntil("phase == .complete") { engine.phase == .complete }

        XCTAssertEqual(engine.focusSweepStatus, .inactive,
                       "Trails blends clouds and all — no registered stars, no sweep")
        XCTAssertTrue(lens.sets.isEmpty, "The lens must never move for trails")
        XCTAssertEqual(engine.stats.subsAccepted, 6)
    }

    func testDisabledSettingSkipsTheSweep() async throws {
        let lens = FocusLensBox()
        let engine = SessionEngine(mount: FocusMockMount(), stacker: FocusMockStacker(),
                                   hooks: makeFocusModelHooks(peak: 0.91, lens: lens))
        engine.autoFocusSweep = false

        engine.start(shot: makeShot(subs: 6))
        try await waitUntil("phase == .complete") { engine.phase == .complete }

        XCTAssertEqual(engine.focusSweepStatus, .inactive)
        XCTAssertTrue(lens.sets.isEmpty)
        XCTAssertEqual(engine.stats.subsAccepted, 6)
    }

    func testWeakSharpnessSignalSkipsGracefully() async throws {
        // Default focus hooks + frames with no pixel data: the probe can't be
        // scored, so the sweep must skip and the session must still complete.
        let engine = SessionEngine(mount: FocusMockMount(), stacker: FocusMockStacker(),
                                   hooks: makeHooks())

        engine.start(shot: makeShot(subs: 6))
        try await waitUntil("phase == .complete") { engine.phase == .complete }

        guard case .skipped = engine.focusSweepStatus else {
            XCTFail("Expected a graceful skip, got \(engine.focusSweepStatus)")
            return
        }
        XCTAssertEqual(engine.stats.subsAccepted, 6,
                       "A skipped sweep must cost nothing but the probe frame")
        XCTAssertNil(engine.interruption)
    }
}
