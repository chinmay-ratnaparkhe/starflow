import Foundation

// MARK: - ColorCalibrator (Star-colour calibration, SPCC-lite — docs/ROADMAP-v3.md #6)
//
// The principle (as documented for Siril's PCC and PixInsight's SPCC): stars
// the plate solver matched to the catalog have KNOWN colours — their B−V index
// predicts the linear R/G and B/G flux ratios a neutral camera would record
// (`BrightStar.bvToExpectedRatios`). Measure what the stack ACTUALLY recorded
// for those same stars and fit the two global channel gains that reconcile the
// two, with the average-spiral-galaxy white reference baked into the expected
// ratios. Two numbers for the whole image — no per-pixel repainting, no
// invented colour.
//
// Per star: a small-aperture flux per channel around the star's predicted
// position (re-centred on the local peak, so a couple of pixels of prediction
// error — registration drift between the solve frame and the stack reference —
// is absorbed), background-subtracted with the median of a surrounding
// annulus. Per-star gain samples gainR = expected(R/G) / measured(R/G) (and
// likewise for B) are combined by a sigma-clipped median, so a star sitting on
// a satellite streak or a hot pixel cannot steer the fit.
//
// Honesty contract: fewer than `minimumStars` USABLE stars (in-frame, positive
// background-subtracted flux in all three channels, and NOT saturated) returns
// nil — the caller leaves the image uncalibrated rather than pretending.
// Saturation matters here more than in most pipelines: the catalog is the
// sky's BRIGHTEST stars, exactly the ones a phone sensor clips first, and a
// clipped core reads R≈G≈B no matter the star's true colour — feeding it to
// the fit would drag both gains toward a colour the sky never had. Any star
// whose aperture peak reaches `saturationCeiling` in any channel is excluded.
// Fitted gains are clamped to `gainFloor...gainCeiling`; a fit that WANTS to
// leave that range is measuring something other than a white-balance error.
//
// Pure functions over plain buffers — nonisolated, no clocks, no globals;
// tests drive it with synthetic stacks.
public enum ColorCalibrator {

    // MARK: - Types

    /// One plate-solver match projected into the stack grid: the catalog
    /// colour plus the star's predicted pixel position (stack-grid
    /// coordinates, y down).
    public struct MatchedStar: Sendable {
        public var bv: Double
        public var x: Double
        public var y: Double
        public init(bv: Double, x: Double, y: Double) {
            self.bv = bv; self.x = x; self.y = y
        }
    }

    /// The fitted global channel gains, to be applied at render time
    /// (multiply R by `rGain`, B by `bGain`; G is the reference and stays 1).
    public struct ChannelGains: Equatable, Sendable {
        public var rGain: Double
        public var bGain: Double
        /// Stars that actually contributed measurements.
        public var starCount: Int
        public init(rGain: Double, bGain: Double, starCount: Int) {
            self.rGain = rGain; self.bGain = bGain; self.starCount = starCount
        }
    }

    // MARK: - Tunables (fixed)

    /// Fewer usable stars than this → nil (uncalibrated, honest).
    public static let minimumStars = 5
    /// Sane-gain clamp: a correct white-balance fix is a modest correction.
    public static let gainFloor = 0.5
    public static let gainCeiling = 2.0
    /// Aperture / background-annulus radii (stack-grid px).
    static let apertureRadius = 3.0
    static let annulusInnerRadius = 5.0
    static let annulusOuterRadius = 8.0
    /// Peak re-centring search radius around the predicted position (px).
    static let recenterRadius = 2
    /// Stars closer to an edge than this cannot be measured (the annulus
    /// would fall off-grid) — callers may pre-filter with it.
    public static var measurementMargin: Double { annulusOuterRadius + Double(recenterRadius) + 1 }
    /// Sigma-clip threshold for the robust gain combine.
    static let clipKappa = 2.5
    /// A star must clear this background-subtracted flux (mean-units × pixels)
    /// in EVERY channel to be usable. Real stars measure orders of magnitude
    /// above it; a flat patch measures ~0 ± floating-point dust, and a ratio of
    /// two near-zero fluxes is noise, not colour.
    static let minimumFlux = 1e-6
    /// A star whose aperture peak reaches this level (mean-accumulator units,
    /// 0…1 — frames are 8-bit, so a core clipped in every sub averages to ~1.0)
    /// in ANY channel is excluded: a clipped channel reads a flat ceiling, not
    /// the star's colour, and the catalog's bright stars are the first to clip.
    /// 0.95 also catches cores clipped in most-but-not-all subs.
    static let saturationCeiling: Float = 0.95

    // MARK: - Calibration

