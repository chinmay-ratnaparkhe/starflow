import Foundation
import CoreGraphics
import Accelerate

/// v1 CPU stacking pipeline (see docs/DESIGN.md — Stacking module).
///
/// Pipeline per frame:
///  1. CGImage → grayscale `[Float]` (0…1), rescaled into the `reset` grid.
///  2. Background estimate (sigma-clipped mean + sigma), threshold star detection,
///     3×3 local maxima, 7×7 background-subtracted centroid refinement.
///  3. Translation estimate by brightest-star pairwise-offset voting (median of the
///     winning vote cluster), then nearest-neighbour matching against the reference
///     star list, then a similarity fit (rotation + translation, Procrustes/Kabsch in 2D).
///  4. Reject the frame if matched stars < 5 or RMS residual > 2 px (clouds, wild motion).
///  5. Accumulate a running mean with rotation-aware bilinear sampling; optional
///     kappa-sigma clipping (Welford mean + M2, clip at 3σ) suppresses satellites/planes.
///     The clip decision is made on LUMINANCE and applied to all three colour channels
///     jointly, so a clipped satellite pixel never leaves a colour cast behind.
///  6. Preview: colour CGImage, asinh-stretched per channel with the gain derived from
///     luminance (the f(L)/L trick) so star colour survives the stretch.
///
/// Colour model: detection and registration run on the same grayscale derivative as v1
/// (bit-identical maths); RGB planes are ingested alongside and accumulated per channel.
/// The result is a colour stack — still not a colour-CALIBRATED final image (no matrix,
/// no white-balance fit), but real star colour instead of monochrome luminance.
public final class CPUStacker: Stacking {

    // MARK: - Public support types

    public struct DetectedStar: Sendable {
        public var x: Double
        public var y: Double
        public var flux: Double
        public init(x: Double, y: Double, flux: Double) {
            self.x = x; self.y = y; self.flux = flux
        }
    }

