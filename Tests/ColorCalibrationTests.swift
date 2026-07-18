import XCTest
import CoreGraphics
@testable import StarFlow

/// Star-colour calibration (SPCC-lite, feature 6) against synthetic stacks.
///
/// Stacks are synthesized directly in the calibrator's input space: flat
/// per-channel pedestals plus Gaussian stars whose per-channel amplitudes are
/// derived from their B−V through the SAME `bvToExpectedRatios` conversion the
/// calibrator trusts, then a known global colour cast is multiplied into the R
/// and B channels. The calibrator must recover the inverse cast within 5%,
/// refuse to calibrate on fewer than 5 usable stars, clamp runaway gains to
/// [0.5, 2.0], and the B−V conversion itself must be monotonic (hotter star =
/// bluer) and anchored at the average-spiral-galaxy white reference.
final class ColorCalibrationTests: XCTestCase {

    private let width = 220
    private let height = 180

    // MARK: - Synthesis

    /// Nine stars spanning blue (−0.2) to Betelgeuse-red (1.85), placed well
    /// inside the measurement margin and far enough apart that no star's PSF
    /// reaches a neighbour's background annulus.
    private let starField: [(bv: Double, x: Double, y: Double, amp: Double)] = [
        (-0.20, 30.0, 30.0, 0.50),
        (0.00, 80.0, 30.0, 0.42),
        (0.30, 130.0, 30.0, 0.36),
        (0.65, 180.0, 30.0, 0.48),
        (0.90, 30.0, 90.0, 0.40),
        (1.20, 80.0, 90.0, 0.34),
        (1.50, 130.0, 90.0, 0.45),
        (1.85, 180.0, 90.0, 0.38),
        (0.50, 105.0, 150.0, 0.44),
    ]

    /// Render pedestal + Gaussian stars into three planes. Star amplitudes per
    /// channel follow the star's expected colour; `castR`/`castB` multiply the
    /// whole R/B channels (pedestal included) like a camera white-balance
    /// error would. Optionally adds a red "hot blob" saboteur with a colour no
    /// star could have, to exercise the sigma-clipped median.
    private func renderStack(castR: Double, castB: Double,
                             stars: [(bv: Double, x: Double, y: Double, amp: Double)],
                             redBlobAt: (x: Double, y: Double)? = nil)
        -> (r: [Float], g: [Float], b: [Float]) {
        var r = [Float](repeating: Float(0.02 * castR), count: width * height)
        var g = [Float](repeating: 0.02, count: width * height)
        var b = [Float](repeating: Float(0.02 * castB), count: width * height)
        func addGaussian(_ plane: inout [Float], x: Double, y: Double, amp: Double) {
            let sigma = 1.4
            let inv = 1.0 / (2 * sigma * sigma)
            let radius = 6
            let x0 = max(0, Int(x) - radius), x1 = min(width - 1, Int(x) + radius)
            let y0 = max(0, Int(y) - radius), y1 = min(height - 1, Int(y) + radius)
            for yy in y0...y1 {
                for xx in x0...x1 {
                    let dx = Double(xx) - x, dy = Double(yy) - y
                    plane[yy * width + xx] += Float(amp * exp(-(dx * dx + dy * dy) * inv))
                }
            }
        }
        for star in stars {
            let expected = BrightStar.bvToExpectedRatios(bv: star.bv)
            addGaussian(&r, x: star.x, y: star.y, amp: star.amp * expected.rOverG * castR)
            addGaussian(&g, x: star.x, y: star.y, amp: star.amp)
            addGaussian(&b, x: star.x, y: star.y, amp: star.amp * expected.bOverG * castB)
        }
        if let blob = redBlobAt {
            addGaussian(&r, x: blob.x, y: blob.y, amp: 0.7)
            addGaussian(&g, x: blob.x, y: blob.y, amp: 0.05)
            addGaussian(&b, x: blob.x, y: blob.y, amp: 0.05)
        }
        return (r, g, b)
    }

