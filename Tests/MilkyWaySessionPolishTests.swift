import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - MilkyWaySessionPolishTests
//
// Feature 3 (Milky Way session polish) pure-math coverage:
//  - ExposurePlanner.refine: one-stop ISO tuning from the MEASURED sky background.
//  - CloudTimeBudget: cloud-skipped frames extend the session (capped at 2×),
//    never consume the planned sub count, with honest waiting copy.
//  - FramingGuide: where the core sits relative to frame center (arrow + degrees).
//  - IntegrationDepth: live depth tier (5/15/30 min) honest per sky condition.
// All simulator-safe: no camera, no motion hardware, no clocks.

final class MilkyWaySessionPolishTests: XCTestCase {

    // MARK: Fixtures

    private func plan(iso: Double, exposure: Double = 1.0) -> ExposurePlanner.Plan {
        ExposurePlanner.Plan(exposureSeconds: exposure, iso: iso, note: "")
    }

    // MARK: - ExposurePlanner.refine (measured-background tuning)

    func testRefineDropsAStopWhenBackgroundNearsSaturation() throws {
        let tuned = try XCTUnwrap(
            ExposurePlanner.refine(measuredBackground: 0.24, current: plan(iso: 3200)))
        XCTAssertEqual(tuned.iso, 1600, accuracy: 1e-9)
        XCTAssertEqual(tuned.exposureSeconds, 1.0, accuracy: 1e-12,
                       "Refinement trades gain, never shutter — 1 s is the hard cap")
        XCTAssertTrue(tuned.note.contains("Sky measured"),
                      "The narration must credit the measurement: \(tuned.note)")
        XCTAssertTrue(tuned.note.contains("tuning to ISO 1600"),
                      "The narration must name the new ISO: \(tuned.note)")
    }

    func testRefineRaisesAStopWhenSkyIsDarkerThanPlanned() throws {
        let tuned = try XCTUnwrap(
            ExposurePlanner.refine(measuredBackground: 0.01, current: plan(iso: 1600)))
        XCTAssertEqual(tuned.iso, 3200, accuracy: 1e-9)
        XCTAssertTrue(tuned.note.contains("tuning to ISO 3200"))
    }

    func testRefineLeavesAHealthyBackgroundAlone() {
        XCTAssertNil(ExposurePlanner.refine(measuredBackground: 0.05,
                                            current: plan(iso: 3200)),
                     "A background in the healthy band must not trigger tuning")
        XCTAssertNil(ExposurePlanner.refine(measuredBackground: 0.19,
                                            current: plan(iso: 3200)))
        XCTAssertNil(ExposurePlanner.refine(measuredBackground: 0.03,
                                            current: plan(iso: 3200)))
    }

    func testRefineClampsAtTheFormatBounds() throws {
        // Raising from the ceiling: the clamp cancels the stop → no adjustment.
        XCTAssertNil(ExposurePlanner.refine(measuredBackground: 0.01,
                                            current: plan(iso: ExposurePlanner.isoCeiling)))
        // A partial clamp still moves: 4800 × 2 = 9600 → clamped to 6400.
        let tuned = try XCTUnwrap(
            ExposurePlanner.refine(measuredBackground: 0.01, current: plan(iso: 4800)))
        XCTAssertEqual(tuned.iso, ExposurePlanner.isoCeiling, accuracy: 1e-9)
        // Dropping never lands below the floor: 250 / 2 = 125 (≥ 100).
        let dropped = try XCTUnwrap(
            ExposurePlanner.refine(measuredBackground: 0.25, current: plan(iso: 250)))
        XCTAssertGreaterThanOrEqual(dropped.iso, ExposurePlanner.isoFloor)
    }

    func testRefineNeverTouchesTargetLitRecipes() {
        // Lunar-class recipe (ISO 100): the Moon provides the photons — a bright
        // measured background is the SUBJECT, not a problem to tune away.
        XCTAssertNil(ExposurePlanner.refine(measuredBackground: 0.5,
                                            current: plan(iso: 100, exposure: 0.008)))
        XCTAssertNil(ExposurePlanner.refine(measuredBackground: 0.5,
                                            current: plan(iso: ExposurePlanner.brightTargetISOThreshold)))
    }

