import XCTest
import CoreGraphics
@testable import StarFlow

/// FIELD-BLOCKING regression: alt-az FIELD ROTATION.
///
/// The Flow 2 Pro is an alt-az head, so a perfectly framed target still rotates about
/// the optical axis at R = 15.04·cos(lat)·cos(Az)/cos(Alt) deg/hour — ≈ 10 deg/hr for
/// the Milky Way core low in the south from Hurricane Ridge (lat 47.97). That is 1° of
/// rotation every 6 minutes and 5° after half an hour. v1 bootstrapped registration
/// with a translation-only offset vote (3 px tolerance) seeded with IDENTITY rotation:
/// under rotation θ only star pairs within 3 px/θ of each other agree, the vote
/// collapses, and every frame is rejected partway into a long stack — the whole
/// second half of the night lost.
///
/// These tests pin both halves of the fix:
///   1. predicted-rotation seeding (`CPUStacker.setExpectedRotationRate`), and
///   2. the seed-rotation search + reference re-baselining safety nets, which work
///      even when no rate is known.
/// `testTranslationOnlyRegistrationFailsAtFiveDegrees` documents the old behaviour the
/// fix replaces, so the suite still bites if the rotation handling is ever removed.
final class RegistrationRotationTests: XCTestCase {

    private static let width = 400
    private static let height = 300
    private static let anchorX = 137.4
    private static let anchorY = 88.7

