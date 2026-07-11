import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - ExposurePlannerTests
//
// Pure capture-intelligence tests: exposure planning vs sky quality, the
// variance-of-Laplacian focus metric, the rolling sharpness window, and the
// storage budget math. No camera, no hardware — everything passes on the
// iOS Simulator.

final class ExposurePlannerTests: XCTestCase {

    // MARK: Fixtures

    private func skyRecipe(iso: Double, exposure: Double = 1.0) -> CaptureRecipe {
        CaptureRecipe(exposureSeconds: exposure, iso: iso,
                      targetSubCount: 100, nudgeTracking: false)
    }

    // MARK: - Exposure planning

    func testCityExposesRightAtLowGain() {
        // Milky-Way-class base (ISO 3200): city keeps the full shutter, cuts gain 4×.
        let p = ExposurePlanner.plan(base: skyRecipe(iso: 3200), quality: .city)
        XCTAssertEqual(p.iso, 800, accuracy: 1e-9)
        XCTAssertEqual(p.exposureSeconds, 1.0, accuracy: 1e-12,
                       "Expose-right means holding the shutter, not shortening it")
    }

    func testCityNeverExceedsItsISOCeiling() {
        let p = ExposurePlanner.plan(base: skyRecipe(iso: 6400), quality: .city)
        XCTAssertEqual(p.iso, ExposurePlanner.cityISOCeiling, accuracy: 1e-9)
    }

    func testCityRespectsISOFloor() {
        // 300 × 0.25 = 75 → clamped up to the 100 floor.
        let p = ExposurePlanner.plan(base: skyRecipe(iso: 300), quality: .city)
        XCTAssertEqual(p.iso, ExposurePlanner.isoFloor, accuracy: 1e-9)
    }

    func testDarkSiteRidesDimSkyRecipesAt3200Plus() {
        // Aurora-class base (1600): doubling lands exactly on the 3200 floor.
        let aurora = ExposurePlanner.plan(base: skyRecipe(iso: 1600), quality: .dark)
        XCTAssertGreaterThanOrEqual(aurora.iso, ExposurePlanner.darkSiteISOFloor)
        // Milky-Way-class base (3200): doubled to 6400, still ≥ 3200.
        let mw = ExposurePlanner.plan(base: skyRecipe(iso: 3200), quality: .dark)
        XCTAssertEqual(mw.iso, 6400, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(mw.iso, ExposurePlanner.darkSiteISOFloor)
    }

    func testDarkClampsAtTheCeiling() {
        let p = ExposurePlanner.plan(base: skyRecipe(iso: 6400), quality: .dark)
        XCTAssertEqual(p.iso, ExposurePlanner.isoCeiling, accuracy: 1e-9)
    }

    func testTargetLitRecipesAreQualityBlind() {
        // Lunar (ISO 100, 1/125 s) and City Nights (ISO 100, 1 s): the subject
        // provides the photons — sky quality must not touch the recipe.
        let lunar = CaptureRecipe(exposureSeconds: 0.008, iso: 100,
                                  targetSubCount: 150, nudgeTracking: true)
        for quality in SkyQuality.allCases {
            let p = ExposurePlanner.plan(base: lunar, quality: quality)
            XCTAssertEqual(p.iso, 100, accuracy: 1e-9, "\(quality) changed a target-lit ISO")
            XCTAssertEqual(p.exposureSeconds, 0.008, accuracy: 1e-12,
                           "\(quality) changed a target-lit exposure")
        }
    }

    func testMidQualityScaling() {
        // ISS-class base (800): suburb halves, rural is the native recipe.
        XCTAssertEqual(ExposurePlanner.plan(base: skyRecipe(iso: 800), quality: .suburb).iso,
                       400, accuracy: 1e-9)
        XCTAssertEqual(ExposurePlanner.plan(base: skyRecipe(iso: 800), quality: .rural).iso,
                       800, accuracy: 1e-9)
    }

    func testISOIsMonotonicFromCityToDark() {
        for baseISO in [400.0, 800.0, 1600.0, 3200.0, 6400.0] {
            let base = skyRecipe(iso: baseISO)
            let isos = [SkyQuality.city, .suburb, .rural, .dark]
                .map { ExposurePlanner.plan(base: base, quality: $0).iso }
            for i in 1..<isos.count {
                XCTAssertLessThanOrEqual(isos[i - 1], isos[i],
                                         "ISO must not decrease city→dark (base \(baseISO))")
            }
        }
    }

    func testExposureNeverExceedsTheOneSecondCap() {
        // CaptureRecipe already caps at init; the plan must never undo that.
        let base = CaptureRecipe(exposureSeconds: 5.0, iso: 1600,
                                 targetSubCount: 60, nudgeTracking: false)
        for quality in SkyQuality.allCases {
            let p = ExposurePlanner.plan(base: base, quality: quality)
            XCTAssertLessThanOrEqual(p.exposureSeconds, 1.0,
                                     "\(quality) broke the 1 s third-party cap")
        }
    }

    func testAdjustedRecipeKeepsThePlanShape() {
        // Timelapse-like base: only exposure/ISO may change — the plan shape
        // (sub count, tracking, cadence) is the mode's contract.
        let base = CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: 240,
                                 nudgeTracking: false, intervalSeconds: 30)
        let adjusted = ExposurePlanner.adjustedRecipe(base: base, quality: .dark)
        XCTAssertEqual(adjusted.iso, 1600, accuracy: 1e-9)
        XCTAssertEqual(adjusted.targetSubCount, 240)
        XCTAssertFalse(adjusted.nudgeTracking)
        XCTAssertEqual(adjusted.intervalSeconds, 30, accuracy: 1e-12)
    }