    // MARK: - CloudTimeBudget

    func testPlannedWallSecondsCountsExposureAndCadence() {
        let backToBack = CaptureRecipe(exposureSeconds: 1.0, iso: 3200,
                                       targetSubCount: 600, nudgeTracking: true)
        XCTAssertEqual(CloudTimeBudget.plannedWallSeconds(recipe: backToBack),
                       600, accuracy: 1e-9)
        let timelapse = CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: 240,
                                      nudgeTracking: false, intervalSeconds: 30)
        XCTAssertEqual(CloudTimeBudget.plannedWallSeconds(recipe: timelapse),
                       240 * 31.0, accuracy: 1e-9)
    }

    func testCloudBudgetCapsAtTwiceThePlan() {
        XCTAssertTrue(CloudTimeBudget.allowsExtension(plannedSeconds: 600,
                                                      elapsedSeconds: 0))
        XCTAssertTrue(CloudTimeBudget.allowsExtension(plannedSeconds: 600,
                                                      elapsedSeconds: 1199.9))
        XCTAssertFalse(CloudTimeBudget.allowsExtension(plannedSeconds: 600,
                                                       elapsedSeconds: 1200),
                       "2× the planned wall time is the hard extension cap")
        XCTAssertFalse(CloudTimeBudget.allowsExtension(plannedSeconds: 600,
                                                       elapsedSeconds: 50_000))
    }

    func testCloudWaitLineIsHonestAboutAddedTime() {
        // 240 skipped 1 s frames = 4 minutes of added session time.
        let line = CloudTimeBudget.waitLine(skippedFrames: 240, frameSeconds: 1.0,
                                            extending: true)
        XCTAssertTrue(line.contains("Waiting out clouds"), line)
        XCTAssertTrue(line.contains("4 min added"), line)
        // Under a minute reads in seconds, not "0 min".
        let secondsLine = CloudTimeBudget.waitLine(skippedFrames: 45, frameSeconds: 1.0,
                                                   extending: true)
        XCTAssertTrue(secondsLine.contains("45 s added"), secondsLine)
        // Budget exhausted: the copy must not promise more extension.
        let capped = CloudTimeBudget.waitLine(skippedFrames: 1200, frameSeconds: 1.0,
                                              extending: false)
        XCTAssertFalse(capped.contains("added"), capped)
        XCTAssertTrue(capped.lowercased().contains("clouds"), capped)
    }

    // MARK: - FramingGuide (core position vs frame center)

    func testOffsetPointsRightAndUp() {
        // Camera az 180 / alt 10; core az 190 / alt 25 → right of and above center.
        let off = FramingGuide.offset(cameraAzimuthDeg: 180, cameraAltitudeDeg: 10,
                                      target: HorizontalCoord(altitudeDeg: 25,
                                                              azimuthDeg: 190))
        XCTAssertEqual(off.upDeg, 15, accuracy: 1e-9)
        XCTAssertEqual(off.rightDeg, 10 * cos(25 * Double.pi / 180), accuracy: 1e-9,
                       "The azimuth arc is foreshortened by cos(target altitude)")
        XCTAssertGreaterThan(off.separationDeg, 15)
    }

    func testOffsetWrapsAroundNorth() {
        // Camera az 350, target az 10 → 20° RIGHT, never 340° left.
        let off = FramingGuide.offset(cameraAzimuthDeg: 350, cameraAltitudeDeg: 0,
                                      target: HorizontalCoord(altitudeDeg: 0,
                                                              azimuthDeg: 10))
        XCTAssertEqual(off.rightDeg, 20, accuracy: 1e-9)
        XCTAssertEqual(off.upDeg, 0, accuracy: 1e-9)
        // And the mirror case wraps left.
        let mirrored = FramingGuide.offset(cameraAzimuthDeg: 10, cameraAltitudeDeg: 0,
                                           target: HorizontalCoord(altitudeDeg: 0,
                                                                   azimuthDeg: 350))
        XCTAssertEqual(mirrored.rightDeg, -20, accuracy: 1e-9)
    }

    func testGuidanceLineNamesDirectionAndDegrees() {
        let left = FramingGuide.Offset(rightDeg: -12.2, upDeg: 0.3)
        XCTAssertEqual(FramingGuide.guidanceLine(offset: left, targetName: "Core"),
                       "Core: 12° left")
        let both = FramingGuide.Offset(rightDeg: 8, upDeg: -5)
        XCTAssertEqual(FramingGuide.guidanceLine(offset: both, targetName: "Core"),
                       "Core: 8° right, 5° down")
    }

    func testGuidanceCallsCenteredInsideTheThreshold() {
        let near = FramingGuide.Offset(rightDeg: 1.0, upDeg: -1.2)
        XCTAssertEqual(FramingGuide.guidanceLine(offset: near, targetName: "Core"),
                       "Core centered — hold this framing.")
        XCTAssertNil(FramingGuide.arrowAngleDeg(offset: near),
                     "A centered target draws no arrow")
    }

    func testArrowAngleMatchesScreenDirections() {
        XCTAssertEqual(FramingGuide.arrowAngleDeg(
            offset: .init(rightDeg: 0, upDeg: 10)) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(FramingGuide.arrowAngleDeg(
            offset: .init(rightDeg: 10, upDeg: 0)) ?? -1, 90, accuracy: 1e-9)
        XCTAssertEqual(FramingGuide.arrowAngleDeg(
            offset: .init(rightDeg: 0, upDeg: -10)) ?? -1, 180, accuracy: 1e-9)
        XCTAssertEqual(FramingGuide.arrowAngleDeg(
            offset: .init(rightDeg: -10, upDeg: 0)) ?? -1, 270, accuracy: 1e-9)
    }

    // MARK: - IntegrationDepth (live depth meter)

    func testDepthTierThresholdsAt5And15And30Minutes() {
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 0), .starting)
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 4 * 60 + 59), .starting)
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 5 * 60), .building)
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 14 * 60 + 59), .building)
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 15 * 60), .good)
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 29 * 60 + 59), .good)
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 30 * 60), .deep)
        XCTAssertEqual(IntegrationDepth.tier(integratedSeconds: 3 * 3600), .deep)
    }

    func testDepthLineMatchesTierUnderAClearSky() {
        XCTAssertEqual(IntegrationDepth.line(integratedSeconds: 16 * 60, condition: .clear),
                       "Depth: good — faint arms emerging.")
        XCTAssertEqual(IntegrationDepth.line(integratedSeconds: 16 * 60, condition: .unknown),
                       "Depth: good — faint arms emerging.",
                       "An ungraded sky reads like clear — no invented caveats")
    }

    func testDepthLineStaysHonestPerSkyCondition() {
        let hazy = IntegrationDepth.line(integratedSeconds: 16 * 60, condition: .hazy)
        XCTAssertTrue(hazy.contains("Depth: good"), hazy)
        XCTAssertTrue(hazy.lowercased().contains("haze"),
                      "Haze must temper the promise: \(hazy)")
        let bright = IntegrationDepth.line(integratedSeconds: 60 * 60,
                                           condition: .overexposed)
        XCTAssertTrue(bright.contains("too bright"), bright)
        XCTAssertFalse(bright.contains("deep"),
                       "An overexposed sky must not brag about depth")
        let cloudy = IntegrationDepth.line(integratedSeconds: 10 * 60, condition: .cloudy)
        XCTAssertTrue(cloudy.contains("10 min"), cloudy)
        XCTAssertTrue(cloudy.lowercased().contains("cloud"), cloudy)
    }
}

