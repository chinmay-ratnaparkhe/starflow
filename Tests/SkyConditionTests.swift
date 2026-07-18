import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - Test doubles (file-private; names prefixed to avoid target-wide collisions)

@MainActor
private final class SkyMockMount: MountControlling {
    var connection: MountConnection = .docked(name: "MockFlow")
    var authority: MountAuthority = .granted
    var telemetry: MountTelemetry? = MountTelemetry(pitchDeg: 5, yawDeg: 120,
                                                    speedDegPerSec: 0, batteryPercent: 87)
    func start() {}
    func stopEverything() async {}
    func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func waitSettled() async -> Bool { true }
    func keepalivePulse() async {}
}

/// Accept-everything stacker that counts `add` calls, so tests can prove the
/// engine's cloud gate skipped the accumulate (frames captured, never added).
private final class SkyMockStacker: Stacking {
    var added = 0
    func reset(width: Int, height: Int) { added = 0 }
    func add(frame: SubFrame) -> Bool { added += 1; return true }
    func currentResult() -> StackResult {
        StackResult(accepted: added, rejected: 0, integrationSeconds: Double(added), preview: nil)
    }
    func finalImage() -> CGImage? { nil }
}

private struct SkyTestTimeout: Error {}

// MARK: - Tests

@MainActor
final class SkyConditionTests: XCTestCase {

    // MARK: Scripted-sequence helpers

    /// Feed (starCount, background) pairs one second apart; returns the
    /// resulting condition.
    @discardableResult
    private func feed(_ monitor: SkyConditionMonitor,
                      _ sequence: [(stars: Int, bg: Double)],
                      startingAt t0: TimeInterval = 0) -> SkyCondition {
        var condition = monitor.condition
        for (offset, sample) in sequence.enumerated() {
            condition = monitor.ingest(SkyObservation(
                starCount: sample.stars,
                backgroundLevel: sample.bg,
                timestamp: Date(timeIntervalSinceReferenceDate: t0 + Double(offset))))
        }
        return condition
    }

    private func clearFrames(_ count: Int) -> [(stars: Int, bg: Double)] {
        Array(repeating: (stars: 40, bg: 0.05), count: count)
    }

    // MARK: Classification — each state is reachable

    func testWarmupPromotesToClearOnlyAfterHysteresis() {
        let monitor = SkyConditionMonitor()
        XCTAssertEqual(monitor.condition, .unknown)
        feed(monitor, clearFrames(2))
        XCTAssertEqual(monitor.condition, .unknown,
                       "Two frames must not be enough to promote out of .unknown")
        feed(monitor, clearFrames(1), startingAt: 2)
        XCTAssertEqual(monitor.condition, .clear)
        XCTAssertEqual(monitor.baselineStarCount, 40, accuracy: 0.01)
        XCTAssertEqual(monitor.baselineBackground, 0.05, accuracy: 1e-9)
    }

    func testStarCollapsePlusBackgroundRiseClassifiesCloudy() {
        let monitor = SkyConditionMonitor()
        feed(monitor, clearFrames(5))
        XCTAssertEqual(monitor.condition, .clear)

        // Clouds: stars collapse to 3/40, background rises 0.05 → 0.09.
        feed(monitor, [(3, 0.09), (3, 0.09)], startingAt: 5)
        XCTAssertEqual(monitor.condition, .clear,
                       "Two cloudy votes must not flip the state yet (hysteresis)")
        feed(monitor, [(3, 0.09)], startingAt: 7)
        XCTAssertEqual(monitor.condition, .cloudy)
        XCTAssertEqual(monitor.lastTransition?.from, .clear)
        XCTAssertEqual(monitor.lastTransition?.to, .cloudy)
    }

    func testModerateStarLossClassifiesHazyNotCloudy() {
        let monitor = SkyConditionMonitor()
        feed(monitor, clearFrames(5))
        // 18/40 = 45% of baseline, background unchanged: haze, not clouds.
        feed(monitor, [(18, 0.05), (18, 0.05), (18, 0.05)], startingAt: 5)
        XCTAssertEqual(monitor.condition, .hazy)
    }

    func testSustainedNearSaturationBackgroundClassifiesOverexposed() {
        let monitor = SkyConditionMonitor()
        feed(monitor, clearFrames(5))
        feed(monitor, [(30, 0.40)], startingAt: 5)
        XCTAssertEqual(monitor.condition, .clear,
                       "A single bright frame must not flip the verdict")
        feed(monitor, [(30, 0.40), (30, 0.40)], startingAt: 6)
        XCTAssertEqual(monitor.condition, .overexposed)
    }