    // MARK: - Focus metric (variance of Laplacian)

    /// Gaussian starfield with flux-normalized amplitudes: blurring spreads the same
    /// light over more pixels, so the sharp field has much larger second derivatives.
    private func starField(sigma: Double, width: Int = 64, height: Int = 64) -> [Float] {
        var buffer = [Float](repeating: 0.05, count: width * height)
        let centers = [(16.0, 16.0), (44.0, 20.0), (28.0, 44.0), (52.0, 52.0), (10.0, 40.0)]
        let amp = 0.9 * (1.2 * 1.2) / (sigma * sigma)   // equal total flux across sigmas
        for (cx, cy) in centers {
            for y in 0..<height {
                for x in 0..<width {
                    let dx = Double(x) - cx
                    let dy = Double(y) - cy
                    buffer[y * width + x] +=
                        Float(amp * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)))
                }
            }
        }
        for i in 0..<buffer.count { buffer[i] = min(1, max(0, buffer[i])) }
        return buffer
    }

    func testLaplacianVarianceIsZeroOnAFlatField() {
        let flat = [Float](repeating: 0.42, count: 64 * 64)
        XCTAssertEqual(FocusMetric.laplacianVariance(flat, width: 64, height: 64),
                       0, accuracy: 1e-12)
    }

    func testLaplacianVarianceRanksSharpAboveBlurred() {
        let sharp = FocusMetric.laplacianVariance(starField(sigma: 1.2), width: 64, height: 64)
        let blurred = FocusMetric.laplacianVariance(starField(sigma: 3.0), width: 64, height: 64)
        XCTAssertGreaterThan(sharp, 0)
        XCTAssertGreaterThan(blurred, 0)
        XCTAssertGreaterThan(sharp, blurred * 3,
                             "In-focus stars must score decisively higher than defocused blobs")
    }

    func testLaplacianVarianceIsDeterministic() {
        let field = starField(sigma: 1.5)
        XCTAssertEqual(FocusMetric.laplacianVariance(field, width: 64, height: 64),
                       FocusMetric.laplacianVariance(field, width: 64, height: 64))
    }

    func testLaplacianVarianceRejectsDegenerateInput() {
        XCTAssertEqual(FocusMetric.laplacianVariance([0.5, 0.5], width: 2, height: 1), 0)
        XCTAssertEqual(FocusMetric.laplacianVariance([Float](repeating: 0, count: 10),
                                                     width: 64, height: 64), 0,
                       "Mismatched buffer size must return 0, not crash")
    }

    func testSharpnessOfCGImageTracksTheBufferMetric() throws {
        let sharpImage = try XCTUnwrap(
            CPUStacker.grayImage(from: starField(sigma: 1.2), width: 64, height: 64))
        let blurredImage = try XCTUnwrap(
            CPUStacker.grayImage(from: starField(sigma: 3.0), width: 64, height: 64))
        let sharp = try XCTUnwrap(FocusMetric.sharpness(of: sharpImage, sampleWidth: 64))
        let blurred = try XCTUnwrap(FocusMetric.sharpness(of: blurredImage, sampleWidth: 64))
        XCTAssertGreaterThan(sharp, 0)
        XCTAssertGreaterThan(sharp, blurred,
                             "The CGImage path must preserve the sharpness ordering")
    }

    func testRollingSharpnessWindowAndDegradationAlarm() {
        var rolling = RollingSharpness(window: 3)
        XCTAssertNil(rolling.mean)
        XCTAssertFalse(rolling.isDegraded(), "No opinion without samples")

        rolling.record(10)
        rolling.record(10)
        XCTAssertFalse(rolling.isDegraded(), "Needs at least 3 samples for an opinion")

        rolling.record(10)
        XCTAssertEqual(rolling.mean ?? 0, 10, accuracy: 1e-12)
        XCTAssertFalse(rolling.isDegraded())

        rolling.record(4)   // window slides to [10, 10, 4]; mean 8; 4 < 8 × 0.7
        XCTAssertEqual(rolling.count, 3, "Window must stay capped")
        XCTAssertEqual(rolling.latest ?? 0, 4, accuracy: 1e-12)
        XCTAssertEqual(rolling.mean ?? 0, 8, accuracy: 1e-12)
        XCTAssertTrue(rolling.isDegraded(), "A sharp drop below the mean is the focus alarm")

        rolling.reset()
        XCTAssertEqual(rolling.count, 0)
        XCTAssertNil(rolling.latest)
        XCTAssertFalse(rolling.isDegraded())
    }

    // MARK: - Storage budget

    func testBytesPerFrameEstimates() {
        let recipe = skyRecipe(iso: 3200)
        XCTAssertEqual(StorageBudget.estimatedBytesPerFrame(recipe: recipe, keepingSubs: true),
                       StorageBudget.hevcBytesPerFrame + StorageBudget.bayerRawBytesPerFrame)
        XCTAssertEqual(StorageBudget.estimatedBytesPerFrame(recipe: recipe, keepingSubs: false),
                       StorageBudget.transientBytesPerFrame)
    }

    func testPlannedSessionBytesScalesWithTheSubCount() {
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 800,
                                   targetSubCount: 100, nudgeTracking: false)
        XCTAssertEqual(StorageBudget.plannedSessionBytes(recipe: recipe, bytesPerFrame: 10_000_000),
                       StorageBudget.sessionOverheadBytes + 1_000_000_000)
        XCTAssertGreaterThan(StorageBudget.plannedSessionBytes(recipe: recipe, keepingSubs: true),
                             StorageBudget.plannedSessionBytes(recipe: recipe, keepingSubs: false),
                             "Persisting RAW subs must dominate the plan")
    }

    func testVerdictThresholds() {
        let planned: Int64 = 2_000_000_000
        // refuse below planned + 1 GB reserve = 3.0 GB
        XCTAssertEqual(StorageBudget.verdict(freeBytes: 2_900_000_000, plannedBytes: planned),
                       .refuse)
        // warn under planned × 1.25 + reserve = 3.5 GB
        XCTAssertEqual(StorageBudget.verdict(freeBytes: 3_000_000_000, plannedBytes: planned),
                       .warn)
        XCTAssertEqual(StorageBudget.verdict(freeBytes: 3_200_000_000, plannedBytes: planned),
                       .warn)
        XCTAssertEqual(StorageBudget.verdict(freeBytes: 3_600_000_000, plannedBytes: planned),
                       .ok)
        // Unknown free space can't refuse — the in-flight guardian still protects.
        XCTAssertEqual(StorageBudget.verdict(freeBytes: nil, plannedBytes: planned), .ok)
    }
}

