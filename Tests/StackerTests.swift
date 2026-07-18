import XCTest
import CoreGraphics
@testable import StarFlow

/// CPU stacker verification on synthetic COLOURED gaussian starfields (no hardware,
/// no fixtures). Design gate: 8 frames shifted up to 6 px and rotated up to 1°,
/// ≥ 7 accepted, final alignment error < 0.7 px at the brightest star; pure noise
/// frames rejected; the final image is genuinely colour (non-grayscale).
final class StackerTests: XCTestCase {

    private static let width = 400
    private static let height = 300

    // MARK: - Deterministic RNG (SplitMix64 + Box–Muller)

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
        mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
            lo + (hi - lo) * uniform()
        }
        mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12)
            let u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    // MARK: - Synthetic starfield (COLOURED — the pipeline stacks RGB)

    private struct SynthStar {
        var x: Double
        var y: Double
        var amp: Double
        var sigma: Double
        var tintR: Double
        var tintG: Double
        var tintB: Double
    }

    /// Luminance-normalised star tint: 0 = warm orange (K/M star), 1 = blue-white
    /// (B/A star). Normalising by Rec.709 luminance keeps `amp` meaning "brightness",
    /// so detection statistics match the old grayscale field.
    private static func tint(_ t: Double) -> (r: Double, g: Double, b: Double) {
        var r = 1.0 - 0.45 * t          // 1.00 → 0.55
        var g = 0.72 + 0.08 * t          // 0.72 → 0.80
        var b = 0.50 + 0.50 * t          // 0.50 → 1.00
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        r /= lum; g /= lum; b /= lum
        return (r, g, b)
    }

    /// Anchor star (index 0) is the brightest, at a known subpixel position —
    /// the ground truth for the alignment assertion. It is strongly WARM so the
    /// colour-preservation assertions have a known target.
    private static let anchorX = 137.4
    private static let anchorY = 88.7

    private func makeStarField(rng: inout SplitMix64) -> [SynthStar] {
        let warm = Self.tint(0)
        var stars: [SynthStar] = [
            SynthStar(x: Self.anchorX, y: Self.anchorY, amp: 0.80, sigma: 1.6,
                      tintR: warm.r, tintG: warm.g, tintB: warm.b)
        ]
        while stars.count < 40 {
            let c = Self.tint(rng.uniform())
            let candidate = SynthStar(x: rng.uniform(25, Double(Self.width - 25)),
                                      y: rng.uniform(25, Double(Self.height - 25)),
                                      amp: rng.uniform(0.25, 0.55),
                                      sigma: rng.uniform(1.2, 1.8),
                                      tintR: c.r, tintG: c.g, tintB: c.b)
            let clear = stars.allSatisfy { hypot($0.x - candidate.x, $0.y - candidate.y) > 16 }
            if clear { stars.append(candidate) }
        }
        return stars
    }

    /// Render the field translated by (dx, dy) and rotated by rotationDeg about the
    /// image centre, over a 0.05 pedestal with independent per-channel gaussian
    /// noise. Three colour planes, values clamped 0…1.
    private func render(stars: [SynthStar], dx: Double, dy: Double, rotationDeg: Double,
                        noiseSigma: Double, rng: inout SplitMix64)
        -> (r: [Float], g: [Float], b: [Float]) {
        let w = Self.width, h = Self.height
        var bufR = [Float](repeating: 0.05, count: w * h)
        var bufG = [Float](repeating: 0.05, count: w * h)
        var bufB = [Float](repeating: 0.05, count: w * h)
        if noiseSigma > 0 {
            for i in 0..<bufR.count {
                bufR[i] += Float(noiseSigma * rng.gaussian())
                bufG[i] += Float(noiseSigma * rng.gaussian())
                bufB[i] += Float(noiseSigma * rng.gaussian())
            }
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
                    let ddx = Double(x) - px
                    let ddy = Double(y) - py
                    let psf = star.amp * exp(-(ddx * ddx + ddy * ddy) * inv)
                    let i = y * w + x
                    bufR[i] += Float(psf * star.tintR)
                    bufG[i] += Float(psf * star.tintG)
                    bufB[i] += Float(psf * star.tintB)
                }
            }
        }
        for i in 0..<bufR.count {
            bufR[i] = min(1, max(0, bufR[i]))
            bufG[i] = min(1, max(0, bufG[i]))
            bufB[i] = min(1, max(0, bufB[i]))
        }
        return (bufR, bufG, bufB)
    }

    /// Rec.709 luminance plane of a colour render (for direct detection tests).
    private func luminance(_ p: (r: [Float], g: [Float], b: [Float])) -> [Float] {
        var out = [Float](repeating: 0, count: p.r.count)
        for i in 0..<out.count {
            out[i] = 0.2126 * p.r[i] + 0.7152 * p.g[i] + 0.0722 * p.b[i]
        }
        return out
    }

    private func makeImage(_ planes: (r: [Float], g: [Float], b: [Float])) throws -> CGImage {
        try XCTUnwrap(CPUStacker.rgbImage(r: planes.r, g: planes.g, b: planes.b,
                                          width: Self.width, height: Self.height),
                      "failed to build synthetic colour CGImage")
    }

    /// Neutral (gray) colour image from a single plane — for flat/noise frames.
    private func makeImage(_ values: [Float]) throws -> CGImage {
        try XCTUnwrap(CPUStacker.rgbImage(r: values, g: values, b: values,
                                          width: Self.width, height: Self.height),
                      "failed to build synthetic CGImage")
    }

    /// Non-grayscale metric: per-pixel channel spread (max − min across r,g,b) of a
    /// CGImage, plus how many pixels are visibly coloured (spread > 0.08 ≈ 20/255).
    private func channelSpread(of image: CGImage) throws -> (maxSpread: Float, coloredPixels: Int) {
        let planes = try XCTUnwrap(
            CPUStacker.rgbFloats(from: image, width: image.width, height: image.height))
        var maxSpread: Float = 0
        var colored = 0
        for i in 0..<planes.r.count {
            let hi = max(planes.r[i], planes.g[i], planes.b[i])
            let lo = min(planes.r[i], planes.g[i], planes.b[i])
            let spread = hi - lo
            maxSpread = max(maxSpread, spread)
            if spread > 0.08 { colored += 1 }
        }
        return (maxSpread, colored)
    }

    private func makeFrame(index: Int, image: CGImage) -> SubFrame {
        SubFrame(index: index, timestamp: Date(), exposureSeconds: 1.0, iso: 800, pixelData: image)
    }

    /// Background-subtracted centroid inside a small window (background = window minimum).
    private func centroid(in buffer: [Float], nearX: Double, nearY: Double,
                          radius: Int) -> (x: Double, y: Double) {
        let w = Self.width, h = Self.height
        let cx = Int(nearX.rounded()), cy = Int(nearY.rounded())
        let x0 = max(0, cx - radius), x1 = min(w - 1, cx + radius)
        let y0 = max(0, cy - radius), y1 = min(h - 1, cy + radius)
        var floor = Float.greatestFiniteMagnitude
        for y in y0...y1 {
            for x in x0...x1 {
                floor = min(floor, buffer[y * w + x])
            }
        }
        var sw = 0.0, sx = 0.0, sy = 0.0
        for y in y0...y1 {
            for x in x0...x1 {
                let weight = Double(max(0, buffer[y * w + x] - floor))
                sw += weight
                sx += weight * Double(x)
                sy += weight * Double(y)
            }
        }
        guard sw > 0 else { return (Double(cx), Double(cy)) }
        return (sx / sw, sy / sw)
    }

    // MARK: - Tests

    /// 8 frames of the same field, shifted up to 6 px and rotated up to 1°:
    /// ≥ 7 accepted, and the stacked anchor star lands < 0.7 px from its reference position.
    func testStackAlignsShiftedRotatedFrames() throws {
        var rng = SplitMix64(state: 0x5741_524C_4F57_0001)
        let stars = makeStarField(rng: &rng)
        let stacker = CPUStacker()
        stacker.reset(width: Self.width, height: Self.height)

        var acceptedFlags: [Bool] = []
        for i in 0..<8 {
            // Frame 0 is untransformed so the reference grid matches ground truth.
            let dx = i == 0 ? 0 : rng.uniform(-6, 6)
            let dy = i == 0 ? 0 : rng.uniform(-6, 6)
            let rot = i == 0 ? 0 : rng.uniform(-1, 1)
            let buffer = render(stars: stars, dx: dx, dy: dy, rotationDeg: rot,
                                noiseSigma: 0.02, rng: &rng)
            let image = try makeImage(buffer)
            acceptedFlags.append(stacker.add(frame: makeFrame(index: i, image: image)))
        }

        XCTAssertTrue(acceptedFlags[0], "reference frame must be accepted")
        let result = stacker.currentResult()
        XCTAssertGreaterThanOrEqual(result.accepted, 7,
                                    "at least 7 of 8 well-aligned frames should stack")
        XCTAssertEqual(result.accepted, acceptedFlags.filter { $0 }.count)
        XCTAssertEqual(result.accepted + result.rejected, 8)
        XCTAssertEqual(result.integrationSeconds, Double(result.accepted), accuracy: 0.001,
                       "integration = accepted subs × 1 s exposure")

        // Alignment: brightest-star centroid in the stacked mean vs its reference position.
        let mean = stacker.accumulatedMean()
        let c = centroid(in: mean, nearX: Self.anchorX, nearY: Self.anchorY, radius: 6)
        let errorPx = hypot(c.x - Self.anchorX, c.y - Self.anchorY)
        XCTAssertLessThan(errorPx, 0.7,
                          "stacked anchor star drifted \(errorPx) px from reference")

        XCTAssertNotNil(result.preview)

        // COLOUR (field-report regression: the final image came out grayscale).
        // The stack must produce a genuinely colour image: RGB colour model, with
        // real channel variance where the tinted stars are.
        let final = try XCTUnwrap(stacker.finalImage())
        XCTAssertEqual(final.colorSpace?.model, .rgb, "final image must be RGB, not gray")
        let spread = try channelSpread(of: final)
        XCTAssertGreaterThan(spread.maxSpread, 0.1,
                             "tinted stars must survive stacking + stretch in colour "
                             + "(max channel spread \(spread.maxSpread))")
        XCTAssertGreaterThan(spread.coloredPixels, 20,
                             "a whole starfield of tinted stars must leave many coloured "
                             + "pixels, found \(spread.coloredPixels)")

        // Star colour direction check: the warm anchor must stay red-leaning
        // (r > b at its stacked position) — the f(L)/L stretch preserves hue.
        let rgb = stacker.accumulatedRGB()
        let anchorIdx = Int(Self.anchorY.rounded()) * Self.width + Int(Self.anchorX.rounded())
        XCTAssertGreaterThan(rgb.r[anchorIdx], rgb.b[anchorIdx],
                             "warm anchor star lost its colour in the linear stack")
    }

    /// A frame of pure noise (clouds rolled in / lens cap) must be rejected and counted.
    func testRejectsPureNoiseFrame() throws {
        var rng = SplitMix64(state: 0x0BAD_C0FF_EE00_0002)
        let stars = makeStarField(rng: &rng)
        let stacker = CPUStacker()
        stacker.reset(width: Self.width, height: Self.height)

        let reference = render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                               noiseSigma: 0.02, rng: &rng)
        XCTAssertTrue(stacker.add(frame: makeFrame(index: 0, image: try makeImage(reference))))

        var noise = [Float](repeating: 0, count: Self.width * Self.height)
        for i in 0..<noise.count {
            noise[i] = Float(min(1, max(0, 0.05 + 0.02 * rng.gaussian())))
        }
        XCTAssertFalse(stacker.add(frame: makeFrame(index: 1, image: try makeImage(noise))),
                       "a starless noise frame must be rejected")

        let result = stacker.currentResult()
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(result.rejected, 1)
    }

    /// Detection sanity: the synthetic field is found with subpixel centroid accuracy.
    func testDetectsSyntheticStarsWithSubpixelAccuracy() throws {
        var rng = SplitMix64(state: 0x5741_524C_4F57_0003)
        let stars = makeStarField(rng: &rng)
        let buffer = luminance(render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                                      noiseSigma: 0.02, rng: &rng))
        let detected = CPUStacker.detectStars(in: buffer, width: Self.width, height: Self.height)
        XCTAssertGreaterThanOrEqual(detected.count, 30,
                                    "should recover most of the 40 synthetic stars")
        let anchor = try XCTUnwrap(
            detected.min(by: {
                hypot($0.x - Self.anchorX, $0.y - Self.anchorY)
                    < hypot($1.x - Self.anchorX, $1.y - Self.anchorY)
            })
        )
        XCTAssertLessThan(hypot(anchor.x - Self.anchorX, anchor.y - Self.anchorY), 0.5,
                          "anchor star centroid should be subpixel-accurate")
    }

    /// FIELD REPORT regression (indoor "broken app"): a starless scene must never look
    /// dead. The first frame ALWAYS seeds the stack (proof of life), registration goes
    /// inactive, and subsequent starless frames accumulate unregistered — while a
    /// starry stack that rejects a starless frame must say WHY ("too few stars").
    func testStarlessFramesSeedUnregisteredStackAndRejectionsExplain() throws {
        var rng = SplitMix64(state: 0x1D00_12F0_0000_0006)

        // Starless room: perfectly flat seed (deterministically zero detections),
        // then noisy starless frames.
        let stacker = CPUStacker()
        stacker.reset(width: Self.width, height: Self.height)

        let flat = [Float](repeating: 0.05, count: Self.width * Self.height)
        XCTAssertTrue(stacker.add(frame: makeFrame(index: 0, image: try makeImage(flat))),
                      "the first frame must ALWAYS seed the stack, stars or not")
        XCTAssertFalse(stacker.registrationActive,
                       "a starless seed must flip the stack to unregistered accumulate")
        XCTAssertNil(stacker.lastRejectionReason, "accepted frames carry no rejection reason")

        for i in 1...3 {
            var noise = [Float](repeating: 0, count: Self.width * Self.height)
            for j in 0..<noise.count {
                noise[j] = Float(min(1, max(0, 0.05 + 0.02 * rng.gaussian())))
            }
            XCTAssertTrue(stacker.add(frame: makeFrame(index: i, image: try makeImage(noise))),
                          "starless frame \(i) must accumulate unregistered, not be rejected")
            XCTAssertNil(stacker.lastRejectionReason)
        }
        let starless = stacker.currentResult()
        XCTAssertEqual(starless.accepted, 4)
        XCTAssertEqual(starless.rejected, 0)
        XCTAssertNotNil(starless.preview, "proof of life: the preview must exist immediately")

        // Starry stack: a starless frame is still rejected, now with an explanation.
        let starry = CPUStacker()
        starry.reset(width: Self.width, height: Self.height)
        let stars = makeStarField(rng: &rng)
        let reference = render(stars: stars, dx: 0, dy: 0, rotationDeg: 0,
                               noiseSigma: 0.02, rng: &rng)
        XCTAssertTrue(starry.add(frame: makeFrame(index: 0, image: try makeImage(reference))))
        XCTAssertTrue(starry.registrationActive,
                      "a starry seed must keep registration active")
        XCTAssertFalse(starry.add(frame: makeFrame(index: 1, image: try makeImage(flat))),
                       "a starless frame against a starry reference is still rejected")
        XCTAssertEqual(starry.lastRejectionReason, "too few stars",
                       "the rejection must carry the reason the session UI explains")
        XCTAssertEqual(starry.currentResult().accepted, 1)
        XCTAssertEqual(starry.currentResult().rejected, 1)
    }

    /// A frame with too few matched stars (a completely different field) is rejected.
    func testRejectsUnmatchableField() throws {
        var rng = SplitMix64(state: 0x5741_524C_4F57_0004)
        let fieldA = makeStarField(rng: &rng)
        // Independent field: fresh random draw, no shared geometry with fieldA.
        var otherRng = SplitMix64(state: 0xDEAD_BEEF_0000_0005)
        var fieldB: [SynthStar] = []
        while fieldB.count < 40 {
            let c = Self.tint(otherRng.uniform())
            let candidate = SynthStar(x: otherRng.uniform(25, Double(Self.width - 25)),
                                      y: otherRng.uniform(25, Double(Self.height - 25)),
                                      amp: otherRng.uniform(0.25, 0.55),
                                      sigma: otherRng.uniform(1.2, 1.8),
                                      tintR: c.r, tintG: c.g, tintB: c.b)
            let clear = fieldB.allSatisfy { hypot($0.x - candidate.x, $0.y - candidate.y) > 16 }
            if clear { fieldB.append(candidate) }
        }

        let stacker = CPUStacker()
        stacker.reset(width: Self.width, height: Self.height)
        let refBuffer = render(stars: fieldA, dx: 0, dy: 0, rotationDeg: 0,
                               noiseSigma: 0.02, rng: &rng)
        XCTAssertTrue(stacker.add(frame: makeFrame(index: 0, image: try makeImage(refBuffer))))

        let otherBuffer = render(stars: fieldB, dx: 0, dy: 0, rotationDeg: 0,
                                 noiseSigma: 0.02, rng: &rng)
        let accepted = stacker.add(frame: makeFrame(index: 1, image: try makeImage(otherBuffer)))
        if accepted {
            // If a chance alignment squeaks through the vote, the residual gate must have held.
            XCTAssertLessThanOrEqual(stacker.lastResidualPx, 2.0)
            XCTAssertGreaterThanOrEqual(stacker.lastMatchCount, 5)
        } else {
            XCTAssertEqual(stacker.currentResult().rejected, 1)
        }
    }
}