    /// Matches with deliberate ±~1 px prediction error, exercising the
    /// calibrator's local-peak re-centring (solve frame vs stack reference can
    /// drift by a couple of pixels in the field).
    private func matches(for stars: [(bv: Double, x: Double, y: Double, amp: Double)])
        -> [ColorCalibrator.MatchedStar] {
        stars.enumerated().map { i, star in
            ColorCalibrator.MatchedStar(bv: star.bv,
                                        x: star.x + (i.isMultiple(of: 2) ? 0.9 : -1.1),
                                        y: star.y + (i.isMultiple(of: 3) ? -0.8 : 1.0))
        }
    }

    // MARK: - Cast recovery

    /// A known colour cast (R ×0.8, B ×1.25), plus one hot red saboteur blob
    /// among the matches: the fitted gains must invert the cast within 5%.
    func testRecoversInjectedColorCastWithinFivePercent() {
        let castR = 0.8, castB = 1.25
        let planes = renderStack(castR: castR, castB: castB, stars: starField,
                                 redBlobAt: (x: 40.0, y: 150.0))
        var all = matches(for: starField)
        all.append(ColorCalibrator.MatchedStar(bv: 0.65, x: 40.0, y: 150.0))  // saboteur
        guard let gains = ColorCalibrator.calibrate(matches: all,
                                                    r: planes.r, g: planes.g, b: planes.b,
                                                    width: width, height: height) else {
            return XCTFail("calibration must succeed on 9 clean stars")
        }
        XCTAssertEqual(gains.rGain, 1.0 / castR, accuracy: 0.05 / castR,
                       "rGain must invert the R cast")
        XCTAssertEqual(gains.bGain, 1.0 / castB, accuracy: 0.05 / castB,
                       "bGain must invert the B cast")
        XCTAssertGreaterThanOrEqual(gains.starCount, 9)
    }

    /// No cast at all: gains stay within 5% of unity (no invented colour).
    func testNeutralStackFitsUnityGains() {
        let planes = renderStack(castR: 1.0, castB: 1.0, stars: starField)
        guard let gains = ColorCalibrator.calibrate(matches: matches(for: starField),
                                                    r: planes.r, g: planes.g, b: planes.b,
                                                    width: width, height: height) else {
            return XCTFail("calibration must succeed on a neutral stack")
        }
        XCTAssertEqual(gains.rGain, 1.0, accuracy: 0.05)
        XCTAssertEqual(gains.bGain, 1.0, accuracy: 0.05)
    }

    // MARK: - Honest refusal below 5 usable stars

    func testFewerThanFiveMatchesReturnsNil() {
        let four = Array(starField.prefix(4))
        let planes = renderStack(castR: 0.8, castB: 1.25, stars: four)
        XCTAssertNil(ColorCalibrator.calibrate(matches: matches(for: four),
                                               r: planes.r, g: planes.g, b: planes.b,
                                               width: width, height: height),
                     "4 stars must not calibrate")
    }

    /// Six matches, but two point at empty background (their star drifted out
    /// of the stack): only 4 USABLE stars remain → nil, uncalibrated.
    func testMatchesOnEmptyBackgroundDoNotCountAsUsable() {
        let four = Array(starField.prefix(4))
        let planes = renderStack(castR: 0.9, castB: 1.1, stars: four)
        var all = matches(for: four)
        all.append(ColorCalibrator.MatchedStar(bv: 0.4, x: 60.0, y: 150.0))
        all.append(ColorCalibrator.MatchedStar(bv: 1.1, x: 160.0, y: 150.0))
        XCTAssertNil(ColorCalibrator.calibrate(matches: all,
                                               r: planes.r, g: planes.g, b: planes.b,
                                               width: width, height: height),
                     "flat-background matches must not count toward the 5-star minimum")
    }

    func testMatchesTooCloseToEdgeAreSkipped() {
        let four = Array(starField.prefix(4))
        let planes = renderStack(castR: 1.0, castB: 1.0, stars: four)
        var all = matches(for: four)
        all.append(ColorCalibrator.MatchedStar(bv: 0.3, x: 2.0, y: 2.0))   // off-margin
        XCTAssertNil(ColorCalibrator.calibrate(matches: all,
                                               r: planes.r, g: planes.g, b: planes.b,
                                               width: width, height: height))
    }

    // MARK: - Gain clamping

