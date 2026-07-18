import Foundation
import CoreGraphics

// MARK: - CityscapePhase

/// Which half of a cityscape dual-phase session is capturing right now
/// (drives the Foreground/Sky phase chips on the session screen).
public enum CityscapePhase: String, Sendable {
    case foreground = "Foreground"
    case sky = "Sky"
}

// MARK: - CityscapeComposer

/// Cityscape dual-phase compositor (feature 10, v1) — pure math, no actor,
/// no ML model: the sky mask is COMPUTED from luminance + gradient statistics,
/// never guessed by a network.
///
/// Pipeline (all unit-tested on synthetic scenes):
///  1. Robust-mean the identical base foreground frames (per-pixel trimmed
///     mean: min and max samples dropped — headlights, a passer-by's phone
///     light — with 4+ frames; plain mean below that).
///  2. Mertens-lite exposure fusion of the bracket (base / −2 EV / +1 EV):
///     per-pixel well-exposedness weights on each frame's own luminance,
///     single weighted blend per channel. DELIBERATE v1 SIMPLIFICATION —
///     real Mertens fusion blends across a Laplacian pyramid so weight
///     transitions can't halo; the flat per-pixel blend here can leave soft
///     halos at hard bright/dark edges. Documented, accepted for v1.
///  3. Horizon/sky mask from the fused foreground: per-row brightness +
///     horizontal-gradient statistics, bright-below/dark-above split, then a
///     per-column refinement and a median-filter cleanup (the v1 stand-in
///     for a full largest-connected-region pass — a median over columns
///     removes the same isolated outliers on the horizon curve).
///     GRAVITY PRIOR: inputs must arrive UPRIGHT (the session engine rotates
///     every frame for the measured capture tilt first), so "sky is above"
///     means "sky is at low row indices" by construction.
///  4. Feathered composite: sky stack above the mask, fused foreground
///     below, blended across a 12 px band per column.
///  5. Confidence grading: the mask's measured city/sky separation decides
///     high / medium / low. LOW never composites — the honest deliverable is
///     the two stacks separately, with the reason stated. Never a bad
///     composite silently.
public enum CityscapeComposer {

    // MARK: Tunables (fixed for v1)

    /// Identical base foreground frames captured after the bracket.
    public static let baseFrameCount = 6
    /// City-lights base ISO for the foreground bracket: lit signs and windows
    /// are bright — low gain keeps them unclipped (the sky phase brings its
    /// own high-ISO recipe).
    public static let foregroundBaseISO: Double = 100
    /// Feathered blend band across the horizon (px).
    public static let featherPx = 12
    /// Longest side frames are downscaled to for in-memory retention and for
    /// the compose grid (nine full 12 MP sensor frames would pin ~400 MB).
    public static let composeMaxSide = 1024
    /// Mask confidence thresholds on the measured city−sky row-score
    /// separation (absolute units: luminance 0…1 plus mean gradient).
    static let highSeparation = 0.25
    static let mediumSeparation = 0.10
    /// Minimum per-column luminance step to trust a column's own horizon over
    /// the global split.
    static let minColumnStep: Float = 0.05
    /// Well-exposedness weight: center and width of the gaussian on luminance.
    static let exposednessCenter: Float = 0.5
    static let exposednessSigma: Float = 0.2

    // MARK: Public types

    public enum Confidence: String, Sendable {
        case high, medium, low
    }

    /// Three linear colour planes on one grid (row-major, 0…1, row 0 = top).
    public struct Planes: Sendable {
        public var r: [Float]
        public var g: [Float]
        public var b: [Float]
        public init(r: [Float], g: [Float], b: [Float]) {
            self.r = r; self.g = g; self.b = b
        }
    }

    public struct HorizonEstimate: Sendable {
        /// Per-column boundary row: rows above (y < perColumn[x]) are sky.
        public var perColumn: [Int]
        /// Mean boundary row across columns.
        public var meanRow: Double
        /// Measured city−sky separation of the row score (absolute units).
        public var separation: Double
        public var confidence: Confidence
    }

