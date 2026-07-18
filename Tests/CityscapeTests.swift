import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - Synthetic city scene (shared by the composer + session tests)

/// Deterministic synthetic scene: a bright, textured city band below a hard
/// horizon row, dark starry sky above — the exact bright-below/dark-above
/// geometry the v1 luminance mask is built for. No hardware, no fixtures.
private enum CityScene {
    static let width = 160
    static let height = 120
    static let horizonRow = 70

    /// A star the sky stack must deliver into the composite (2×2 block so it
    /// survives 8-bit quantization), well above the 12 px feather band.
    static let starX = 40
    static let starY = 30
    /// A sky pixel guaranteed starless (see `skyPlane`'s star grid).
    static let darkSkyX = 100
    static let darkSkyY = 20

    /// Foreground luminance: sky rows flat 0.05, city rows 0.62 with a window
    /// grid (+0.08) so the city is both brighter AND busier than the sky —
    /// the two statistics the row score measures.
    static func cityLuma(cityLevel: Float = 0.62) -> [Float] {
        var luma = [Float](repeating: 0.05, count: width * height)
        for y in horizonRow..<height {
            for x in 0..<width {
                let window: Float = ((x / 8) + (y / 6)) % 2 == 0 ? 0.08 : 0
                luma[y * width + x] = cityLevel + window
            }
        }
        return luma
    }

    /// Sky-stack luminance: near-black background with a deterministic grid of
    /// bright stars in the top rows (all above `horizonRow` − feather band).
    static func skyLuma() -> [Float] {
        var luma = [Float](repeating: 0.02, count: width * height)
        for i in 0..<12 {
            let sx = 16 + (i * 24) % (width - 20)
            let sy = 8 + (i * 9) % 40
            for dy in 0...1 {
                for dx in 0...1 {
                    luma[(sy + dy) * width + (sx + dx)] = 1.0
                }
            }
        }
        // The named star the composite assertion samples.
        for dy in 0...1 {
            for dx in 0...1 {
                luma[(starY + dy) * width + (starX + dx)] = 1.0
            }
        }
        return luma
    }

    /// Neutral RGB CGImage from one luminance plane.
    static func image(_ luma: [Float]) throws -> CGImage {
        try XCTUnwrap(CPUStacker.rgbImage(r: luma, g: luma, b: luma,
                                          width: width, height: height),
                      "failed to build synthetic CGImage")
    }

    /// Per-pixel scaled copy (bracket exposure simulation), clamped 0…1.
    static func scaled(_ luma: [Float], by factor: Float) -> [Float] {
        luma.map { min(1, max(0, $0 * factor)) }
    }

    /// Rec.709 luminance of a CGImage resampled at scene size.
    static func luminance(of image: CGImage) throws -> [Float] {
        let planes = try XCTUnwrap(
            CPUStacker.rgbFloats(from: image, width: width, height: height))
        var out = [Float](repeating: 0, count: planes.r.count)
        for i in 0..<out.count {
            out[i] = 0.2126 * planes.r[i] + 0.7152 * planes.g[i] + 0.0722 * planes.b[i]
        }
        return out
    }
}

// MARK: - Composer tests

/// CityscapeComposer verification on synthetic scenes (feature 10, v1).
/// Design gates: the mask finds a clean bright-below/dark-above horizon within
/// 3 px; the composite keeps the city bright below and the sky's stars above;
/// a low-contrast scene honestly reads LOW confidence and yields NO composite
/// (foreground-only, reason stated); bracket fusion favors unclipped pixels.
final class CityscapeTests: XCTestCase {

    // MARK: Horizon mask

    /// Bright bottom band + dark starry top → the estimated horizon lands
    /// within 3 px of the true boundary, in every column and on average.
    func testHorizonFoundWithinThreePixels() throws {
        let estimate = try XCTUnwrap(
            CityscapeComposer.estimateHorizon(luma: CityScene.cityLuma(),
                                              width: CityScene.width,
                                              height: CityScene.height),
            "a 160×120 frame is analysable")
        XCTAssertEqual(estimate.confidence, .high,
                       "a 0.05 / 0.62 split with window texture must read high "
                       + "(measured separation \(estimate.separation))")
        XCTAssertEqual(estimate.meanRow, Double(CityScene.horizonRow), accuracy: 3.0)
        let worst = estimate.perColumn
            .map { abs($0 - CityScene.horizonRow) }.max() ?? .max
        XCTAssertLessThanOrEqual(worst, 3,
                                 "every column's boundary must land within 3 px "
                                 + "of the true horizon (worst \(worst))")
    }