// MARK: - Session storage pre-flight (integration)

// Minimal file-private doubles (prefixed to avoid target-wide collisions).

@MainActor
private final class PreflightMockMount: MountControlling {
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

private final class PreflightMockStacker: Stacking {
    func reset(width: Int, height: Int) {}
    func add(frame: SubFrame) -> Bool { true }
    func currentResult() -> StackResult {
        StackResult(accepted: 0, rejected: 0, integrationSeconds: 0, preview: nil)
    }
    func finalImage() -> CGImage? { nil }
}

private struct PreflightTestTimeout: Error {}

@MainActor
final class SessionStoragePreflightTests: XCTestCase {

    private func makeShot(subs: Int) -> ShotModeItem {
        ShotModeItem(
            id: "preflight", name: "Preflight Shot", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: subs,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            feasibility: { _, _ in .great })
    }

    private func makeHooks(freeDisk: @escaping @MainActor () -> Int64?,
                           bytesPerFrame: Int64) -> SessionHooks {
        var hooks = SessionHooks(
            prepareCapture: { _ in (8, 8) },
            captureSub: { recipe, index in
                try await Task.sleep(nanoseconds: 1_000_000)
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                                pixelData: nil)
            },
            endCapture: {},
            thermalState: { .nominal },
            batteryPercent: { 80 },
            freeDiskBytes: freeDisk,
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0.5) },
            now: { Date() },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })
        hooks.estimatedBytesPerFrame = { _ in bytesPerFrame }
        return hooks
    }

    private func waitUntil(timeout: TimeInterval = 10,
                           _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw PreflightTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testRefusesBeforeTheFirstSubWhenTheDiskCannotHoldThePlan() async throws {
        // 12 subs × 100 MB + 250 MB overhead = 1.45 GB planned, 1.2 GB free.
        // Free space is ABOVE the 1 GB in-flight floor (the mid-capture guardian
        // would not fire) but below planned + reserve — the pre-flight must refuse.
        let engine = SessionEngine(mount: PreflightMockMount(),
                                   stacker: PreflightMockStacker(),
                                   hooks: makeHooks(freeDisk: { 1_200_000_000 },
                                                    bytesPerFrame: 100_000_000))
        engine.start(shot: makeShot(subs: 12))
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(engine.stats.subsAccepted, 0,
                       "The refuse must land before the first sub is captured")
        XCTAssertEqual(engine.interruption, .storageLow,
                       "The stop reason must stay visible for the landing report")
    }

    func testRunsToCompletionWithComfortableHeadroom() async throws {
        // 12 subs × 30 MB + overhead ≈ 0.6 GB planned against 64 GB free → ok.
        let engine = SessionEngine(mount: PreflightMockMount(),
                                   stacker: PreflightMockStacker(),
                                   hooks: makeHooks(freeDisk: { 64_000_000_000 },
                                                    bytesPerFrame: 30_000_000))
        engine.start(shot: makeShot(subs: 12))
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(engine.stats.subsAccepted, 12)
        XCTAssertNil(engine.interruption)
    }
}