    /// Rigid similarity transform (rotation + translation, unit scale) mapping
    /// reference-frame coordinates into candidate-frame coordinates.
    public struct SimilarityTransform: Sendable {
        public var cosT: Double
        public var sinT: Double
        public var tx: Double
        public var ty: Double
        public static let identity = SimilarityTransform(cosT: 1, sinT: 0, tx: 0, ty: 0)
        @inline(__always)
        public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
            (cosT * x - sinT * y + tx, sinT * x + cosT * y + ty)
        }
        public var rotationDegrees: Double { atan2(sinT, cosT) * 180 / .pi }
    }

    public struct MatchPair: Sendable {
        public var rx: Double
        public var ry: Double
        public var fx: Double
        public var fy: Double
        public init(rx: Double, ry: Double, fx: Double, fy: Double) {
            self.rx = rx; self.ry = ry; self.fx = fx; self.fy = fy
        }
    }

    // MARK: - Tunables (fixed for v1)

    private let detectionSigmaK = 4.5          // star threshold: bg + k·sigma
    private let minStarsPerFrame = 5           // fewer → frame is clouds/noise → reject
    private let minMatches = 5                 // reject frame if matched stars < 5
    private let maxResidualPx = 2.0            // reject frame if RMS residual > 2 px
    private let maxStarsPerFrame = 60
    private let voteStarCount = 12             // brightest stars used in the offset vote
    private let voteTolerancePx = 3.0
    private let coarseMatchTolerancePx = 8.0   // translation-only pass (absorbs ≤1° rotation)
    private let fineMatchTolerancePx = 2.5     // after similarity fit

    /// Kappa for sigma clipping; nil = plain running mean.
    private let kappaSigma: Double?

    /// False = never attempt star registration: every decodable frame joins a plain
    /// unregistered running mean (timelapse). Fixed at init.
    private let registrationEnabled: Bool

    // MARK: - State

    private let lock = NSLock()
    private var width = 0
    private var height = 0
    private var meanBuf: [Float] = []
    private var m2Buf: [Float] = []
    private var countBuf: [Float] = []
    private var meanR: [Float] = []
    private var meanG: [Float] = []
    private var meanB: [Float] = []
    private var referenceStars: [DetectedStar] = []
    private var acceptedCount = 0
    private var rejectedCount = 0
    private var integration: Double = 0

    /// Diagnostics from the most recent `add` (for session telemetry chips).
    public private(set) var lastMatchCount = 0
    public private(set) var lastResidualPx = 0.0

    /// True while frames are being star-aligned against the reference. Goes false when
    /// the stack was seeded by a frame with too few stars (indoor / starless scene →
    /// unregistered accumulate: plain running mean, no alignment) or when this stacker
    /// was built with `registration: false`. Proof-of-life flag for the session UI.
    public private(set) var registrationActive = true

    /// Human-readable reason the most recent `add` returned false; nil after every
    /// accepted frame. CPUStacker-specific diagnostic — deliberately NOT part of the
    /// `Stacking` protocol (SessionEngine reads it via a conditional cast).
    public private(set) var lastRejectionReason: String?

    public init(kappaSigma: Double? = 3.0, registration: Bool = true) {
        self.kappaSigma = kappaSigma
        self.registrationEnabled = registration
        self.registrationActive = registration
    }

    // MARK: - Stacking conformance

    public func reset(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        self.width = max(0, width)
        self.height = max(0, height)
        let count = self.width * self.height
        meanBuf = [Float](repeating: 0, count: count)
        m2Buf = [Float](repeating: 0, count: count)
        countBuf = [Float](repeating: 0, count: count)
        meanR = [Float](repeating: 0, count: count)
        meanG = [Float](repeating: 0, count: count)
        meanB = [Float](repeating: 0, count: count)
        referenceStars = []
        acceptedCount = 0
        rejectedCount = 0
        integration = 0
        lastMatchCount = 0
        lastResidualPx = 0
        registrationActive = registrationEnabled
        lastRejectionReason = nil
    }

    /// Returns false when the frame is rejected (undecodable / misaligned / cloudy);
    /// `lastRejectionReason` says why. Input frames of any resolution are rescaled into
    /// the `reset` grid, so a reduced-resolution live stack of full-size photos is
    /// supported.
    ///
    /// Proof of life: the FIRST decodable frame always seeds the stack, stars or not,
    /// so the preview shows the real scene immediately. A seed with too few stars flips
    /// the stack into unregistered accumulate (plain running mean, no alignment,
    /// `registrationActive == false`) instead of rejecting every subsequent frame.
    public func add(frame: SubFrame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard width > 0, height > 0,
              let image = frame.pixelData,
              let gray = Self.grayscaleFloats(from: image, width: width, height: height),
              let rgb = Self.rgbFloats(from: image, width: width, height: height) else {
            rejectedCount += 1
            lastRejectionReason = "frame could not be decoded"
            return false
        }

        let stars = registrationEnabled
            ? Self.detectStars(in: gray, width: width, height: height,
                               maxStars: maxStarsPerFrame, sigmaK: detectionSigmaK)
            : []

        let transform: SimilarityTransform
        if acceptedCount == 0 {
            // Seed frame: always accepted. Registration stays active only when the
            // reference actually has enough stars to align against.
            referenceStars = stars
            registrationActive = registrationEnabled && stars.count >= minStarsPerFrame
            transform = .identity
            lastMatchCount = stars.count
            lastResidualPx = 0
        } else if !registrationActive {
            // Unregistered accumulate: no alignment, every decodable frame averages in.
            transform = .identity
            lastMatchCount = stars.count
            lastResidualPx = 0
        } else {
            guard stars.count >= minStarsPerFrame else {
                rejectedCount += 1
                lastRejectionReason = "too few stars"
                return false
            }
            guard let reg = Self.register(reference: referenceStars, candidate: stars,
                                          voteStars: voteStarCount,
                                          voteTolerance: voteTolerancePx,
                                          coarseTolerance: coarseMatchTolerancePx,
                                          fineTolerance: fineMatchTolerancePx) else {
                rejectedCount += 1
                lastRejectionReason = "no star alignment found"
                return false
            }
            guard reg.matches >= minMatches else {
                rejectedCount += 1
                lastRejectionReason = "too few matched stars"
                return false
            }
            guard reg.residualPx <= maxResidualPx else {
                rejectedCount += 1
                lastRejectionReason = "alignment residual too high"
                return false
            }
            transform = reg.transform
            lastMatchCount = reg.matches
            lastResidualPx = reg.residualPx
        }

        accumulate(gray, rgb: rgb, transform: transform)
        acceptedCount += 1
        integration += max(0, frame.exposureSeconds)
        lastRejectionReason = nil
        return true
    }

    public func currentResult() -> StackResult {
        lock.lock(); defer { lock.unlock() }
        return StackResult(accepted: acceptedCount,
                           rejected: rejectedCount,
                           integrationSeconds: integration,
                           preview: previewLocked())
    }

    public func finalImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return previewLocked()
    }

    // MARK: - Extra accessors (tests, session telemetry)

    /// Copy of the accumulated linear LUMINANCE mean buffer (row-major, 0…1) —
    /// the plane detection, registration, and kappa clipping run on.
    public func accumulatedMean() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return meanBuf
    }

    /// Copies of the accumulated linear per-channel mean buffers (row-major, 0…1).
    public func accumulatedRGB() -> (r: [Float], g: [Float], b: [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (meanR, meanG, meanB)
    }

    public func dimensions() -> (width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        return (width, height)
    }

    // MARK: - Accumulation

    private func accumulate(_ frame: [Float],
                            rgb: (r: [Float], g: [Float], b: [Float]),
                            transform t: SimilarityTransform) {
        let kappa = kappaSigma
        @inline(__always)
        func bilinear(_ plane: [Float], _ src: Int, _ ax: Float, _ ay: Float) -> Float {
            let v00 = plane[src], v01 = plane[src + 1]
            let v10 = plane[src + width], v11 = plane[src + width + 1]
            let top = v00 + (v01 - v00) * ax
            let bottom = v10 + (v11 - v10) * ax
            return top + (bottom - top) * ay
        }
        for yi in 0..<height {
            let yd = Double(yi)
            let outRow = yi * width
            for xi in 0..<width {
                let (fx, fy) = t.apply(x: Double(xi), y: yd)
                let x0 = Int(fx.rounded(.down))
                let y0 = Int(fy.rounded(.down))
                guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { continue }
                let ax = Float(fx - Double(x0))
                let ay = Float(fy - Double(y0))
                let src = y0 * width + x0
                let value = bilinear(frame, src, ax, ay)

                let idx = outRow + xi
                let n0 = countBuf[idx]
                // Kappa-sigma decision on LUMINANCE, applied to all channels jointly.
                if let kappa, n0 >= 4 {
                    let variance = m2Buf[idx] / (n0 - 1)
                    if variance > 0 {
                        let sigma = Double(variance.squareRoot())
                        if Double(abs(value - meanBuf[idx])) > kappa * sigma { continue }
                    }
                }
                let n1 = n0 + 1
                countBuf[idx] = n1
                let delta = value - meanBuf[idx]
                meanBuf[idx] += delta / n1
                m2Buf[idx] += delta * (value - meanBuf[idx])
                meanR[idx] += (bilinear(rgb.r, src, ax, ay) - meanR[idx]) / n1
                meanG[idx] += (bilinear(rgb.g, src, ax, ay) - meanG[idx]) / n1
                meanB[idx] += (bilinear(rgb.b, src, ax, ay) - meanB[idx]) / n1
            }
        }
    }

    // MARK: - Preview (asinh stretch, colour-preserving)

    /// Colour preview. The asinh stretch is computed on LUMINANCE, and each channel
    /// is multiplied by the same gain f(L)/L (rather than being stretched
    /// independently), so bright stars keep their colour instead of washing to
    /// white — the classic f(L)/L trick. Per-channel background (sigma-clipped
    /// mean) is subtracted first, which also neutralises the sky-glow colour cast.
    private func previewLocked() -> CGImage? {
        guard acceptedCount > 0, width > 0, height > 0 else { return nil }
        var maxV: Float = 0
        vDSP_maxv(meanBuf, 1, &maxV, vDSP_Length(meanBuf.count))
        let stats = Self.clippedStats(meanBuf)
        let black = Float(stats.mean)
        let range = Double(max(1e-6, maxV - black))
        let beta = 0.05
        let norm = 1.0 / asinh(1.0 / beta)
        let zeroGain = norm / beta            // lim u→0 of asinh(u/β)·norm / u
        let blackR = Float(Self.clippedStats(meanR).mean)
        let blackG = Float(Self.clippedStats(meanG).mean)
        let blackB = Float(Self.clippedStats(meanB).mean)
        let count = meanBuf.count
        var outR = [Float](repeating: 0, count: count)
        var outG = [Float](repeating: 0, count: count)
        var outB = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let u = min(1.0, max(0.0, Double(meanBuf[i] - black) / range))
            let gain = u > 1e-6 ? asinh(u / beta) * norm / u : zeroGain
            let g = Float(gain / range)
            outR[i] = min(1, max(0, (meanR[i] - blackR) * g))
            outG[i] = min(1, max(0, (meanG[i] - blackG) * g))
            outB[i] = min(1, max(0, (meanB[i] - blackB) * g))
        }
        return Self.rgbImage(r: outR, g: outG, b: outB, width: width, height: height)
    }

    // MARK: - Image I/O helpers (public: reused by the simulator capture path & tests)

    /// Draw any CGImage into a `width`×`height` 8-bit gray grid and return floats 0…1.
    public static func grayscaleFloats(from image: CGImage, width: Int, height: Int) -> [Float]? {
        guard width > 0, height > 0 else { return nil }
        let count = width * height
        var bytes = [UInt8](repeating: 0, count: count)
        let drew: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var floats = [Float](repeating: 0, count: count)
        vDSP_vfltu8(bytes, 1, &floats, 1, vDSP_Length(count))
        var scale: Float = 1.0 / 255.0
        var scaled = [Float](repeating: 0, count: count)
        vDSP_vsmul(floats, 1, &scale, &scaled, 1, vDSP_Length(count))
        return scaled
    }

    /// 8-bit grayscale CGImage from row-major floats clamped to 0…1.
    public static func grayImage(from values: [Float], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let out = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let src = y * width
            let dst = y * rowBytes
            for x in 0..<width {
                let v = values[src + x]
                out[dst + x] = UInt8(min(255, max(0, v * 255 + 0.5)))
            }
        }
        return ctx.makeImage()
    }

    /// Draw any CGImage into a `width`×`height` 8-bit RGBA grid and return three
    /// float planes (r, g, b) 0…1. Grayscale sources come back with r == g == b.
    public static func rgbFloats(from image: CGImage, width: Int, height: Int)
        -> (r: [Float], g: [Float], b: [Float])? {
        guard width > 0, height > 0 else { return nil }
        let count = width * height
        var bytes = [UInt8](repeating: 0, count: count * 4)
        let drew: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var r = [Float](repeating: 0, count: count)
        var g = [Float](repeating: 0, count: count)
        var b = [Float](repeating: 0, count: count)
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vfltu8(base, 4, &r, 1, vDSP_Length(count))
            vDSP_vfltu8(base + 1, 4, &g, 1, vDSP_Length(count))
            vDSP_vfltu8(base + 2, 4, &b, 1, vDSP_Length(count))
        }
        var scale: Float = 1.0 / 255.0
        func scaleInPlace(_ plane: inout [Float]) {
            plane.withUnsafeMutableBufferPointer { p in
                guard let base = p.baseAddress else { return }
                vDSP_vsmul(base, 1, &scale, base, 1, vDSP_Length(count))
            }
        }
        scaleInPlace(&r)
        scaleInPlace(&g)
        scaleInPlace(&b)
        return (r, g, b)
    }

    /// 8-bit RGB CGImage from three row-major float planes clamped to 0…1.
    public static func rgbImage(r: [Float], g: [Float], b: [Float],
                                width: Int, height: Int) -> CGImage? {
        let count = width * height
        guard width > 0, height > 0,
              r.count == count, g.count == count, b.count == count,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let out = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let src = y * width
            let dst = y * rowBytes
            for x in 0..<width {
                let i = src + x
                let o = dst + x * 4
                out[o]     = UInt8(min(255, max(0, r[i] * 255 + 0.5)))
                out[o + 1] = UInt8(min(255, max(0, g[i] * 255 + 0.5)))
                out[o + 2] = UInt8(min(255, max(0, b[i] * 255 + 0.5)))
                out[o + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    // MARK: - Statistics & detection

    /// Mean + sigma with one 3σ clip round so stars do not inflate the background estimate.
    public static func clippedStats(_ values: [Float]) -> (mean: Double, sigma: Double) {
        let n = vDSP_Length(values.count)
        guard n > 0 else { return (0, 1e-6) }
        var mean: Float = 0
        vDSP_meanv(values, 1, &mean, n)
        var meanSq: Float = 0
        vDSP_measqv(values, 1, &meanSq, n)
        var m = Double(mean)
        var sigma = Double(max(0, meanSq - mean * mean)).squareRoot()
        let hi = m + 3 * sigma
        var s = 0.0, s2 = 0.0
        var cnt = 0
        for v in values {
            let d = Double(v)
            if d <= hi { s += d; s2 += d * d; cnt += 1 }
        }
        if cnt > 64 {
            m = s / Double(cnt)
            sigma = max(0, s2 / Double(cnt) - m * m).squareRoot()
        }
        return (m, max(sigma, 1e-6))
    }

    /// Threshold detection with 3×3 local maxima and 7×7 centroid refinement.
    /// Returns stars sorted brightest-first, deduplicated within 3 px.
    public static func detectStars(in buffer: [Float], width: Int, height: Int,
                                   maxStars: Int = 60, sigmaK: Double = 4.5) -> [DetectedStar] {
        guard buffer.count == width * height, width > 8, height > 8 else { return [] }
        let stats = clippedStats(buffer)
        let threshold = Float(stats.mean + sigmaK * stats.sigma)
        let background = Float(stats.mean)
        var found: [DetectedStar] = []
        let r = 3
        for y in r..<(height - r) {
            let row = y * width
            for x in r..<(width - r) {
                let v = buffer[row + x]
                guard v > threshold else { continue }
                var isMax = true
                neighbors: for dy in -1...1 {
                    let nrow = (y + dy) * width
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        if buffer[nrow + x + dx] > v { isMax = false; break neighbors }
                    }
                }
                guard isMax else { continue }
                var sw = 0.0, sx = 0.0, sy = 0.0
                for dy in -r...r {
                    let nrow = (y + dy) * width
                    for dx in -r...r {
                        let w = Double(max(0, buffer[nrow + x + dx] - background))
                        sw += w
                        sx += w * Double(x + dx)
                        sy += w * Double(y + dy)
                    }
                }
                guard sw > 0 else { continue }
                found.append(DetectedStar(x: sx / sw, y: sy / sw, flux: sw))
            }
        }
        found.sort { $0.flux > $1.flux }
        var kept: [DetectedStar] = []
        for star in found {
            if kept.count >= maxStars { break }
            let tooClose = kept.contains {
                let dx = $0.x - star.x, dy = $0.y - star.y
                return dx * dx + dy * dy < 9
            }
            if !tooClose { kept.append(star) }
        }
        return kept
    }

    // MARK: - Registration

    /// Translation estimate: pairwise offsets between the brightest stars of both lists,
    /// vote for the offset with the most support, return the median of the winning cluster.
    public static func estimateTranslation(reference: [DetectedStar], candidate: [DetectedStar],
                                           take: Int, tolerance: Double) -> (dx: Double, dy: Double)? {
        let a = Array(reference.prefix(take))
        let b = Array(candidate.prefix(take))
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var offsets: [(dx: Double, dy: Double)] = []
        offsets.reserveCapacity(a.count * b.count)
        for r in a {
            for c in b {
                offsets.append((c.x - r.x, c.y - r.y))
            }
        }
        var bestIndex = -1
        var bestSupport = 0
        for i in 0..<offsets.count {
            let o = offsets[i]
            var support = 0
            for p in offsets where abs(p.dx - o.dx) <= tolerance && abs(p.dy - o.dy) <= tolerance {
                support += 1
            }
            if support > bestSupport {
                bestSupport = support
                bestIndex = i
            }
        }
        guard bestIndex >= 0, bestSupport >= 3 else { return nil }
        let winner = offsets[bestIndex]
        var dxs: [Double] = []
        var dys: [Double] = []
        for p in offsets where abs(p.dx - winner.dx) <= tolerance && abs(p.dy - winner.dy) <= tolerance {
            dxs.append(p.dx)
            dys.append(p.dy)
        }
        return (median(dxs), median(dys))
    }

    /// Nearest-neighbour matching of reference stars to candidate stars under `transform`.
    public static func matchPairs(reference: [DetectedStar], candidate: [DetectedStar],
                                  transform: SimilarityTransform, tolerance: Double) -> [MatchPair] {
        var pairs: [MatchPair] = []
        let tol2 = tolerance * tolerance
        for r in reference {
            let p = transform.apply(x: r.x, y: r.y)
            var bestDist = tol2
            var best: DetectedStar?
            for c in candidate {
                let dx = c.x - p.x, dy = c.y - p.y
                let d = dx * dx + dy * dy
                if d < bestDist { bestDist = d; best = c }
            }
            if let best {
                pairs.append(MatchPair(rx: r.x, ry: r.y, fx: best.x, fy: best.y))
            }
        }
        return pairs
    }

    /// Least-squares rotation + translation (2D Kabsch / Procrustes) on matched pairs.
    public static func fitSimilarity(_ pairs: [MatchPair]) -> SimilarityTransform {
        let n = Double(pairs.count)
        guard n > 0 else { return .identity }
        var crx = 0.0, cry = 0.0, cfx = 0.0, cfy = 0.0
        for p in pairs { crx += p.rx; cry += p.ry; cfx += p.fx; cfy += p.fy }
        crx /= n; cry /= n; cfx /= n; cfy /= n
        var sxx = 0.0, sxy = 0.0
        for p in pairs {
            let ax = p.rx - crx, ay = p.ry - cry
            let bx = p.fx - cfx, by = p.fy - cfy
            sxx += ax * bx + ay * by
            sxy += ax * by - ay * bx
        }
        let theta = (sxx == 0 && sxy == 0) ? 0 : atan2(sxy, sxx)
        let c = cos(theta), s = sin(theta)
        return SimilarityTransform(cosT: c, sinT: s,
                                   tx: cfx - (c * crx - s * cry),
                                   ty: cfy - (s * crx + c * cry))
    }

    public static func rmsResidual(_ pairs: [MatchPair], _ t: SimilarityTransform) -> Double {
        guard !pairs.isEmpty else { return .infinity }
        var sum = 0.0
        for p in pairs {
            let (px, py) = t.apply(x: p.rx, y: p.ry)
            let dx = p.fx - px, dy = p.fy - py
            sum += dx * dx + dy * dy
        }
        return (sum / Double(pairs.count)).squareRoot()
    }

    /// Full registration: vote translation → coarse match → similarity fit → fine re-match → refit.
    public static func register(reference: [DetectedStar], candidate: [DetectedStar],
                                voteStars: Int, voteTolerance: Double,
                                coarseTolerance: Double, fineTolerance: Double)
        -> (transform: SimilarityTransform, matches: Int, residualPx: Double)? {
        guard let t0 = estimateTranslation(reference: reference, candidate: candidate,
                                           take: voteStars, tolerance: voteTolerance) else { return nil }
        let coarse = SimilarityTransform(cosT: 1, sinT: 0, tx: t0.dx, ty: t0.dy)
        let roughPairs = matchPairs(reference: reference, candidate: candidate,
                                    transform: coarse, tolerance: coarseTolerance)
        guard roughPairs.count >= 3 else { return nil }
        var transform = fitSimilarity(roughPairs)
        let finePairs = matchPairs(reference: reference, candidate: candidate,
                                   transform: transform, tolerance: fineTolerance)
        guard finePairs.count >= 3 else { return nil }
        transform = fitSimilarity(finePairs)
        return (transform, finePairs.count, rmsResidual(finePairs, transform))
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : 0.5 * (sorted[mid - 1] + sorted[mid])
    }
}