    /// A gravity-prior sanity check on the mask preview: white sky above the
    /// boundary, black city below, feathered between.
    func testMaskPreviewIsWhiteAboveBlackBelow() throws {
        let horizon = [Int](repeating: CityScene.horizonRow, count: CityScene.width)
        let mask = try XCTUnwrap(
            CityscapeComposer.maskPreviewImage(horizon: horizon,
                                               width: CityScene.width,
                                               height: CityScene.height))
        let luma = try CityScene.luminance(of: mask)
        let w = CityScene.width
        XCTAssertGreaterThan(luma[10 * w + 80], 0.9, "well above the horizon = sky (white)")
        XCTAssertLessThan(luma[110 * w + 80], 0.1, "well below the horizon = city (black)")
    }

    // MARK: Full composite

    /// End-to-end compose on the synthetic scene: robust-meaned base frames +
    /// bracket fusion + mask + feathered blend. The city must stay bright
    /// below the horizon and the sky stack's stars must land above it.
    func testCompositePreservesForegroundBrightnessAndSkyStars() throws {
        let base = CityScene.cityLuma()
        let baseImage = try CityScene.image(base)
        // −2 EV / +1 EV bracket frames as straight exposure scalings.
        let under = try CityScene.image(CityScene.scaled(base, by: 0.25))
        let over = try CityScene.image(CityScene.scaled(base, by: 2.0))
        let sky = try CityScene.image(CityScene.skyLuma())

        let outcome = CityscapeComposer.compose(
            baseFrames: [CGImage](repeating: baseImage, count: 7),
            underExposed: under, overExposed: over, sky: sky)

        XCTAssertNotNil(outcome.composite, "a clean horizon must produce a composite")
        XCTAssertNotEqual(outcome.confidence, .low)
        XCTAssertNotNil(outcome.maskPreview)
        XCTAssertNotNil(outcome.foreground)
        let meanRow = try XCTUnwrap(outcome.horizonMeanRow)
        XCTAssertEqual(meanRow, Double(CityScene.horizonRow), accuracy: 3.0)
        XCTAssertFalse(outcome.reason.isEmpty, "the reason line always narrates honestly")

        let luma = try CityScene.luminance(of: XCTUnwrap(outcome.composite))
        let w = CityScene.width
        // City brightness preserved well below the 12 px feather band. The
        // pyramid-free fusion pulls a clipped +1 EV toward the unclipped
        // frames, so "preserved" means solidly bright, not byte-identical.
        var citySum: Float = 0
        for x in 0..<w { citySum += luma[100 * w + x] }
        XCTAssertGreaterThan(citySum / Float(w), 0.45,
                             "the fused city must stay bright below the horizon")
        // The sky stack's star survives into the composite; starless sky stays dark.
        XCTAssertGreaterThan(luma[CityScene.starY * w + CityScene.starX], 0.5,
                             "a sky-stack star must land in the composite")
        XCTAssertLessThan(luma[CityScene.darkSkyY * w + CityScene.darkSkyX], 0.15,
                          "starless sky in the composite comes from the dark sky stack")
    }

    /// Low-contrast scene (uniform mid-gray, no boundary) → LOW confidence,
    /// NO composite, foreground-only with the honest reason. Never a bad
    /// composite silently.
    func testLowContrastSceneYieldsLowConfidenceAndForegroundOnly() throws {
        let flat = [Float](repeating: 0.4, count: CityScene.width * CityScene.height)
        let estimate = try XCTUnwrap(
            CityscapeComposer.estimateHorizon(luma: flat, width: CityScene.width,
                                              height: CityScene.height))
        XCTAssertEqual(estimate.confidence, .low,
                       "a featureless frame must never claim a horizon")

        let flatImage = try CityScene.image(flat)
        let sky = try CityScene.image(CityScene.skyLuma())
        let outcome = CityscapeComposer.compose(
            baseFrames: [CGImage](repeating: flatImage, count: 7),
            underExposed: flatImage, overExposed: flatImage, sky: sky)
        XCTAssertNil(outcome.composite, "low confidence must withhold the composite")
        XCTAssertEqual(outcome.confidence, .low)
        XCTAssertNotNil(outcome.foreground, "the fused foreground is still delivered")
        XCTAssertNotNil(outcome.skyImage, "the sky stack is still delivered separately")
        XCTAssertTrue(outcome.reason.contains("No confident horizon"),
                      "the reason must say WHY there is no composite: \(outcome.reason)")
    }