    /// Everything the develop phase and the landing report need. `composite`
    /// is nil whenever confidence is low or the sky stack produced nothing —
    /// the reason string always says why, honestly.
    public struct Outcome: Sendable {
        public var composite: CGImage?
        public var foreground: CGImage?
        public var skyImage: CGImage?
        public var maskPreview: CGImage?
        public var confidence: Confidence
        public var horizonMeanRow: Double?
        public var reason: String
    }

    // MARK: Bracket recipes

    /// The 3-frame foreground bracket. The 1 s third-party exposure cap bounds
    /// shutter time from ABOVE, so EV moves ride whichever control is free:
    ///  - base:  cap-length exposure at the city base ISO (bright signs stay
    ///    unclipped at low gain),
    ///  - −2 EV: same ISO, exposure ÷ 4 — shortening is always allowed,
    ///  - +1 EV: exposure is already at the cap, so ISO × 2 carries the stop.
    public static func bracketRecipes(baseExposureSeconds: Double = 1.0,
                                      baseISO: Double = foregroundBaseISO) -> [CaptureRecipe] {
        let exposure = min(max(0.001, baseExposureSeconds), 1.0)
        return [
            CaptureRecipe(exposureSeconds: exposure, iso: baseISO,
                          targetSubCount: 1, nudgeTracking: false),
            CaptureRecipe(exposureSeconds: exposure / 4, iso: baseISO,
                          targetSubCount: 1, nudgeTracking: false),
            CaptureRecipe(exposureSeconds: exposure, iso: baseISO * 2,
                          targetSubCount: 1, nudgeTracking: false),
        ]
    }

