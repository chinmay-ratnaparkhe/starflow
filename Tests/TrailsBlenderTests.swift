import XCTest
import CoreGraphics
@testable import StarFlow

/// TrailsBlender verification on synthetic gaussian stars (no hardware, no fixtures).
/// Design gate: lighten (max) blending a star that drifts across the frames must draw
/// a streak much longer than any single frame's PSF, while a static star stays a point.
final class TrailsBlenderTests: XCTestCase {

    private static let width = 200
    private static let height = 120

    /// Detection threshold well above the 0.05 pedestal and well below the 0.9 peak,
    /// so 8-bit CGImage round-trips can't flip a pixel across it.
    private static let threshold: Float = 0.3

    // MARK: - Synthetic frames

    /// Gaussian stars (amp 0.85, sigma 1.5) over a 0.05 pedestal, clamped 0…1.
    /// Deterministic: no noise — the blend has no detection step to exercise.
    private func render(stars: [(x: Double, y: Double)], pedestal: Float = 0.05) -> [Float] {
        let w = Self.width, h = Self.height
        var buffer = [Float](repeating: pedestal, count: w * h)
        let amp = 0.85, sigma = 1.5
        let inv = 1.0 / (2 * sigma * sigma)
        let r = Int((4 * sigma).rounded(.up))
        for star in stars {
            let x0 = max(0, Int(star.x) - r), x1 = min(w - 1, Int(star.x) + r)
            let y0 = max(0, Int(star.y) - r), y1 = min(h - 1, Int(star.y) + r)
            guard x0 <= x1, y0 <= y1 else { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) - star.x
                    let dy = Double(y) - star.y
                    buffer[y * w + x] += Float(amp * exp(-(dx * dx + dy * dy) * inv))
                }
            }
        }
        for i in 0..<buffer.count {
            buffer[i] = min(1, max(0, buffer[i]))
        }
        return buffer
    }

    private func makeFrame(index: Int, _ values: [Float]) throws -> SubFrame {
        let image = try XCTUnwrap(
            CPUStacker.grayImage(from: values, width: Self.width, height: Self.height),
            "failed to build synthetic CGImage")
        return SubFrame(index: index, timestamp: Date(), exposureSeconds: 1.0, iso: 400,
                        pixelData: image)
    }

    /// Horizontal extent (px) of pixels above the threshold within ±`band` rows of `y` —
    /// the streak-length measure for a horizontal trail.
    private func horizontalExtent(in buffer: [Float], aroundY y: Int, band: Int = 4) -> Int {
        var minX = Int.max
        var maxX = Int.min
        for yy in max(0, y - band)...min(Self.height - 1, y + band) {
            let row = yy * Self.width
            for x in 0..<Self.width where buffer[row + x] > Self.threshold {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        return maxX >= minX ? maxX - minX + 1 : 0
    }

    // MARK: - Tests

    /// 12 frames with one star drifting +4 px/frame (44 px of total travel) and one
    /// static star: the max blend must stretch the drifter into a streak several times
    /// longer than the single-frame PSF, while the static star stays PSF-sized.
    func testMaxBlendDrawsStreaksLongerThanSingleFramePSF() throws {
        let frameCount = 12
        let stepX = 4.0
        let trailStartX = 30.0, trailY = 60.0
        let staticX = 160.0, staticY = 30.0

        let blender = TrailsBlender()
        blender.reset(width: Self.width, height: Self.height)

        var singleFramePSFExtent = 0
        for i in 0..<frameCount {
            let buffer = render(stars: [
                (x: trailStartX + stepX * Double(i), y: trailY),
                (x: staticX, y: staticY),
            ])
            if i == 0 {
                singleFramePSFExtent = horizontalExtent(in: buffer, aroundY: Int(trailY))
            }
            XCTAssertTrue(blender.add(frame: try makeFrame(index: i, buffer)),
                          "clean frame \(i) must be accepted")
        }

        // Sanity: a single frame's star really is a compact point.
        XCTAssertGreaterThan(singleFramePSFExtent, 0)
        XCTAssertLessThanOrEqual(singleFramePSFExtent, 10,
                                 "single-frame PSF should be a few pixels wide")

        let blend = blender.accumulatedMax()
        let streakExtent = horizontalExtent(in: blend, aroundY: Int(trailY))
        let travel = Int(stepX * Double(frameCount - 1))   // 44 px of drift

        XCTAssertGreaterThan(streakExtent, 3 * singleFramePSFExtent,
                             "streak (\(streakExtent) px) must dwarf the PSF "
                             + "(\(singleFramePSFExtent) px)")
        XCTAssertGreaterThanOrEqual(streakExtent, travel,
                                    "streak must span at least the star's travel")

        // The static star must NOT smear: lighten blend leaves stationary points alone.
        let staticExtent = horizontalExtent(in: blend, aroundY: Int(staticY))
        XCTAssertLessThanOrEqual(staticExtent, singleFramePSFExtent + 2,
                                 "static star grew from \(singleFramePSFExtent) to "
                                 + "\(staticExtent) px — max blend must not smear it")

        // Max blend preserves peak brightness (mean stacking would dilute a moving
        // star to ~1/12th of this).
        let peak = blend.max() ?? 0
        XCTAssertGreaterThan(peak, 0.8, "streak peak must keep single-frame brightness")

        let result = blender.currentResult()
        XCTAssertEqual(result.accepted, frameCount)
        XCTAssertEqual(result.rejected, 0)
        XCTAssertEqual(result.integrationSeconds, Double(frameCount), accuracy: 0.001)
        XCTAssertNotNil(result.preview)
        XCTAssertNotNil(blender.finalImage())
    }

    /// COLOUR (field-report regression: finals came out grayscale): a warm-tinted
    /// star must keep its tint along the whole trail — the max blend runs per
    /// channel and the output image is genuinely RGB.
    func testTrailsKeepStarColorAlongTheArc() throws {
        let frameCount = 6
        let stepX = 8.0
        let startX = 40.0, y = 40.0
        let tint = (r: 1.0, g: 0.55, b: 0.35)   // warm orange star

        let blender = TrailsBlender()
        blender.reset(width: Self.width, height: Self.height)

        for i in 0..<frameCount {
            let base = render(stars: [(x: startX + stepX * Double(i), y: y)])
            // Neutral pedestal, tinted star: plane_c = pedestal + (star − pedestal)·tint_c.
            let r = base.map { 0.05 + ($0 - 0.05) * Float(tint.r) }
            let g = base.map { 0.05 + ($0 - 0.05) * Float(tint.g) }
            let b = base.map { 0.05 + ($0 - 0.05) * Float(tint.b) }
            let image = try XCTUnwrap(
                CPUStacker.rgbImage(r: r, g: g, b: b, width: Self.width, height: Self.height))
            let frame = SubFrame(index: i, timestamp: Date(), exposureSeconds: 1.0, iso: 400,
                                 pixelData: image)
            XCTAssertTrue(blender.add(frame: frame), "colour frame \(i) must be accepted")
        }

        // Every star position along the arc must stay red-leaning in the blend.
        let rgb = blender.accumulatedRGBMax()
        for i in 0..<frameCount {
            let idx = Int(y) * Self.width + Int(startX + stepX * Double(i))
            XCTAssertGreaterThan(rgb.r[idx] - rgb.b[idx], 0.3,
                                 "trail lost its colour at arc position \(i)")
        }

        // The final image is a real colour image with visible channel variance.
        let final = try XCTUnwrap(blender.finalImage())
        XCTAssertEqual(final.colorSpace?.model, .rgb, "trails final must be RGB, not gray")
        let planes = try XCTUnwrap(
            CPUStacker.rgbFloats(from: final, width: final.width, height: final.height))
        var maxSpread: Float = 0
        for i in 0..<planes.r.count {
            let hi = max(planes.r[i], planes.g[i], planes.b[i])
            let lo = min(planes.r[i], planes.g[i], planes.b[i])
            maxSpread = max(maxSpread, hi - lo)
        }
        XCTAssertGreaterThan(maxSpread, 0.3, "trail image must be visibly coloured")

        // Luminance accessor still tracks the streak for the legacy geometry checks.
        let streak = horizontalExtent(in: blender.accumulatedMax(), aroundY: Int(y))
        XCTAssertGreaterThanOrEqual(streak, Int(stepX * Double(frameCount - 1)),
                                    "colour blend must still draw the full streak")
    }

    /// Undecodable frames and washed-out frames (headlights across the lens) are
    /// rejected and counted; a washout must not bleach the accumulated trails.
    func testRejectsUndecodableAndWashedOutFrames() throws {
        let blender = TrailsBlender()
        blender.reset(width: Self.width, height: Self.height)

        // No pixel data → rejected.
        let empty = SubFrame(index: 0, timestamp: Date(), exposureSeconds: 1.0, iso: 400,
                             pixelData: nil)
        XCTAssertFalse(blender.add(frame: empty), "nil pixelData must be rejected")

        // Reference frame: normal night pedestal.
        let dark = render(stars: [(x: 100.0, y: 60.0)])
        XCTAssertTrue(blender.add(frame: try makeFrame(index: 1, dark)))

        // Washed-out frame: background leaps from 0.05 to 0.6 — reject, don't blend.
        let washed = render(stars: [], pedestal: 0.6)
        XCTAssertFalse(blender.add(frame: try makeFrame(index: 2, washed)),
                       "a washed-out frame would permanently bleach the max buffer")

        let blend = blender.accumulatedMax()
        let corner = blend[5 * Self.width + 5]   // far from the star
        XCTAssertLessThan(corner, 0.2, "rejected washout must not raise the background")

        let result = blender.currentResult()
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(result.rejected, 2)
        XCTAssertEqual(result.integrationSeconds, 1.0, accuracy: 0.001)
    }
}