// MARK: - Exposure refinement engine integration

// Minimal file-private doubles (prefixed to avoid target-wide collisions).

@MainActor
private final class PolishMockMount: MountControlling {
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

private final class PolishMockStacker: Stacking {
    func reset(width: Int, height: Int) {}
    func add(frame: SubFrame) -> Bool { true }
    func currentResult() -> StackResult {
        StackResult(accepted: 0, rejected: 0, integrationSeconds: 0, preview: nil)
    }
    func finalImage() -> CGImage? { nil }
}

private final class PolishISOLog {
    var isos: [Double] = []
}

private struct PolishTestTimeout: Error {}

@MainActor
final class ExposureRefinementIntegrationTests: XCTestCase {

    /// A session whose frames MEASURE a sky background near saturation must
    /// drop ISO one stop after the first few frames — exactly once — while the
    /// shutter and plan shape stay untouched.
    func testMeasuredBrightSkyDropsISOOnceMidSession() async throws {
        let side = 64
        let bright = Self.flatGrayImage(side: side, gray: 0.25)
        let log = PolishISOLog()
        let hooks = SessionHooks(
            prepareCapture: { _ in (side, side) },
            captureSub: { recipe, index in
                try await Task.sleep(nanoseconds: 2_000_000)
                log.isos.append(recipe.iso)
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                                pixelData: bright)
            },
            endCapture: {},
            thermalState: { .nominal },
            batteryPercent: { 80 },
            freeDiskBytes: { 64_000_000_000 },
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0.5) },
            now: { Date() },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })

        let engine = SessionEngine(mount: PolishMockMount(),
                                   stacker: PolishMockStacker(), hooks: hooks)
        engine.autoFocusSweep = false   // isolate the capture loop's refinement
        let shot = ShotModeItem(
            id: "refine", name: "Refine Shot", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: 12,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            stackingStyle: .registered,
            feasibility: { _, _ in .great })
        engine.start(shot: shot)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(log.isos.first ?? 0, 800, accuracy: 1e-9,
                       "The session must start on the mode's planned ISO")
        XCTAssertEqual(log.isos.last ?? 0, 400, accuracy: 1e-9,
                       "A near-saturation measured background must drop one stop")
        XCTAssertEqual(Set(log.isos).count, 2,
                       "Exactly one mid-session adjustment — never a hunt")
        // Once adjusted, the ISO must never bounce back.
        if let firstTuned = log.isos.firstIndex(of: 400) {
            XCTAssertTrue(log.isos[firstTuned...].allSatisfy { $0 == 400 })
            XCTAssertGreaterThanOrEqual(firstTuned, SessionEngine.refineAfterSamples,
                                        "Tuning must wait for the measured frames")
        } else {
            XCTFail("No tuned frames recorded")
        }
    }

    /// The same bright sky under a trails session must NOT be tuned — a
    /// mid-run gain step would print a visible seam into the lighten blend.
    func testTrailsSessionsAreNeverRefined() async throws {
        let side = 64
        let bright = Self.flatGrayImage(side: side, gray: 0.25)
        let log = PolishISOLog()
        let hooks = SessionHooks(
            prepareCapture: { _ in (side, side) },
            captureSub: { recipe, index in
                try await Task.sleep(nanoseconds: 2_000_000)
                log.isos.append(recipe.iso)
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                                pixelData: bright)
            },
            endCapture: {},
            thermalState: { .nominal },
            batteryPercent: { 80 },
            freeDiskBytes: { 64_000_000_000 },
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0.5) },
            now: { Date() },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })

        let engine = SessionEngine(mount: PolishMockMount(),
                                   stacker: PolishMockStacker(), hooks: hooks)
        engine.autoFocusSweep = false
        let shot = ShotModeItem(
            id: "trailsrefine", name: "Trails Shot", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 400, targetSubCount: 10,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            stackingStyle: .trails,
            feasibility: { _, _ in .great })
        engine.start(shot: shot)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(Set(log.isos), [400],
                       "Trails sessions must run their planned ISO end to end")
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 10,
                           _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw PolishTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

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