    /// No foreground at all → no composite, and the reason says so.
    func testNoForegroundFramesIsHonest() {
        let outcome = CityscapeComposer.compose(baseFrames: [], underExposed: nil,
                                                overExposed: nil, sky: nil)
        XCTAssertNil(outcome.composite)
        XCTAssertEqual(outcome.confidence, .low)
        XCTAssertFalse(outcome.reason.isEmpty)
    }

    // MARK: Bracket fusion

    /// Well-exposedness weighting must pull a clipped highlight toward the
    /// unclipped bracket frame, and leave an already well-exposed pixel
    /// essentially where it was.
    func testBracketFusionFavorsUnclippedPixels() throws {
        // Two 1-pixel-logic frames on a 16×16 grid (the composer's minimum):
        // index 0 = clipped highlight, index 1 = well-exposed midtone.
        let count = 16 * 16
        var baseR = [Float](repeating: 0.5, count: count)
        var underR = [Float](repeating: 0.125, count: count)
        baseR[0] = 1.0       // clipped in the base…
        underR[0] = 0.35     // …but held by the −2 EV frame
        let base = CityscapeComposer.Planes(r: baseR, g: baseR, b: baseR)
        let under = CityscapeComposer.Planes(r: underR, g: underR, b: underR)

        let fused = try XCTUnwrap(CityscapeComposer.fuseExposures([base, under]))
        // Clipped pixel: the unclipped 0.35 must dominate the blend.
        XCTAssertLessThan(fused.r[0], 0.55,
                          "a clipped highlight must be pulled toward the unclipped frame")
        XCTAssertGreaterThan(fused.r[0], 0.3)
        // Well-exposed pixel: 0.5 carries near-maximum weight and must stay put.
        XCTAssertEqual(fused.r[1], 0.5, accuracy: 0.08,
                       "a well-exposed pixel keeps its value through fusion")
    }

    /// Uniform planes (every weight tiny) must still fuse — the weight floor
    /// forbids a divide-by-zero.
    func testFusionSurvivesUniformExtremeFrames() throws {
        let count = 16 * 16
        let black = [Float](repeating: 0, count: count)
        let planes = CityscapeComposer.Planes(r: black, g: black, b: black)
        let fused = try XCTUnwrap(CityscapeComposer.fuseExposures([planes, planes]))
        XCTAssertEqual(fused.r[0], 0, accuracy: 1e-5)
    }

    // MARK: Robust mean

    /// With 4+ frames the per-pixel min and max are dropped: one headlight
    /// streak in one frame must vanish from the mean entirely.
    func testRobustMeanDropsOutlierFrame() {
        let steady = [Float](repeating: 0.5, count: 64)
        var headlight = steady
        for i in 0..<16 { headlight[i] = 1.0 }
        let mean = CityscapeComposer.robustMean([steady, steady, steady,
                                                 steady, steady, headlight])
        XCTAssertEqual(mean[0], 0.5, accuracy: 1e-5,
                       "the trimmed mean must drop the headlight sample outright")
        XCTAssertEqual(mean[32], 0.5, accuracy: 1e-5)
    }

    /// Below 4 frames there is no trimming — a plain mean is the honest fallback.
    func testRobustMeanPlainMeanBelowFourFrames() {
        let a = [Float](repeating: 0.5, count: 8)
        let b = [Float](repeating: 1.0, count: 8)
        let mean = CityscapeComposer.robustMean([a, a, b])
        XCTAssertEqual(mean[0], (0.5 + 0.5 + 1.0) / 3, accuracy: 1e-5)
    }

    // MARK: Bracket recipes