    // MARK: - Deterministic RNG

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double {
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * uniform() }
        /// Symmetric uniform noise — cheap enough for an 80-frame sequence and
        /// perfectly adequate for a detection threshold sitting far above it.
        mutating func noise(_ amplitude: Double) -> Double { uniform(-amplitude, amplitude) }
    }

    private struct SynthStar {
        var x: Double
        var y: Double
        var amp: Double
        var sigma: Double
    }

    // MARK: - Synthetic field

    private func makeStarField(rng: inout SplitMix64) -> [SynthStar] {
        var stars: [SynthStar] = [
            SynthStar(x: Self.anchorX, y: Self.anchorY, amp: 0.80, sigma: 1.6)
        ]
        while stars.count < 40 {
            let candidate = SynthStar(x: rng.uniform(30, Double(Self.width - 30)),
                                      y: rng.uniform(30, Double(Self.height - 30)),
                                      amp: rng.uniform(0.30, 0.60),
                                      sigma: rng.uniform(1.2, 1.8))
            let clear = stars.allSatisfy { hypot($0.x - candidate.x, $0.y - candidate.y) > 18 }
            if clear { stars.append(candidate) }
        }
        return stars
    }

    /// Render the field rotated by `rotationDeg` about the image centre and then
    /// translated by (dx, dy) — the same convention `CPUStacker.SimilarityTransform`
    /// uses, so a fitted rotation of +θ means the frame really was rotated by +θ.
    private func render(stars: [SynthStar], dx: Double, dy: Double, rotationDeg: Double,
                        noiseAmplitude: Double, rng: inout SplitMix64) -> [Float] {
        let w = Self.width, h = Self.height
        var buf = [Float](repeating: 0.05, count: w * h)
        if noiseAmplitude > 0 {
            for i in 0..<buf.count { buf[i] += Float(rng.noise(noiseAmplitude)) }
        }
        let theta = rotationDeg * .pi / 180
        let c = cos(theta), s = sin(theta)
        let cx = Double(w) / 2, cy = Double(h) / 2
        for star in stars {
            let rx = star.x - cx, ry = star.y - cy
            let px = c * rx - s * ry + cx + dx
            let py = s * rx + c * ry + cy + dy
            let r = Int((4 * star.sigma).rounded(.up))
            let x0 = max(0, Int(px) - r), x1 = min(w - 1, Int(px) + r)
            let y0 = max(0, Int(py) - r), y1 = min(h - 1, Int(py) + r)
            guard x0 <= x1, y0 <= y1 else { continue }
            let inv = 1.0 / (2 * star.sigma * star.sigma)
            for y in y0...y1 {
                for x in x0...x1 {
                    let ddx = Double(x) - px, ddy = Double(y) - py
                    buf[y * w + x] += Float(star.amp * exp(-(ddx * ddx + ddy * ddy) * inv))
                }
            }
        }
        for i in 0..<buf.count { buf[i] = min(1, max(0, buf[i])) }
        return buf
    }

    private func makeImage(_ values: [Float]) throws -> CGImage {
        try XCTUnwrap(CPUStacker.rgbImage(r: values, g: values, b: values,
                                          width: Self.width, height: Self.height),
                      "failed to build synthetic CGImage")
    }

    private func frame(_ index: Int, _ image: CGImage, at date: Date) -> SubFrame {
        SubFrame(index: index, timestamp: date, exposureSeconds: 1.0, iso: 800, pixelData: image)
    }

    /// Background-subtracted centroid in a small window (background = window minimum).
    private func centroid(in buffer: [Float], nearX: Double, nearY: Double,
                          radius: Int) -> (x: Double, y: Double) {
        let w = Self.width, h = Self.height
        let cx = Int(nearX.rounded()), cy = Int(nearY.rounded())
        let x0 = max(0, cx - radius), x1 = min(w - 1, cx + radius)
        let y0 = max(0, cy - radius), y1 = min(h - 1, cy + radius)
        var floorValue = Float.greatestFiniteMagnitude
        for y in y0...y1 {
            for x in x0...x1 { floorValue = min(floorValue, buffer[y * w + x]) }
        }
        var sw = 0.0, sx = 0.0, sy = 0.0
        for y in y0...y1 {
            for x in x0...x1 {
                let weight = Double(max(0, buffer[y * w + x] - floorValue))
                sw += weight; sx += weight * Double(x); sy += weight * Double(y)
            }
        }
        guard sw > 0 else { return (Double(cx), Double(cy)) }
        return (sx / sw, sy / sw)
    }

    // MARK: - The rate itself

    /// Tonight's geometry: Hurricane Ridge (47.97° N), core in the south (az 190°) and
    /// low (alt 11°) → ~10 deg/hr of field rotation, i.e. 1° every 6 minutes.
    func testFieldRotationRateMatchesTonightsGeometry() {
        let rate = NudgePlanner.fieldRotationRateDegPerHour(altDeg: 11, azDeg: 190,
                                                            latitudeDeg: 47.97)
        XCTAssertEqual(abs(rate), 10.1, accuracy: 0.4,
                       "the core's field rotation tonight should be ~10 deg/hr, got \(rate)")
        // Due east/west: cos(Az) = 0 → the field is instantaneously not rotating.
        XCTAssertEqual(NudgePlanner.fieldRotationRateDegPerHour(altDeg: 30, azDeg: 90,
                                                                latitudeDeg: 47.97),
                       0, accuracy: 1e-9)
        // Opposite azimuths rotate opposite ways.
        let north = NudgePlanner.fieldRotationRateDegPerHour(altDeg: 20, azDeg: 0,
                                                             latitudeDeg: 47.97)
        let south = NudgePlanner.fieldRotationRateDegPerHour(altDeg: 20, azDeg: 180,
                                                             latitudeDeg: 47.97)
        XCTAssertEqual(north, -south, accuracy: 1e-9)
        // Near the zenith the true rate diverges; the clamp must keep it finite.
        let zenith = NudgePlanner.fieldRotationRateDegPerHour(altDeg: 89.99, azDeg: 180,
                                                              latitudeDeg: 47.97)
        XCTAssertTrue(zenith.isFinite, "a near-zenith target must not blow the rate up")
        XCTAssertLessThan(abs(zenith), 200)
        // deg/s is just the hourly rate over 3600.
        XCTAssertEqual(NudgePlanner.fieldRotationRateDegPerSecond(altDeg: 11, azDeg: 190,
                                                                   latitudeDeg: 47.97),
                       rate / 3600, accuracy: 1e-12)
    }

    // MARK: - The static registration API

    /// Seeding the rotation lets the static registration API solve a 5° frame outright.
    /// (The translation-only call is deliberately NOT asserted to fail here: at 5° it
    /// sometimes finds a foothold — a few bright stars close enough together for the
    /// 3 px offset vote — and the rotation-aware Kabsch fit then converges from it. That
    /// luck is exactly what makes the v1 pipeline unreliable rather than merely broken,
    /// and `testFortyMinuteSequence…` below measures the damage it does over a night.)
    func testSeededRegistrationSolvesFiveDegreesOutright() throws {
        var rng = SplitMix64(state: 0x524F_5441_5445_0001)
        let stars = makeStarField(rng: &rng)
        let reference = render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                               noiseAmplitude: 0.02, rng: &rng)
        let rotated = render(stars: stars, dx: 2, dy: -1, rotationDeg: 5,
                             noiseAmplitude: 0.02, rng: &rng)
        let refStars = CPUStacker.detectStars(in: reference, width: Self.width, height: Self.height)
        let candStars = CPUStacker.detectStars(in: rotated, width: Self.width, height: Self.height)
        XCTAssertGreaterThanOrEqual(refStars.count, 20)
        XCTAssertGreaterThanOrEqual(candStars.count, 20)

        let seeded = try XCTUnwrap(
            CPUStacker.register(reference: refStars, candidate: candStars,
                                voteStars: 12, voteTolerance: 3.0,
                                coarseTolerance: 8.0, fineTolerance: 2.5,
                                seedRotationRadians: 5 * .pi / 180,
                                rotationCenter: (Double(Self.width) / 2,
                                                 Double(Self.height) / 2)),
            "seeded registration must find the 5° solution")
        XCTAssertGreaterThanOrEqual(seeded.matches, 20,
                                    "the seeded fit should match nearly the whole field")
        XCTAssertLessThan(seeded.residualPx, 1.0)
        XCTAssertEqual(seeded.transform.rotationDegrees, 5, accuracy: 0.2)

        // The seed ladder is finite, deterministic, and always contains the un-seeded
        // solution, so a bad prediction can never hide it.
        let ladder = CPUStacker.rotationSeedLadder(seed: 0.2, windowDegrees: 10, stepDegrees: 0.5)
        XCTAssertEqual(ladder.first, 0.2)
        XCTAssertEqual(ladder[1], -0.2)
        XCTAssertTrue(ladder.contains(0))
        XCTAssertEqual(ladder.count, 3 + 2 * 20)
        XCTAssertEqual(CPUStacker.rotationSeedLadder(seed: 0, windowDegrees: 0,
                                                     stepDegrees: 0.5), [0],
                       "with no search window the historical single attempt is all that runs")
    }

    // MARK: - Predicted-rotation seeding

    /// 0.5°, 2°, 5°, 8° of field rotation (plus translation and noise): with the
    /// predicted rate supplied, every frame is ACCEPTED with sub-pixel residual — and
    /// the search is disabled here, so this proves the SEEDING alone carries it.
    func testPredictedRotationSeedingAcceptsEveryAngle() throws {
        let dt: TimeInterval = 600                     // 10 min between the two frames
        for (i, angle) in [0.5, 2.0, 5.0, 8.0].enumerated() {
            var rng = SplitMix64(state: 0x5345_4544_0000_0010 &+ UInt64(i))
            let stars = makeStarField(rng: &rng)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            // Rate that predicts exactly this angle after dt seconds.
            let stacker = CPUStacker(expectedRotationRateDegPerSec: angle / dt,
                                     rotationSearch: false)
            stacker.reset(width: Self.width, height: Self.height)

            let reference = render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                                   noiseAmplitude: 0.02, rng: &rng)
            XCTAssertTrue(stacker.add(frame: frame(0, try makeImage(reference), at: t0)))

            let rotated = render(stars: stars, dx: 3.5, dy: -2.5, rotationDeg: angle,
                                 noiseAmplitude: 0.02, rng: &rng)
            let accepted = stacker.add(frame: frame(1, try makeImage(rotated),
                                                    at: t0.addingTimeInterval(dt)))
            XCTAssertTrue(accepted,
                          "a frame rotated \(angle)° must register once the rotation is "
                          + "predicted (reason: \(stacker.lastRejectionReason ?? "-"))")
            XCTAssertLessThan(stacker.lastResidualPx, 1.0,
                              "residual at \(angle)° was \(stacker.lastResidualPx) px")
            XCTAssertGreaterThanOrEqual(stacker.lastMatchCount, 5)
            XCTAssertEqual(stacker.lastRotationDeg, angle, accuracy: 0.25,
                           "the fit must recover the true rotation at \(angle)°")
            XCTAssertEqual(stacker.currentResult().rejected, 0)
        }
    }

    /// The same angles with NO predicted rate at all: the seed-rotation search finds
    /// them. This is the session with no location fix — it must still stack.
    func testRotationSearchAcceptsEveryAngleWithoutAPredictedRate() throws {
        for (i, angle) in [0.5, 2.0, 5.0, 8.0].enumerated() {
            var rng = SplitMix64(state: 0x5345_4152_4348_0020 &+ UInt64(i))
            let stars = makeStarField(rng: &rng)
            let stacker = CPUStacker()                  // no rate, default search
            stacker.reset(width: Self.width, height: Self.height)
            XCTAssertNil(stacker.expectedRotationRateDegPerSec)

            let reference = render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                                   noiseAmplitude: 0.02, rng: &rng)
            XCTAssertTrue(stacker.add(frame: frame(0, try makeImage(reference), at: Date())))

            let rotated = render(stars: stars, dx: -4, dy: 3, rotationDeg: angle,
                                 noiseAmplitude: 0.02, rng: &rng)
            XCTAssertTrue(stacker.add(frame: frame(1, try makeImage(rotated), at: Date())),
                          "the rotation search must recover \(angle)° with no predicted "
                          + "rate (reason: \(stacker.lastRejectionReason ?? "-"))")
            XCTAssertLessThan(stacker.lastResidualPx, 1.0,
                              "residual at \(angle)° was \(stacker.lastResidualPx) px")
            XCTAssertEqual(stacker.lastRotationDeg, angle, accuracy: 0.25)
        }
    }

    /// A wrong-SIGNED prediction (sky handedness vs sensor pixels) must not cost frames:
    /// the ladder tries the negated seed immediately.
    func testWrongSignedPredictionStillRegisters() throws {
        var rng = SplitMix64(state: 0x5349_474E_0000_0030)
        let stars = makeStarField(rng: &rng)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let dt: TimeInterval = 600
        let stacker = CPUStacker(expectedRotationRateDegPerSec: -4.0 / dt)   // sign flipped
        stacker.reset(width: Self.width, height: Self.height)
        let reference = render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                               noiseAmplitude: 0.02, rng: &rng)
        XCTAssertTrue(stacker.add(frame: frame(0, try makeImage(reference), at: t0)))
        let rotated = render(stars: stars, dx: 1, dy: 1, rotationDeg: 4.0,
                             noiseAmplitude: 0.02, rng: &rng)
        XCTAssertTrue(stacker.add(frame: frame(1, try makeImage(rotated),
                                               at: t0.addingTimeInterval(dt))),
                      "a sign error in the predicted rate must cost a search step, not a frame")
        XCTAssertLessThan(stacker.lastResidualPx, 1.0)
        XCTAssertEqual(stacker.lastRotationDeg, 4.0, accuracy: 0.25)
    }

    // MARK: - The 40-minute night

    /// 40 minutes of the real thing: 40 s cadence, 10 deg/hr of field rotation
    /// (6.7° end to end), slow translation drift and noise. At least 95% of frames must
    /// stack, and the stacked anchor star must still sit on its ORIGINAL grid position —
    /// reference re-baselining must never let the output image walk away.
    ///
    /// THIS IS THE TEST THAT BITES. The same frames are also run through the v1 bootstrap
    /// (fixed reference, translation-only vote, identity seed) and that shadow run must
    /// visibly collapse — it stops accepting entirely once the field has turned a few
    /// degrees, which is the night the owner would otherwise have lost.
    func testFortyMinuteSequenceAtTenDegPerHourKeepsStacking() throws {
        var rng = SplitMix64(state: 0x4E49_4748_5400_0040)
        let stars = makeStarField(rng: &rng)
        let cadence: TimeInterval = 40
        let frames = 60                                   // 40 minutes
        let ratePerSec = 10.0 / 3600.0
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        let stacker = CPUStacker(expectedRotationRateDegPerSec: ratePerSec)
        stacker.reset(width: Self.width, height: Self.height)

        var accepted = 0
        var v1Reference: [CPUStacker.DetectedStar] = []
        var v1Accepted = 0
        var v1LastAcceptedFrame = 0
        for i in 0..<frames {
            let elapsed = Double(i) * cadence
            let rotation = ratePerSec * elapsed           // deg
            let buffer = render(stars: stars,
                                dx: 0.04 * Double(i), dy: -0.03 * Double(i),
                                rotationDeg: rotation, noiseAmplitude: 0.02, rng: &rng)
            let image = try makeImage(buffer)
            if stacker.add(frame: frame(i, image, at: t0.addingTimeInterval(elapsed))) {
                accepted += 1
            }

            // v1 shadow: one fixed reference, no rotation handling at all.
            let detected = CPUStacker.detectStars(in: buffer,
                                                  width: Self.width, height: Self.height)
            if v1Reference.isEmpty {
                v1Reference = detected
                v1Accepted += 1
                continue
            }
            if let old = CPUStacker.register(reference: v1Reference, candidate: detected,
                                             voteStars: 12, voteTolerance: 3.0,
                                             coarseTolerance: 8.0, fineTolerance: 2.5),
               old.matches >= 5, old.residualPx <= 2.0 {
                v1Accepted += 1
                v1LastAcceptedFrame = i
            }
        }

        XCTAssertGreaterThanOrEqual(accepted, Int(0.95 * Double(frames)),
                                    "only \(accepted)/\(frames) frames stacked across "
                                    + "40 minutes of field rotation")
        XCTAssertLessThan(v1Accepted, Int(0.90 * Double(frames)),
                          "the v1 bootstrap kept \(v1Accepted)/\(frames) frames — if it "
                          + "no longer collapses, this test has stopped proving anything")
        XCTAssertLessThan(v1LastAcceptedFrame, frames - 1,
                          "the v1 bootstrap must stop accepting frames entirely before the "
                          + "sequence ends (it last accepted frame \(v1LastAcceptedFrame))")
        XCTAssertGreaterThan(accepted, v1Accepted,
                             "rotation-aware registration must save frames v1 threw away")
        XCTAssertGreaterThan(stacker.rebaselineCount, 0,
                             "6.7° of accumulated rotation must have re-baselined the "
                             + "reference at least once")

        // Grid integrity: the composed transforms must keep the stack in the ORIGINAL
        // output grid — the anchor star stays where the first frame put it.
        let mean = stacker.accumulatedMean()
        let c = centroid(in: mean, nearX: Self.anchorX, nearY: Self.anchorY, radius: 6)
        let errorPx = hypot(c.x - Self.anchorX, c.y - Self.anchorY)
        XCTAssertLessThan(errorPx, 1.0,
                          "re-baselining drifted the stacked image \(errorPx) px off grid")
    }

    /// Re-baselining is the safety net that works with NO predicted rate: same 40-minute
    /// rotation, nothing configured. Frames must keep stacking and the image must stay
    /// on the original grid.
    func testReferenceRebaselineCarriesAStackWithNoPredictedRate() throws {
        var rng = SplitMix64(state: 0x5245_4241_5345_0050)
        let stars = makeStarField(rng: &rng)
        let cadence: TimeInterval = 60
        let frames = 40                                   // 40 minutes
        let ratePerSec = 10.0 / 3600.0
        let stacker = CPUStacker()                        // no rate at all
        stacker.reset(width: Self.width, height: Self.height)

        var accepted = 0
        for i in 0..<frames {
            let elapsed = Double(i) * cadence
            let buffer = render(stars: stars, dx: 0.05 * Double(i), dy: 0,
                                rotationDeg: ratePerSec * elapsed,
                                noiseAmplitude: 0.02, rng: &rng)
            if stacker.add(frame: frame(i, try makeImage(buffer), at: Date())) { accepted += 1 }
        }
        XCTAssertGreaterThanOrEqual(accepted, Int(0.95 * Double(frames)),
                                    "only \(accepted)/\(frames) frames stacked without a "
                                    + "predicted rate")
        XCTAssertGreaterThan(stacker.rebaselineCount, 0)
        let c = centroid(in: stacker.accumulatedMean(),
                         nearX: Self.anchorX, nearY: Self.anchorY, radius: 6)
        XCTAssertLessThan(hypot(c.x - Self.anchorX, c.y - Self.anchorY), 1.0)
    }

    // MARK: - Nothing changed for the easy case

    /// Identity: an unrotated, barely-translated sequence with no rate configured must
    /// behave exactly as it always did — every frame accepted, no rotation fitted, no
    /// re-baselining, sub-pixel alignment.
    func testIdentityCaseUnchanged() throws {
        var rng = SplitMix64(state: 0x4944_454E_5449_0060)
        let stars = makeStarField(rng: &rng)
        let stacker = CPUStacker()
        stacker.reset(width: Self.width, height: Self.height)

        for i in 0..<8 {
            let dx = i == 0 ? 0 : rng.uniform(-3, 3)
            let dy = i == 0 ? 0 : rng.uniform(-3, 3)
            let buffer = render(stars: stars, dx: dx, dy: dy, rotationDeg: 0,
                                noiseAmplitude: 0.02, rng: &rng)
            XCTAssertTrue(stacker.add(frame: frame(i, try makeImage(buffer), at: Date())),
                          "frame \(i) of an unrotated sequence must still stack")
            if i > 0 {
                XCTAssertEqual(stacker.lastRotationDeg, 0, accuracy: 0.2,
                               "no rotation may be invented for an unrotated frame")
            }
        }
        let result = stacker.currentResult()
        XCTAssertEqual(result.accepted, 8)
        XCTAssertEqual(result.rejected, 0)
        XCTAssertEqual(stacker.rebaselineCount, 0,
                       "a well-behaved stack must never re-baseline its reference")
        let c = centroid(in: stacker.accumulatedMean(),
                         nearX: Self.anchorX, nearY: Self.anchorY, radius: 6)
        XCTAssertLessThan(hypot(c.x - Self.anchorX, c.y - Self.anchorY), 0.7)
    }

    /// A starless frame is still rejected while a rotation search is available — the
    /// search must never manufacture an alignment out of noise.
    func testRotationSearchDoesNotRescueStarlessFrames() throws {
        var rng = SplitMix64(state: 0x4E4F_4953_4500_0070)
        let stars = makeStarField(rng: &rng)
        let stacker = CPUStacker()
        stacker.reset(width: Self.width, height: Self.height)
        let reference = render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                               noiseAmplitude: 0.02, rng: &rng)
        XCTAssertTrue(stacker.add(frame: frame(0, try makeImage(reference), at: Date())))

        let flat = [Float](repeating: 0.05, count: Self.width * Self.height)
        XCTAssertFalse(stacker.add(frame: frame(1, try makeImage(flat), at: Date())))
        XCTAssertEqual(stacker.lastRejectionReason, "too few stars")
        XCTAssertEqual(stacker.currentResult().rejected, 1)
    }

    // MARK: - Transform algebra

    /// Composition and the rotation helper are the plumbing re-baselining depends on.
    func testTransformCompositionMatchesSequentialApplication() {
        let a = CPUStacker.SimilarityTransform(cosT: cos(0.3), sinT: sin(0.3), tx: 12, ty: -5)
        let b = CPUStacker.SimilarityTransform(cosT: cos(-0.1), sinT: sin(-0.1), tx: -3, ty: 8)
        let composed = CPUStacker.SimilarityTransform.compose(outer: a, inner: b)
        for p in [(0.0, 0.0), (137.4, 88.7), (399.0, 299.0)] {
            let stepwise = a.apply(x: b.apply(x: p.0, y: p.1).x, y: b.apply(x: p.0, y: p.1).y)
            let direct = composed.apply(x: p.0, y: p.1)
            XCTAssertEqual(direct.x, stepwise.x, accuracy: 1e-9)
            XCTAssertEqual(direct.y, stepwise.y, accuracy: 1e-9)
        }
        // A rotation about a centre leaves that centre fixed.
        let centre = (x: 200.0, y: 150.0)
        let spin = CPUStacker.SimilarityTransform.rotation(radians: 0.42, about: centre)
        let fixed = spin.apply(x: centre.x, y: centre.y)
        XCTAssertEqual(fixed.x, centre.x, accuracy: 1e-9)
        XCTAssertEqual(fixed.y, centre.y, accuracy: 1e-9)
        XCTAssertEqual(spin.rotationDegrees, 0.42 * 180 / .pi, accuracy: 1e-9)
    }
}