    /// Aspect-preserving in-memory retention copy, longest side ≤ `maxSide`.
    /// Returns the image itself when it already fits.
    public static func retentionCopy(_ image: CGImage,
                                     maxSide: Int = composeMaxSide) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let longest = max(w, h)
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        let dw = max(1, Int((Double(w) * scale).rounded()))
        let dh = max(1, Int((Double(h) * scale).rounded()))
        guard let planes = CPUStacker.rgbFloats(from: image, width: dw, height: dh)
        else { return nil }
        return CPUStacker.rgbImage(r: planes.r, g: planes.g, b: planes.b,
                                   width: dw, height: dh)
    }

    // MARK: Robust mean

    /// Per-pixel trimmed mean over identical exposures: with 4+ frames the
    /// min and max samples are dropped (a headlight sweep or a hand in frame
    /// poisons at most the extremes), fewer frames fall back to a plain mean.
    /// Planes whose length differs from the first are ignored.
    public static func robustMean(_ planes: [[Float]]) -> [Float] {
        guard let first = planes.first else { return [] }
        let matching = planes.filter { $0.count == first.count }
        guard matching.count > 1 else { return first }
        let count = first.count
        let trim = matching.count >= 4
        let divisor = Float(trim ? matching.count - 2 : matching.count)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var sum: Float = 0
            var lo = Float.greatestFiniteMagnitude
            var hi = -Float.greatestFiniteMagnitude
            for plane in matching {
                let v = plane[i]
                sum += v
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
            out[i] = trim ? (sum - lo - hi) / divisor : sum / divisor
        }
        return out
    }

    // MARK: Exposure fusion (Mertens-lite)

    /// Rec.709 luminance of one plane set.
    public static func luminance(_ p: Planes) -> [Float] {
        let count = min(p.r.count, min(p.g.count, p.b.count))
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = 0.2126 * p.r[i] + 0.7152 * p.g[i] + 0.0722 * p.b[i]
        }
        return out
    }

    /// Mertens-lite exposure fusion: each frame's per-pixel weight is the
    /// well-exposedness of its OWN luminance, w = exp(−(L−0.5)²/(2·0.2²)),
    /// so clipped highlights and crushed shadows contribute least; the fused
    /// pixel is the weight-normalised blend per channel. Pyramid-free — see
    /// the type doc for the accepted v1 simplification. Frames whose plane
    /// length differs from the first are ignored; nil when nothing usable.
    public static func fuseExposures(_ frames: [Planes]) -> Planes? {
        guard let first = frames.first else { return nil }
        let count = first.r.count
        let usable = frames.filter {
            $0.r.count == count && $0.g.count == count && $0.b.count == count
        }
        guard !usable.isEmpty else { return nil }
        if usable.count == 1 { return usable[0] }
        var outR = [Float](repeating: 0, count: count)
        var outG = [Float](repeating: 0, count: count)
        var outB = [Float](repeating: 0, count: count)
        var weightSum = [Float](repeating: 0, count: count)
        let center = exposednessCenter
        let inv2Sigma2 = 1.0 / (2 * exposednessSigma * exposednessSigma)
        let floorWeight: Float = 1e-4   // uniform frames must never divide by zero
        for frame in usable {
            let luma = luminance(frame)
            for i in 0..<count {
                let d = luma[i] - center
                let w = exp(-d * d * inv2Sigma2) + floorWeight
                outR[i] += w * frame.r[i]
                outG[i] += w * frame.g[i]
                outB[i] += w * frame.b[i]
                weightSum[i] += w
            }
        }
        for i in 0..<count {
            let w = weightSum[i]
            outR[i] /= w; outG[i] /= w; outB[i] /= w
        }
        return Planes(r: outR, g: outG, b: outB)
    }

    // MARK: Horizon estimation

    /// Bright-below/dark-above horizon estimate from the fused foreground's
    /// luminance. Row score = mean brightness + mean horizontal gradient (a
    /// lit city is both brighter and busier than night sky); the global split
    /// maximises the below-minus-above score separation, then each column
    /// refines within a band around it and a 9-wide median filter cleans the
    /// curve (v1's largest-connected-region stand-in). The measured
    /// separation grades confidence in absolute units, so a low-contrast
    /// scene — or a sky BRIGHTER than the ground — honestly reads low.
    /// Inputs must be upright (sky at low rows); nil when the frame is too
    /// small to analyse.
    public static func estimateHorizon(luma: [Float], width: Int, height: Int)
        -> HorizonEstimate? {
        guard width >= 16, height >= 16, luma.count == width * height else { return nil }

        // Per-row statistics.
        var rowScore = [Double](repeating: 0, count: height)
        for y in 0..<height {
            let row = y * width
            var sum = 0.0
            var grad = 0.0
            for x in 0..<width {
                sum += Double(luma[row + x])
                if x + 1 < width {
                    grad += Double(abs(luma[row + x + 1] - luma[row + x]))
                }
            }
            rowScore[y] = sum / Double(width) + grad / Double(max(1, width - 1))
        }

        // Global split maximising meanBelow − meanAbove via prefix sums.
        var prefix = [Double](repeating: 0, count: height + 1)
        for y in 0..<height { prefix[y + 1] = prefix[y] + rowScore[y] }
        let total = prefix[height]
        let margin = max(4, height / 16)
        var bestRow = margin
        var bestSeparation = -Double.infinity
        for h in margin...(height - margin) {
            let above = prefix[h] / Double(h)
            let below = (total - prefix[h]) / Double(height - h)
            let separation = below - above
            if separation > bestSeparation {
                bestSeparation = separation
                bestRow = h
            }
        }

        let confidence: Confidence
        if bestSeparation >= highSeparation {
            confidence = .high
        } else if bestSeparation >= mediumSeparation {
            confidence = .medium
        } else {
            confidence = .low
        }
        if confidence == .low {
            // No trustworthy boundary — report the split for diagnostics but
            // don't refine per column (there is nothing real to refine).
            return HorizonEstimate(perColumn: [Int](repeating: bestRow, count: width),
                                   meanRow: Double(bestRow),
                                   separation: bestSeparation,
                                   confidence: .low)
        }

        // Per-column refinement inside a band around the global split: the
        // strongest downward luminance step wins; weak steps keep the global
        // row so a featureless column can't wander.
        let band = 2 * featherPx
        let lowY = max(4, bestRow - band)
        let highY = min(height - 4, bestRow + band)
        var perColumn = [Int](repeating: bestRow, count: width)
        if lowY < highY {
            for x in 0..<width {
                var columnBestRow = bestRow
                var columnBestStep: Float = 0
                for y in lowY...highY {
                    var below: Float = 0
                    for dy in 0...2 { below += luma[(y + dy) * width + x] }
                    below /= 3
                    var above: Float = 0
                    for dy in 1...3 { above += luma[(y - dy) * width + x] }
                    above /= 3
                    let step = below - above
                    if step > columnBestStep {
                        columnBestStep = step
                        columnBestRow = y
                    }
                }
                perColumn[x] = columnBestStep >= minColumnStep ? columnBestRow : bestRow
            }
        }

        // Median-filter cleanup over columns (radius 4): isolated outliers on
        // the horizon curve — a lone antenna, one noisy column — drop out,
        // the same effect a largest-connected-region pass buys at v1 scale.
        let radius = 4
        var cleaned = perColumn
        for x in 0..<width {
            let lo = max(0, x - radius)
            let hi = min(width - 1, x + radius)
            var window = Array(perColumn[lo...hi])
            window.sort()
            cleaned[x] = window[window.count / 2]
        }

        let meanRow = Double(cleaned.reduce(0, +)) / Double(width)
        return HorizonEstimate(perColumn: cleaned, meanRow: meanRow,
                               separation: bestSeparation, confidence: confidence)
    }

    // MARK: Feathered composite

    /// Sky stack above the mask, fused foreground below, alpha-feathered
    /// across `featherPx` rows per column (linear ramp centred on the
    /// boundary). Plane lengths must match `width`×`height`.
    public static func featheredComposite(foreground: Planes, sky: Planes,
                                          horizon: [Int],
                                          width: Int, height: Int) -> Planes {
        let count = width * height
        var outR = [Float](repeating: 0, count: count)
        var outG = [Float](repeating: 0, count: count)
        var outB = [Float](repeating: 0, count: count)
        let feather = Float(featherPx)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let i = row + x
                let alphaSky = min(1, max(0, (Float(horizon[x]) + feather / 2 - Float(y)) / feather))
                let alphaFore = 1 - alphaSky
                outR[i] = alphaSky * sky.r[i] + alphaFore * foreground.r[i]
                outG[i] = alphaSky * sky.g[i] + alphaFore * foreground.g[i]
                outB[i] = alphaSky * sky.b[i] + alphaFore * foreground.b[i]
            }
        }
        return Planes(r: outR, g: outG, b: outB)
    }

    /// Grayscale mask preview: white = sky, black = foreground, feathered the
    /// same way the composite blends.
    public static func maskPreviewImage(horizon: [Int], width: Int, height: Int) -> CGImage? {
        guard horizon.count == width, width > 0, height > 0 else { return nil }
        var mask = [Float](repeating: 0, count: width * height)
        let feather = Float(featherPx)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                mask[row + x] = min(1, max(0, (Float(horizon[x]) + feather / 2 - Float(y)) / feather))
            }
        }
        return CPUStacker.grayImage(from: mask, width: width, height: height)
    }

    // MARK: Top-level compose

    /// Full v1 composite. Inputs are CGImages already rotated UPRIGHT by the
    /// caller (the gravity prior — sky sits at the top of every plane):
    ///  - `baseFrames`: the identical base-exposure foreground frames
    ///    (bracket base + the 6 repeats), robust-meaned per channel,
    ///  - `underExposed` / `overExposed`: the −2 EV and +1 EV bracket frames,
    ///  - `sky`: the registered sky stack's final image (nil when the sky
    ///    phase produced nothing).
    /// Every degraded path returns an honest `reason` — low mask confidence
    /// or a missing sky stack yields NO composite rather than a bad blend.
    public static func compose(baseFrames: [CGImage],
                               underExposed: CGImage?,
                               overExposed: CGImage?,
                               sky: CGImage?) -> Outcome {
        guard let reference = baseFrames.first ?? underExposed ?? overExposed else {
            return Outcome(composite: nil, foreground: nil, skyImage: sky,
                           maskPreview: nil, confidence: .low, horizonMeanRow: nil,
                           reason: "No foreground frames were captured — nothing to composite.")
        }
        // Compose grid: the reference frame's aspect, longest side capped.
        let longest = max(reference.width, reference.height)
        let scale = min(1.0, Double(composeMaxSide) / Double(max(1, longest)))
        let width = max(16, Int((Double(reference.width) * scale).rounded()))
        let height = max(16, Int((Double(reference.height) * scale).rounded()))

        func ingest(_ image: CGImage?) -> Planes? {
            guard let image,
                  let p = CPUStacker.rgbFloats(from: image, width: width, height: height)
            else { return nil }
            return Planes(r: p.r, g: p.g, b: p.b)
        }

        // 1. Robust mean of the identical base frames.
        let basePlanes = baseFrames.compactMap { ingest($0) }
        let robustBase: Planes?
        if basePlanes.isEmpty {
            robustBase = nil
        } else {
            robustBase = Planes(r: robustMean(basePlanes.map(\.r)),
                                g: robustMean(basePlanes.map(\.g)),
                                b: robustMean(basePlanes.map(\.b)))
        }

        // 2. Exposure fusion of [robust base, −2 EV, +1 EV].
        var fusionInput: [Planes] = []
        if let robustBase { fusionInput.append(robustBase) }
        if let under = ingest(underExposed) { fusionInput.append(under) }
        if let over = ingest(overExposed) { fusionInput.append(over) }
        guard let fused = fuseExposures(fusionInput) ?? robustBase else {
            return Outcome(composite: nil, foreground: nil, skyImage: sky,
                           maskPreview: nil, confidence: .low, horizonMeanRow: nil,
                           reason: "No foreground frame could be decoded — nothing to composite.")
        }
        let foregroundImage = CPUStacker.rgbImage(r: fused.r, g: fused.g, b: fused.b,
                                                  width: width, height: height)

        // 3. Horizon mask from the fused foreground.
        guard let horizon = estimateHorizon(luma: luminance(fused),
                                            width: width, height: height) else {
            return Outcome(composite: nil, foreground: foregroundImage, skyImage: sky,
                           maskPreview: nil, confidence: .low, horizonMeanRow: nil,
                           reason: "The foreground frame is too small to find a horizon in.")
        }
        if horizon.confidence == .low {
            return Outcome(composite: nil, foreground: foregroundImage, skyImage: sky,
                           maskPreview: nil, confidence: .low, horizonMeanRow: nil,
                           reason: "No confident horizon line — the bright-city / dark-sky "
                               + "boundary didn't separate cleanly, so the two stacks are "
                               + "kept separate instead of guessing a blend.")
        }
        guard let skyPlanes = ingest(sky) else {
            return Outcome(composite: nil, foreground: foregroundImage, skyImage: sky,
                           maskPreview: nil, confidence: horizon.confidence,
                           horizonMeanRow: horizon.meanRow,
                           reason: "The sky stack produced no image — keeping the fused "
                               + "foreground only.")
        }

        // 4. Feathered composite.
        let blended = featheredComposite(foreground: fused, sky: skyPlanes,
                                         horizon: horizon.perColumn,
                                         width: width, height: height)
        let compositeImage = CPUStacker.rgbImage(r: blended.r, g: blended.g, b: blended.b,
                                                 width: width, height: height)
        let maskImage = maskPreviewImage(horizon: horizon.perColumn,
                                         width: width, height: height)
        let reason: String
        switch horizon.confidence {
        case .high:
            reason = "Composite blended along the measured horizon — mask confidence high."
        case .medium:
            reason = "Composite blended along the measured horizon — mask confidence "
                + "medium; check the boundary before sharing."
        case .low:
            reason = ""   // unreachable: handled above
        }
        return Outcome(composite: compositeImage, foreground: foregroundImage,
                       skyImage: sky, maskPreview: maskImage,
                       confidence: horizon.confidence,
                       horizonMeanRow: horizon.meanRow, reason: reason)
    }
}