    func testOverexposedNeedsNoStarBaseline() {
        // City twilight: never any stars, background pinned near saturation.
        let monitor = SkyConditionMonitor()
        feed(monitor, [(0, 0.5), (0, 0.5), (0, 0.5)])
        XCTAssertEqual(monitor.condition, .overexposed)
    }

    func testRecoveryFromCloudsBackToClear() {
        let monitor = SkyConditionMonitor()
        feed(monitor, clearFrames(5))
        feed(monitor, [(2, 0.09), (2, 0.09), (2, 0.09)], startingAt: 5)
        XCTAssertEqual(monitor.condition, .cloudy)

        feed(monitor, clearFrames(2), startingAt: 8)
        XCTAssertEqual(monitor.condition, .cloudy, "Recovery also needs the hysteresis dwell")
        feed(monitor, clearFrames(1), startingAt: 10)
        XCTAssertEqual(monitor.condition, .clear)
        XCTAssertEqual(monitor.lastTransition?.from, .cloudy)
        XCTAssertEqual(monitor.lastTransition?.to, .clear)
    }

    // MARK: Hysteresis — no flapping

    func testAlternatingFramesNeverFlapTheState() {
        let monitor = SkyConditionMonitor()
        feed(monitor, clearFrames(5))
        XCTAssertEqual(monitor.condition, .clear)

        // Alternate single cloudy-looking and clear frames: consecutive-vote
        // hysteresis must hold .clear through every one of them.
        var t: TimeInterval = 5
        for _ in 0..<6 {
            let afterCloudy = feed(monitor, [(3, 0.09)], startingAt: t)
            XCTAssertEqual(afterCloudy, .clear, "One-frame blip must not flap the state")
            let afterClear = feed(monitor, clearFrames(1), startingAt: t + 1)
            XCTAssertEqual(afterClear, .clear)
            t += 2
        }
    }

    // MARK: Honesty — no baseline, no verdict

    func testStarlessSceneStaysUnknownInsteadOfCloudy() {
        // A lunar close-up or an indoor test never establishes a starry
        // baseline — the monitor must refuse to call that "cloudy".
        let monitor = SkyConditionMonitor()
        for (i, sample) in [(2, 0.08), (0, 0.06), (1, 0.07), (2, 0.08), (0, 0.06),
                            (1, 0.07), (2, 0.08), (0, 0.06), (1, 0.07), (2, 0.08)].enumerated() {
            let c = monitor.ingest(SkyObservation(
                starCount: sample.0, backgroundLevel: sample.1,
                timestamp: Date(timeIntervalSinceReferenceDate: Double(i))))
            XCTAssertEqual(c, .unknown, "Frame \(i): no starry baseline → no verdict")
        }
    }

    func testResetForgetsEverything() {
        let monitor = SkyConditionMonitor()
        feed(monitor, clearFrames(5))
        feed(monitor, [(2, 0.09), (2, 0.09), (2, 0.09)], startingAt: 5)
        XCTAssertEqual(monitor.condition, .cloudy)

        monitor.reset()
        XCTAssertEqual(monitor.condition, .unknown)
        XCTAssertNil(monitor.lastObservation)
        XCTAssertNil(monitor.lastTransition)
        XCTAssertEqual(feed(monitor, clearFrames(3)), .clear)
    }

    // MARK: Frame measurement (CPUStacker maths reused)