    /// Fit the two global channel gains from matched stars against the stack's
    /// linear per-channel mean accumulators (row-major, `width`×`height` —
    /// `CPUStacker.accumulatedRGB` order). Returns nil when fewer than
    /// `minimumStars` stars yield a usable measurement.
    public static func calibrate(matches: [MatchedStar],
                                 r: [Float], g: [Float], b: [Float],
                                 width: Int, height: Int) -> ChannelGains? {
        let count = width * height
        guard width > 0, height > 0,
              r.count == count, g.count == count, b.count == count else { return nil }
        var rSamples: [Double] = []
        var bSamples: [Double] = []
        for star in matches {
            guard let flux = measureFlux(xGuess: star.x, yGuess: star.y,
                                         r: r, g: g, b: b,
                                         width: width, height: height),
                  flux.r > minimumFlux, flux.g > minimumFlux, flux.b > minimumFlux,
                  flux.r.isFinite, flux.g.isFinite, flux.b.isFinite else { continue }
            let expected = BrightStar.bvToExpectedRatios(bv: star.bv)
            rSamples.append(expected.rOverG / (flux.r / flux.g))
            bSamples.append(expected.bOverG / (flux.b / flux.g))
        }
        guard rSamples.count >= minimumStars else { return nil }
        let rGain = min(gainCeiling, max(gainFloor, robustGain(rSamples)))
        let bGain = min(gainCeiling, max(gainFloor, robustGain(bSamples)))
        return ChannelGains(rGain: rGain, bGain: bGain, starCount: rSamples.count)
    }

    // MARK: - Aperture photometry (shared with tests)

    /// Background-annulus-subtracted aperture flux per channel around the
    /// star's predicted position. The centre is first re-snapped to the
    /// brightest summed-RGB pixel within `recenterRadius`, absorbing small
    /// prediction errors. Nil when the measurement footprint leaves the grid,
    /// or when the aperture peak reaches `saturationCeiling` in any channel —
    /// a clipped core carries no colour information (see the tunable's doc).
    static func measureFlux(xGuess: Double, yGuess: Double,
                            r: [Float], g: [Float], b: [Float],
                            width: Int, height: Int)
        -> (r: Double, g: Double, b: Double)? {
        // Validate BEFORE the Int conversions: Int(Double.nan) and huge
        // magnitudes trap in Swift — a bad coordinate must decline (nil),
        // never crash. In-grid values always survive this pre-check.
        guard xGuess.isFinite, yGuess.isFinite,
              xGuess >= 0, xGuess < Double(width),
              yGuess >= 0, yGuess < Double(height) else { return nil }
        var cx = Int(xGuess.rounded())
        var cy = Int(yGuess.rounded())
        let outer = Int(annulusOuterRadius.rounded(.up))
        let reach = outer + recenterRadius
        guard cx - reach >= 0, cx + reach < width,
              cy - reach >= 0, cy + reach < height else { return nil }

        // Re-centre on the local peak of the channel sum.
        var bestValue = -Double.infinity
        var bestX = cx, bestY = cy
        for dy in -recenterRadius...recenterRadius {
            for dx in -recenterRadius...recenterRadius {
                let i = (cy + dy) * width + (cx + dx)
                let v = Double(r[i]) + Double(g[i]) + Double(b[i])
                if v > bestValue { bestValue = v; bestX = cx + dx; bestY = cy + dy }
            }
        }
        cx = bestX; cy = bestY

        var apR = 0.0, apG = 0.0, apB = 0.0
        var apPixels = 0.0
        var apPeak: Float = 0
        var bgR: [Double] = [], bgG: [Double] = [], bgB: [Double] = []
        for dy in -outer...outer {
            for dx in -outer...outer {
                let d = Double(dx * dx + dy * dy).squareRoot()
                let i = (cy + dy) * width + (cx + dx)
                if d <= apertureRadius {
                    apR += Double(r[i]); apG += Double(g[i]); apB += Double(b[i])
                    apPixels += 1
                    apPeak = max(apPeak, r[i], g[i], b[i])
                } else if d >= annulusInnerRadius, d <= annulusOuterRadius {
                    bgR.append(Double(r[i])); bgG.append(Double(g[i])); bgB.append(Double(b[i]))
                }
            }
        }
        guard apPixels > 0, !bgR.isEmpty else { return nil }
        // Saturated-star exclusion: a clipped channel is a flat ceiling, not
        // colour — the star is unusable, whatever its other channels say.
        guard apPeak < saturationCeiling else { return nil }
        return (apR - median(bgR) * apPixels,
                apG - median(bgG) * apPixels,
                apB - median(bgB) * apPixels)
    }

    // MARK: - Robust combine

    /// Median, one sigma-clip round (drop samples > `clipKappa`·σ from the
    /// median), median of the survivors.
    static func robustGain(_ samples: [Double]) -> Double {
        let m = median(samples)
        let n = Double(samples.count)
        let variance = samples.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / n
        let sigma = variance.squareRoot()
        guard sigma > 1e-12 else { return m }
        let kept = samples.filter { abs($0 - m) <= clipKappa * sigma }
        return kept.isEmpty ? m : median(kept)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : 0.5 * (sorted[mid - 1] + sorted[mid])
    }
}