    /// A grotesque cast (R ×0.2, B ×3.0) would want gains of 5 and 0.33 —
    /// both must clamp to the sane range [0.5, 2.0]. Amplitudes are scaled
    /// down so the boosted B channel stays below the saturation ceiling: this
    /// test is about clamping, not saturated-star exclusion.
    func testGainsClampToSaneRange() {
        let faint = starField.map { (bv: $0.bv, x: $0.x, y: $0.y, amp: $0.amp * 0.25) }
        let planes = renderStack(castR: 0.2, castB: 3.0, stars: faint)
        guard let gains = ColorCalibrator.calibrate(matches: matches(for: faint),
                                                    r: planes.r, g: planes.g, b: planes.b,
                                                    width: width, height: height) else {
            return XCTFail("calibration must still return (clamped) gains")
        }
        XCTAssertEqual(gains.rGain, ColorCalibrator.gainCeiling, accuracy: 1e-9)
        XCTAssertEqual(gains.bGain, ColorCalibrator.gainFloor, accuracy: 1e-9)
    }

    // MARK: - Saturated-star exclusion

    /// The catalog's bright stars are exactly the ones a phone sensor clips,
    /// and a clipped core reads R≈G≈B regardless of the star's true colour.
    /// A saturated star among the matches must not contribute: five clean
    /// stars plus one saturated → the fit uses exactly the five clean ones.
    func testSaturatedStarsAreExcludedFromTheFit() {
        let five = Array(starField.prefix(5))
        var stars = five
        stars.append((bv: -0.20, x: 130.0, y: 150.0, amp: 2.5))   // clipped core
        let planes = renderStack(castR: 1.0, castB: 1.0, stars: stars)
        guard let gains = ColorCalibrator.calibrate(matches: matches(for: stars),
                                                    r: planes.r, g: planes.g, b: planes.b,
                                                    width: width, height: height) else {
            return XCTFail("five clean stars must still calibrate")
        }
        XCTAssertEqual(gains.starCount, 5,
                       "the saturated star must not count as a usable star")
        XCTAssertEqual(gains.rGain, 1.0, accuracy: 0.05)
        XCTAssertEqual(gains.bGain, 1.0, accuracy: 0.05)
    }

    /// Saturated stars must not pad the honesty minimum either: four clean
    /// stars plus one saturated is still only four usable → nil, uncalibrated.
    func testSaturatedStarDoesNotCountTowardMinimum() {
        var stars = Array(starField.prefix(4))
        stars.append((bv: 0.65, x: 130.0, y: 150.0, amp: 2.5))    // clipped core
        let planes = renderStack(castR: 0.9, castB: 1.1, stars: stars)
        XCTAssertNil(ColorCalibrator.calibrate(matches: matches(for: stars),
                                               r: planes.r, g: planes.g, b: planes.b,
                                               width: width, height: height),
                     "a saturated star must not substitute for a fifth usable star")
    }

    // MARK: - B−V conversion

    /// Anchored at the white reference and strictly monotonic across the valid
    /// range: hotter star (smaller B−V) → bluer (larger B/G, smaller R/G).
    func testBvConversionAnchoredAndMonotonic() {
        let white = BrightStar.bvToExpectedRatios(bv: BrightStar.whiteReferenceBV)
        XCTAssertEqual(white.rOverG, 1.0, accuracy: 1e-9)
        XCTAssertEqual(white.bOverG, 1.0, accuracy: 1e-9)

        var previous = BrightStar.bvToExpectedRatios(bv: -0.4)
        for step in 1...48 {
            let bv = -0.4 + Double(step) * 0.05
            let ratios = BrightStar.bvToExpectedRatios(bv: bv)
            XCTAssertGreaterThan(ratios.rOverG, previous.rOverG,
                                 "R/G must rise with B−V (redder star) at \(bv)")
            XCTAssertLessThan(ratios.bOverG, previous.bOverG,
                              "B/G must fall with B−V (redder star) at \(bv)")
            previous = ratios
        }
        // Sanity anchors: Vega-white is bluer than the reference, Betelgeuse
        // far redder.
        let vega = BrightStar.bvToExpectedRatios(bv: 0.0)
        XCTAssertLessThan(vega.rOverG, 1.0)
        XCTAssertGreaterThan(vega.bOverG, 1.0)
        let betelgeuse = BrightStar.bvToExpectedRatios(bv: 1.85)
        XCTAssertGreaterThan(betelgeuse.rOverG, 1.0)
        XCTAssertLessThan(betelgeuse.bOverG, 1.0)
        // Out-of-range inputs clamp rather than extrapolate.
        let clamped = BrightStar.bvToExpectedRatios(bv: 9.0)
        let edge = BrightStar.bvToExpectedRatios(bv: 2.0)
        XCTAssertEqual(clamped.rOverG, edge.rOverG, accuracy: 1e-12)
    }