    func testMeasureFindsStarsAndBackgroundInSyntheticFrame() throws {
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 3200,
                                   targetSubCount: 1, nudgeTracking: false)
        let frame = SessionHooks.syntheticFrame(recipe: recipe, index: 0)
        let image = try XCTUnwrap(frame.pixelData)
        let side = SessionHooks.syntheticSize
        let obs = try XCTUnwrap(SkyConditionMonitor.measure(
            image: image, width: side, height: side, at: frame.timestamp))
        XCTAssertGreaterThanOrEqual(obs.starCount, 10,
                                    "The synthetic starfield must read as starry")
        XCTAssertLessThan(obs.backgroundLevel, 0.1,
                          "The synthetic sky background is dark")
        XCTAssertEqual(obs.timestamp, frame.timestamp)
    }

    func testMeasureFlatBrightFrameReadsStarlessAndBright() throws {
        let image = try XCTUnwrap(Self.flatGrayImage(side: 256, gray: 0.5))
        let obs = try XCTUnwrap(SkyConditionMonitor.measure(
            image: image, width: 256, height: 256, at: Date()))
        XCTAssertEqual(obs.starCount, 0)
        XCTAssertEqual(obs.backgroundLevel, 0.5, accuracy: 0.02)
    }

    func testCPUStackerPublishesPerFrameSkyObservation() throws {
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 3200,
                                   targetSubCount: 1, nudgeTracking: false)
        let stacker = CPUStacker()
        let side = SessionHooks.syntheticSize
        stacker.reset(width: side, height: side)
        XCTAssertNil(stacker.lastSkyObservation)

        let frame = SessionHooks.syntheticFrame(recipe: recipe, index: 0)
        XCTAssertTrue(stacker.add(frame: frame))
        let obs = try XCTUnwrap(stacker.lastSkyObservation)
        XCTAssertGreaterThanOrEqual(obs.starCount, 10)
        XCTAssertLessThan(obs.backgroundLevel, 0.1)
        XCTAssertEqual(obs.timestamp, frame.timestamp,
                       "Observation must be tagged with the frame it came from")

        stacker.reset(width: side, height: side)
        XCTAssertNil(stacker.lastSkyObservation, "reset must clear the observation")
    }

    // MARK: Engine integration — cloud gate

    /// Registered-stack session under a scripted sky: 6 starry frames, 6 flat
    /// cloudy frames, then stars again. The engine must classify cloudy after
    /// the hysteresis dwell, skip the accumulate while cloudy (frames counted
    /// as rejected, stacker untouched), notice the gap, and resume stacking.
    @MainActor
    func testEngineSkipsAccumulateWhileCloudyThenResumes() async throws {
        let (engine, stacker) = makeEngine(stackingStyle: .registered, targetSubs: 24)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        // Frames 0–8 accumulate (condition flips to .cloudy after frame 8's
        // observation); frames 9–14 are skipped while cloudy (clear votes on
        // 12–14 satisfy the dwell); frames 15–23 accumulate again.
        XCTAssertEqual(stacker.added, 18, "Cloudy frames must not reach the stacker")
        XCTAssertEqual(engine.stats.subsAccepted, 18)
        XCTAssertEqual(engine.stats.subsRejected, 6,
                       "Skipped frames are honestly counted as rejected")
        XCTAssertEqual(engine.skyCondition, .clear,
                       "The monitor must notice the sky clearing during the pause")
        XCTAssertEqual(engine.stats.skyCondition, .clear)
    }

    /// Same scripted sky, trails style: clouds are part of the shot — every
    /// frame must reach the blender, nothing is skipped.
    @MainActor
    func testEngineNeverGatesTrailsStyleOnClouds() async throws {
        let (engine, stacker) = makeEngine(stackingStyle: .trails, targetSubs: 24)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(stacker.added, 24)
        XCTAssertEqual(engine.stats.subsAccepted, 24)
        XCTAssertEqual(engine.stats.subsRejected, 0)
    }

    // MARK: Engine fixtures

    /// Engine wired to a scripted sky: frames 0–5 starfield, 6–11 flat cloudy
    /// gray, 12+ starfield again. Injected mock stacker accepts everything, so
    /// every skipped frame is provably the engine's cloud gate.
    @MainActor
    private func makeEngine(stackingStyle: StackingStyle,
                            targetSubs: Int) -> (SessionEngine, SkyMockStacker) {
        let side = SessionHooks.syntheticSize
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 800,
                                   targetSubCount: targetSubs, nudgeTracking: false)
        let starImage = SessionHooks.syntheticFrame(recipe: recipe, index: 0).pixelData
        let cloudImage = Self.flatGrayImage(side: side, gray: 0.12)
        let hooks = SessionHooks(
            prepareCapture: { _ in (side, side) },
            captureSub: { recipe, index in
                try await Task.sleep(nanoseconds: 2_000_000)
                let cloudy = (6...11).contains(index)
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                                pixelData: cloudy ? cloudImage : starImage)
            },
            endCapture: {},
            thermalState: { .nominal },
            batteryPercent: { 80 },
            freeDiskBytes: { 64_000_000_000 },
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0.5) },
            now: { Date() },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })

        let stacker = SkyMockStacker()
        let engine = SessionEngine(mount: SkyMockMount(), stacker: stacker, hooks: hooks)
        let shot = ShotModeItem(
            id: "skytest", name: "Sky Test", tagline: "test", symbol: "star",
            recipe: recipe, expectation: "test", tutorial: [], cityViable: true,
            needsGimbal: true, stackingStyle: stackingStyle,
            feasibility: { _, _ in .great })
        engine.start(shot: shot)
        return (engine, stacker)
    }

    private func waitUntil(timeout: TimeInterval = 15,
                           _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw SkyTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Image fixtures

    private static func flatGrayImage(side: Int, gray: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }
}