    /// The 1 s third-party exposure cap bounds shutter from above, so the EV
    /// moves ride whichever control is free: −2 EV shortens the exposure,
    /// +1 EV doubles ISO at the cap.
    func testBracketRecipesRespectTheExposureCap() {
        let recipes = CityscapeComposer.bracketRecipes()
        XCTAssertEqual(recipes.count, 3)
        XCTAssertEqual(recipes[0].exposureSeconds, 1.0)
        XCTAssertEqual(recipes[0].iso, CityscapeComposer.foregroundBaseISO)
        XCTAssertEqual(recipes[1].exposureSeconds, 0.25, "−2 EV = exposure ÷ 4")
        XCTAssertEqual(recipes[1].iso, CityscapeComposer.foregroundBaseISO)
        XCTAssertEqual(recipes[2].exposureSeconds, 1.0, "exposure is capped at 1 s")
        XCTAssertEqual(recipes[2].iso, CityscapeComposer.foregroundBaseISO * 2,
                       "+1 EV rides ISO because the shutter is at the cap")
        for recipe in recipes {
            XCTAssertLessThanOrEqual(recipe.exposureSeconds, 1.0)
            XCTAssertFalse(recipe.nudgeTracking, "the head is parked for the bracket")
            XCTAssertEqual(recipe.targetSubCount, 1)
        }
        // An over-cap base exposure clamps rather than violating the cap.
        let clamped = CityscapeComposer.bracketRecipes(baseExposureSeconds: 2.5)
        XCTAssertEqual(clamped[0].exposureSeconds, 1.0)
    }

    /// Retention copies bound memory: an oversized frame downscales to the
    /// compose cap preserving aspect; a small frame passes through untouched.
    func testRetentionCopyBoundsLongestSide() throws {
        let big = try XCTUnwrap(CPUStacker.rgbImage(
            r: [Float](repeating: 0.5, count: 2048 * 64),
            g: [Float](repeating: 0.5, count: 2048 * 64),
            b: [Float](repeating: 0.5, count: 2048 * 64),
            width: 2048, height: 64))
        let retained = try XCTUnwrap(CityscapeComposer.retentionCopy(big))
        XCTAssertEqual(retained.width, CityscapeComposer.composeMaxSide)
        XCTAssertEqual(retained.height, 32, "aspect ratio preserved through the downscale")

        let small = try CityScene.image(CityScene.cityLuma())
        let untouched = try XCTUnwrap(CityscapeComposer.retentionCopy(small))
        XCTAssertEqual(untouched.width, CityScene.width)
        XCTAssertEqual(untouched.height, CityScene.height)
    }
}

// MARK: - Session-flow test doubles (file-private, City-prefixed)

@MainActor
private final class CityMockMount: MountControlling {
    var connection: MountConnection = .docked(name: "MockFlow")
    var authority: MountAuthority = .granted
    var telemetry: MountTelemetry? = MountTelemetry(pitchDeg: 0, yawDeg: 0,
                                                    speedDegPerSec: 0, batteryPercent: 90)
    var stopCount = 0

    func start() {}
    func stopEverything() async { stopCount += 1 }
    func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func waitSettled() async -> Bool { true }
    func keepalivePulse() async {}
}

/// Sky-phase stand-in: accepts every frame and hands the Develop phase the
/// synthetic starry sky image as its final stack.
private final class CityMockStacker: Stacking {
    let skyImage: CGImage?
    private var added = 0
    init(skyImage: CGImage?) { self.skyImage = skyImage }

    func reset(width: Int, height: Int) { added = 0 }
    func add(frame: SubFrame) -> Bool { added += 1; return true }
    func currentResult() -> StackResult {
        StackResult(accepted: added, rejected: 0,
                    integrationSeconds: Double(added), preview: skyImage)
    }
    func finalImage() -> CGImage? { skyImage }
}

private struct CityTestTimeout: Error {}

// MARK: - Session-flow test (feature 10, Phase A → Phase B → composite)