    /// The catalog's B−V values are sane and the famous anchors are right.
    func testCatalogCarriesSaneBVValues() {
        for star in PlateSolver.catalog {
            XCTAssertGreaterThanOrEqual(star.bv, -0.4, star.name)
            XCTAssertLessThanOrEqual(star.bv, 2.0, star.name)
        }
        XCTAssertEqual(PlateSolver.catalog.first { $0.name == "Vega" }?.bv, 0.00)
        XCTAssertEqual(PlateSolver.catalog.first { $0.name == "Betelgeuse" }?.bv, 1.85)
        XCTAssertEqual(PlateSolver.catalog.first { $0.name == "Sirius" }?.bv, 0.00)
        XCTAssertEqual(PlateSolver.catalog.first { $0.name == "Arcturus" }?.bv, 1.23)
    }

    // MARK: - CPUStacker render-time gains

    /// `applyChannelGains` must change the RENDERED image only: the linear
    /// accumulators stay bit-identical, and `reset` restores neutral gains.
    func testChannelGainsAffectRenderOnlyAndResetRestoresNeutral() throws {
        let side = 64
        let count = side * side
        var r = [Float](repeating: 0.05, count: count)
        var g = [Float](repeating: 0.05, count: count)
        var b = [Float](repeating: 0.05, count: count)
        // One warm star mid-frame (R-heavy, so both gain directions show).
        let sigma = 1.6, inv = 1.0 / (2 * sigma * sigma)
        for y in 24...40 {
            for x in 24...40 {
                let dx = Double(x) - 32.0, dy = Double(y) - 32.0
                let k = exp(-(dx * dx + dy * dy) * inv)
                r[y * side + x] += Float(0.50 * k)
                g[y * side + x] += Float(0.35 * k)
                b[y * side + x] += Float(0.45 * k)
            }
        }
        let image = try XCTUnwrap(CPUStacker.rgbImage(r: r, g: g, b: b,
                                                      width: side, height: side))
        let frame = SubFrame(index: 0, timestamp: Date(), exposureSeconds: 1,
                             iso: 800, pixelData: image)
        let stacker = CPUStacker()
        stacker.reset(width: side, height: side)
        XCTAssertTrue(stacker.add(frame: frame))

        let accumulatedBefore = stacker.accumulatedRGB()
        let renderedBefore = try XCTUnwrap(stacker.finalImage())
        let before = try XCTUnwrap(CPUStacker.rgbFloats(from: renderedBefore,
                                                        width: side, height: side))

        stacker.applyChannelGains(r: 1.6, b: 0.6)
        let gains = stacker.channelGains()
        XCTAssertEqual(gains.r, 1.6, accuracy: 1e-6)
        XCTAssertEqual(gains.b, 0.6, accuracy: 1e-6)

        let accumulatedAfter = stacker.accumulatedRGB()
        XCTAssertEqual(accumulatedAfter.r, accumulatedBefore.r,
                       "R accumulator must be untouched by render gains")
        XCTAssertEqual(accumulatedAfter.g, accumulatedBefore.g)
        XCTAssertEqual(accumulatedAfter.b, accumulatedBefore.b)

        let renderedAfter = try XCTUnwrap(stacker.finalImage())
        let after = try XCTUnwrap(CPUStacker.rgbFloats(from: renderedAfter,
                                                       width: side, height: side))
        XCTAssertTrue((0..<count).contains { after.r[$0] > before.r[$0] + 0.02 },
                      "R gain 1.6 must brighten some star pixel in the render")
        XCTAssertTrue((0..<count).contains { after.b[$0] < before.b[$0] - 0.02 },
                      "B gain 0.6 must dim some star pixel in the render")

        stacker.reset(width: side, height: side)
        let neutral = stacker.channelGains()
        XCTAssertEqual(neutral.r, 1.0)
        XCTAssertEqual(neutral.b, 1.0)
    }
}