/// Engine-level dual-phase flow on the same synthetic scene: Phase A banks the
/// bracket + base frames FIRST with the head parked, Phase B runs the normal
/// sky stack, and the Develop phase publishes a REAL composer outcome.
@MainActor
final class CityscapeSessionTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 15,
                           _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw CityTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func testDualPhaseFlowBanksForegroundFirstThenComposites() async throws {
        let cityLuma = CityScene.cityLuma()
        let cityImage = try CityScene.image(cityLuma)
        let underImage = try CityScene.image(CityScene.scaled(cityLuma, by: 0.25))
        let overImage = try CityScene.image(CityScene.scaled(cityLuma, by: 2.0))
        let skyImage = try CityScene.image(CityScene.skyLuma())

        // Every capture call is recorded so the phase ordering is provable.
        let recorded = SessionValueRecorder()
        var hooks = SessionHooks(
            prepareCapture: { _ in (CityScene.width, CityScene.height) },
            captureSub: { recipe, index in
                recorded.append((iso: recipe.iso, exposure: recipe.exposureSeconds))
                try await Task.sleep(nanoseconds: 2_000_000)
                // Foreground recipes run at the city's low gain (ISO ≤ 200);
                // the sky phase runs the shot's ISO 1600 recipe.
                let image: CGImage
                if recipe.iso <= 200 {
                    image = recipe.exposureSeconds < 1.0 ? underImage
                        : (recipe.iso > CityscapeComposer.foregroundBaseISO
                            ? overImage : cityImage)
                } else {
                    image = skyImage
                }
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds,
                                iso: recipe.iso, pixelData: image)
            },
            endCapture: {},
            thermalState: { .nominal },
            batteryPercent: { 80 },
            freeDiskBytes: { 64_000_000_000 },
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0) },
            now: { Date() },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })
        // landscapeLeft = sensor-native upright: the synthetic scene is built
        // upright already, so the develop-phase rotation must be a no-op.
        hooks.captureTilt = { .landscapeLeft }

        let mount = CityMockMount()
        let stacker = CityMockStacker(skyImage: skyImage)
        let engine = SessionEngine(mount: mount, stacker: stacker, hooks: hooks)
        engine.autoFocusSweep = false        // sweep frames would blur the ordering proof
        engine.pauseStackingWhenCloudy = false

        let shot = ShotModeItem(
            id: "cityscape-test", name: "City Test", tagline: "test", symbol: "building.2",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 1600, targetSubCount: 4,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            capturesForeground: true,
            feasibility: { _, _ in .great })

        engine.start(shot: shot)
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        // Phase A first: exactly the 3-frame bracket then 6 base frames, all
        // at foreground gain, BEFORE any sky sub.
        let calls = recorded.values
        XCTAssertGreaterThanOrEqual(calls.count, 13, "9 foreground + 4 sky frames")
        let foreground = Array(calls.prefix(9))
        XCTAssertEqual(foreground[0].iso, CityscapeComposer.foregroundBaseISO)
        XCTAssertEqual(foreground[0].exposure, 1.0)
        XCTAssertEqual(foreground[1].exposure, 0.25, "bracket slot 2 is the −2 EV frame")
        XCTAssertEqual(foreground[2].iso, CityscapeComposer.foregroundBaseISO * 2,
                       "bracket slot 3 carries +1 EV on ISO")
        for frame in foreground.suffix(6) {
            XCTAssertEqual(frame.iso, CityscapeComposer.foregroundBaseISO,
                           "base frames repeat the bracket base recipe")
            XCTAssertEqual(frame.exposure, 1.0)
        }
        for frame in calls.dropFirst(9) {
            XCTAssertEqual(frame.iso, 1600, "every frame after Phase A is a sky sub")
        }

        // The head was parked for Phase A (stopEverything before the bracket).
        XCTAssertGreaterThanOrEqual(mount.stopCount, 1)

        // Phase chips: the session ends with the sky phase live.
        XCTAssertEqual(engine.cityscapePhase, .sky)

        // Develop published a REAL composer outcome from the synthetic scene.
        let outcome = try XCTUnwrap(engine.cityscapeOutcome,
                                    "the Develop phase must run the composer")
        XCTAssertNotNil(outcome.composite,
                        "the clean synthetic horizon must produce a composite")
        XCTAssertNotEqual(outcome.confidence, .low)
        let meanRow = try XCTUnwrap(outcome.horizonMeanRow)
        XCTAssertEqual(meanRow, Double(CityScene.horizonRow), accuracy: 3.0)
        XCTAssertNotNil(engine.latestPreview, "the composite becomes the preview")
        XCTAssertEqual(engine.stats.subsAccepted, 4,
                       "foreground probes never consume the sky capture plan")
    }
}

/// Tiny reference box so the capture closure can record calls without data races
/// (the hooks closures all run on the MainActor in these tests).
private final class SessionValueRecorder: @unchecked Sendable {
    private(set) var values: [(iso: Double, exposure: Double)] = []
    func append(_ value: (iso: Double, exposure: Double)) { values.append(value) }
}
