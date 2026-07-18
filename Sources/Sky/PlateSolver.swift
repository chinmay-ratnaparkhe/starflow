import Foundation
import CoreGraphics
import simd

// MARK: - PlateSolver (Plate-solve core, docs/ROADMAP-v3.md #4)
//
// Answers "where is the camera pointing?" from star centroids alone — a
// lost-in-space solve. No network, no sensors, no dependencies; pure math,
// deterministic, safe to call from any thread.
//
// Method (validated against synthesized fields before this port):
//  1. Embedded mini-catalog: the brightest stars to V ≤ 3.5 (J2000, Yale Bright
//     Star Catalog positions, 282 entries after merging tight doubles < 0.1°
//     and dropping cataclysmic/long-period variables listed at maxima,
//     sorted brightest-first).
//  2. Triangle-invariant hash table, built once at init: every catalog star
//     forms triangles with pairs of its 10 nearest neighbours (sides ≤ ~30°).
//     Each triangle is projected onto the tangent plane at its own centroid and
//     reduced to the similarity-invariant side ratios (b/a, c/a) with sides
//     ordered a ≥ b ≥ c; the ratios index a hash table.
//  3. `solve` builds the same k-NN triangles over the brightest image centroids,
//     looks each up in the table, and screens candidates by the plate scale they
//     imply against the caller's FOV estimate (±60%). Every surviving hit is a
//     3-star correspondence hypothesis, verified RANSAC-style: fit a
//     4-parameter similarity (rotation + scale + translation, no reflection)
//     from the triangle's tangent-plane coordinates to its pixel coordinates,
//     predict every catalog star that would fall in the frame, and count
//     centroid inliers. The best hypothesis is polished with two rounds of
//     re-centred tangent-plane least squares over all inliers.
//
// Camera model — the documented contract, shared with PlateSolverTests:
//
//     pixel = imageCenter + s · R(roll) · (−ξ, −η)
//
// where (ξ east, η north) are gnomonic tangent-plane coordinates in degrees,
// s is the plate scale in px/deg, pixel y grows DOWN, and R is the standard
// rotation matrix [[cos, −sin], [sin, cos]]. At roll 0 the sky's north points
// up in the image and east points LEFT — a direct (non-mirrored) sky view.
// This makes the sky→pixel map a pure similarity (determinant > 0), so the
// least-squares fit x = A·ξ − B·η + tx, y = B·ξ + A·η + ty is exact for it and
// roll recovers as atan2(−B, −A).
//
// Consumers: `GoToController` (feature 5) closes the aiming loop with this —
// SessionEngine solves live frames to refine aim, re-acquire after flap
// recovery, and cross-check drift — and the AutoTest `solve_preview` debug
// action solves the latest stack preview on demand.

/// One embedded catalog star, J2000.
public struct BrightStar: Sendable {
    public let name: String
    public let raDeg: Double
    public let decDeg: Double
    public let mag: Double
    init(_ name: String, _ raDeg: Double, _ decDeg: Double, _ mag: Double) {
        self.name = name; self.raDeg = raDeg; self.decDeg = decDeg; self.mag = mag
    }
}

public final class PlateSolver: Sendable {

    // MARK: - Solution

    public struct Solution: Sendable {
        /// J2000 sky position of the image center.
        public var centerRADeg: Double
        public var centerDecDeg: Double
        /// Camera roll (deg, 0..<360): rotation of the sky's north away from
        /// image-up, in the camera-model convention documented above.
        public var rollDeg: Double
        /// Plate scale in pixels per degree.
        public var plateScalePxPerDeg: Double
        /// Catalog stars matched to centroids in the final fit.
        public var matchedCount: Int
        /// RMS distance (px) between predicted and measured star positions.
        public var residualPx: Double

        /// Convenience: the center in the app's RA-hours convention.
        public var center: EquatorialCoord {
            EquatorialCoord(raHours: centerRADeg / 15.0, decDeg: centerDecDeg)
        }
        public var plateScaleArcsecPerPx: Double { 3600.0 / plateScalePxPerDeg }
    }

    // MARK: - Tunables (fixed; values validated on synthesized fields)

    private static let maxTriangleSideDeg = 30.0   // catalog triangle side cap
    private static let catalogNeighbors = 10       // k-NN per catalog star
    private static let imageNeighbors = 6          // k-NN per image centroid
    private static let maxSolveCentroids = 18      // brightest centroids used for triangles
    private static let ratioBinWidth = 0.01        // hash bin width in ratio space
    private static let ratioTolerance = 0.02       // invariant match tolerance
    private static let minFlatness = 0.10          // reject sliver triangles (shortest/longest side, c/a, below this — two nearly coincident vertices). NOTE: does NOT reject flat/collinear triangles (b+c ≈ a); those pass and rely on full-field verification.
    private static let scaleWindow = 1.6           // implied-scale screen vs FOV estimate
    private static let minMatches = 6              // fewer inliers → no solve (anti-false-positive)
    private static let earlyExitMatches = 8        // stop hypothesis search at this support
    private static let hypothesisResidualFrac = 0.02 // 3-point fit residual cap: 2% of FOV

    // MARK: - Triangle table (immutable after init)

    private struct TriangleEntry {
        let i0: Int, i1: Int, i2: Int      // catalog indices, canonical order (A, B, C)
        let ratioB: Double, ratioC: Double // b/a, c/a
        let sideADeg: Double               // longest side, tangent-plane degrees
    }

    private let entries: [TriangleEntry]
    private let bins: [Int: [Int]]         // quantized (b/a, c/a) → entry indices
    private let catalogUnits: [SIMD3<Double>]

    /// Table construction is a few milliseconds; share one instance app-wide.
    public static let shared = PlateSolver()

    public init() {
        let cat = Self.catalog
        let units = cat.map { Self.unitVector(raDeg: $0.raDeg, decDeg: $0.decDeg) }
        catalogUnits = units

        // Unique k-NN triangles.
        let cosMax = cos(Self.maxTriangleSideDeg * .pi / 180.0)
        var triangleKeys = Set<Int>()
        var triples: [(Int, Int, Int)] = []
        let n = cat.count
        for i in 0..<n {
            var neighbors: [(cosDist: Double, index: Int)] = []
            for j in 0..<n where j != i {
                let d = simd_dot(units[i], units[j])
                if d > cosMax { neighbors.append((d, j)) }
            }
            neighbors.sort { $0.cosDist > $1.cosDist }   // nearest first
            let near = neighbors.prefix(Self.catalogNeighbors).map { $0.index }
            for a in 0..<near.count {
                for b in (a + 1)..<near.count {
                    let tri = [i, near[a], near[b]].sorted()
                    let key = (tri[0] * n + tri[1]) * n + tri[2]
                    if triangleKeys.insert(key).inserted {
                        triples.append((tri[0], tri[1], tri[2]))
                    }
                }
            }
        }

        // Project each triangle onto the tangent plane at its centroid, take the
        // canonical side-ratio invariants, and hash.
        var built: [TriangleEntry] = []
        built.reserveCapacity(triples.count)
        var table: [Int: [Int]] = [:]
        for (i, j, k) in triples {
            let centroid = simd_normalize(units[i] + units[j] + units[k])
            let ra0 = Self.wrap360(atan2(centroid.y, centroid.x) * 180.0 / .pi)
            let dec0 = asin(max(-1, min(1, centroid.z))) * 180.0 / .pi
            var coords: [Int: (x: Double, y: Double)] = [:]
            var projected = true
            for t in [i, j, k] {
                guard let p = Self.tangentProject(raDeg: cat[t].raDeg, decDeg: cat[t].decDeg,
                                                  centerRADeg: ra0, centerDecDeg: dec0) else {
                    projected = false; break
                }
                coords[t] = p
            }
            guard projected,
                  let canon = Self.canonicalTriangle(i, j, k, coords: { coords[$0]! }),
                  canon.sideA <= Self.maxTriangleSideDeg * 1.2 else { continue }
            let index = built.count
            built.append(TriangleEntry(i0: canon.ids.0, i1: canon.ids.1, i2: canon.ids.2,
                                       ratioB: canon.ratioB, ratioC: canon.ratioC,
                                       sideADeg: canon.sideA))
            table[Self.binKey(canon.ratioB, canon.ratioC), default: []].append(index)
        }
        entries = built
        bins = table
    }

    // MARK: - Solve

    /// Solve a field from star centroids (pixel coordinates, y down,
    /// brightest-first — `CPUStacker.detectStars` order). `fovEstimateDeg` is the
    /// rough horizontal field of view; ±60% slack is tolerated. Returns nil when
    /// no hypothesis gathers ≥ 6 verified catalog matches — a random scatter or a
    /// star-poor field yields nil rather than a wrong answer.
    public func solve(centroids: [CGPoint], imageSize: CGSize,
                      fovEstimateDeg: Double) -> Solution? {
        let w = Double(imageSize.width), h = Double(imageSize.height)
        guard centroids.count >= Self.minMatches, w > 8, h > 8,
              fovEstimateDeg > 0.5, fovEstimateDeg < 160 else { return nil }
        let all = centroids.map { (x: Double($0.x), y: Double($0.y)) }
        let pts = Array(all.prefix(Self.maxSolveCentroids))

        // Image k-NN triangles over the brightest centroids, biggest first.
        var triangleKeys = Set<Int>()
        var imageTriangles: [(ids: (Int, Int, Int), ratioB: Double, ratioC: Double, sideA: Double)] = []
        let m = pts.count
        for i in 0..<m {
            var neighbors: [(dist: Double, index: Int)] = []
            for j in 0..<m where j != i {
                let dx = pts[i].x - pts[j].x, dy = pts[i].y - pts[j].y
                neighbors.append(((dx * dx + dy * dy).squareRoot(), j))
            }
            neighbors.sort { $0.dist < $1.dist }
            let near = neighbors.prefix(Self.imageNeighbors).map { $0.index }
            for a in 0..<near.count {
                for b in (a + 1)..<near.count {
                    let tri = [i, near[a], near[b]].sorted()
                    let key = (tri[0] * m + tri[1]) * m + tri[2]
                    guard triangleKeys.insert(key).inserted else { continue }
                    if let canon = Self.canonicalTriangle(tri[0], tri[1], tri[2],
                                                          coords: { pts[$0] }) {
                        imageTriangles.append(canon)
                    }
                }
            }
        }
        imageTriangles.sort { $0.sideA > $1.sideA }

        let expectedScale = w / fovEstimateDeg     // px per degree, rough
        var best: Hypothesis?
        for triangle in imageTriangles {
            for entryIndex in lookup(ratioB: triangle.ratioB, ratioC: triangle.ratioC) {
                let entry = entries[entryIndex]
                let impliedScale = triangle.sideA / entry.sideADeg
                guard impliedScale >= expectedScale / Self.scaleWindow,
                      impliedScale <= expectedScale * Self.scaleWindow else { continue }
                guard let hypothesis = verify(imageIDs: triangle.ids, entry: entry,
                                              points: pts, centroids: all,
                                              width: w, height: h,
                                              fovEstimateDeg: fovEstimateDeg) else { continue }
                if best == nil || hypothesis.pairs.count > best!.pairs.count {
                    best = hypothesis
                }
                if let b = best, b.pairs.count >= Self.earlyExitMatches {
                    if let solution = polish(b, centroids: all, width: w, height: h) {
                        return solution
                    }
                    best = nil     // polish degenerated (pathological) — keep searching
                }
            }
        }
        guard let b = best else { return nil }
        return polish(b, centroids: all, width: w, height: h)
    }

    // MARK: - Hypothesis verification (RANSAC-style)

    private struct Hypothesis {
        var transform: Similarity
        var tangentRADeg: Double
        var tangentDecDeg: Double
        var pairs: [(catalog: Int, centroid: Int)]
    }

    /// Fit the 3-star correspondence and gate on its own residual. The gate
    /// screens grossly wrong chirality / vertex assignments; near-isoceles and
    /// near-collinear triangles can mirror-fit under the gate, so full-field
    /// growth (`grow`, ≥ minMatches verified stars) is the real arbiter.
    private func verify(imageIDs: (Int, Int, Int), entry: TriangleEntry,
                        points: [(x: Double, y: Double)],
                        centroids: [(x: Double, y: Double)],
                        width: Double, height: Double,
                        fovEstimateDeg: Double) -> Hypothesis? {
        let cat = Self.catalog
        let centroid = simd_normalize(catalogUnits[entry.i0] + catalogUnits[entry.i1]
                                      + catalogUnits[entry.i2])
        let ra0 = Self.wrap360(atan2(centroid.y, centroid.x) * 180.0 / .pi)
        let dec0 = asin(max(-1, min(1, centroid.z))) * 180.0 / .pi

        var fitPairs: [(u: Double, v: Double, x: Double, y: Double)] = []
        for (imageID, catalogID) in [(imageIDs.0, entry.i0), (imageIDs.1, entry.i1),
                                     (imageIDs.2, entry.i2)] {
            guard let p = Self.tangentProject(raDeg: cat[catalogID].raDeg,
                                              decDeg: cat[catalogID].decDeg,
                                              centerRADeg: ra0, centerDecDeg: dec0)
            else { return nil }
            fitPairs.append((p.x, p.y, points[imageID].x, points[imageID].y))
        }
        guard let transform = Self.fitSimilarity(fitPairs), transform.scale > 1e-9
        else { return nil }

        var sum = 0.0
        for p in fitPairs {
            let (px, py) = transform.apply(p.u, p.v)
            sum += (px - p.x) * (px - p.x) + (py - p.y) * (py - p.y)
        }
        let residual3 = (sum / 3.0).squareRoot()
        guard residual3 <= Self.hypothesisResidualFrac * transform.scale * fovEstimateDeg
        else { return nil }

        return grow(transform: transform, tangentRADeg: ra0, tangentDecDeg: dec0,
                    centroids: centroids, width: width, height: height)
    }

    /// Predict every catalog star that would land in the frame under the
    /// hypothesis; greedily match each to the nearest unused centroid. Nil below
    /// `minMatches` inliers.
    private func grow(transform: Similarity, tangentRADeg: Double, tangentDecDeg: Double,
                      centroids: [(x: Double, y: Double)],
                      width: Double, height: Double) -> Hypothesis? {
        let cat = Self.catalog
        let scale = transform.scale
        let tolerancePx = max(3.0, 0.006 * max(width, height))
        let (cxi, ceta) = transform.invert(width / 2, height / 2)
        let (centerRA, centerDec) = Self.tangentDeproject(xiDeg: cxi, etaDeg: ceta,
                                                          centerRADeg: tangentRADeg,
                                                          centerDecDeg: tangentDecDeg)
        let halfDiagonalDeg = min(89.0, (width * width + height * height).squareRoot()
                                        / 2.0 / scale * 1.1)
        let cosLimit = cos(halfDiagonalDeg * .pi / 180.0)
        let centerUnit = Self.unitVector(raDeg: centerRA, decDeg: centerDec)

        var pairs: [(catalog: Int, centroid: Int)] = []
        var used = Set<Int>()
        for (catalogID, star) in cat.enumerated() {
            guard simd_dot(centerUnit, catalogUnits[catalogID]) >= cosLimit,
                  let p = Self.tangentProject(raDeg: star.raDeg, decDeg: star.decDeg,
                                              centerRADeg: tangentRADeg,
                                              centerDecDeg: tangentDecDeg)
            else { continue }
            let (px, py) = transform.apply(p.x, p.y)
            guard px >= -tolerancePx, px <= width + tolerancePx,
                  py >= -tolerancePx, py <= height + tolerancePx else { continue }
            var bestDistance = tolerancePx
            var bestCentroid: Int?
            for (j, c) in centroids.enumerated() where !used.contains(j) {
                let d = ((px - c.x) * (px - c.x) + (py - c.y) * (py - c.y)).squareRoot()
                if d < bestDistance { bestDistance = d; bestCentroid = j }
            }
            if let j = bestCentroid {
                used.insert(j)
                pairs.append((catalogID, j))
            }
        }
        guard pairs.count >= Self.minMatches else { return nil }
        return Hypothesis(transform: transform, tangentRADeg: tangentRADeg,
                          tangentDecDeg: tangentDecDeg, pairs: pairs)
    }

    // MARK: - Final least-squares polish

    /// Two rounds: re-center the tangent plane on the current image-center
    /// estimate, least-squares refit over all inliers, re-grow the inlier set.
    /// Then read off center, roll, scale, and RMS residual.
    private func polish(_ hypothesis: Hypothesis,
                        centroids: [(x: Double, y: Double)],
                        width: Double, height: Double) -> Solution? {
        let cat = Self.catalog
        var ra0 = hypothesis.tangentRADeg
        var dec0 = hypothesis.tangentDecDeg
        var transform = hypothesis.transform
        var pairs = hypothesis.pairs

        for _ in 0..<2 {
            let (cxi, ceta) = transform.invert(width / 2, height / 2)
            (ra0, dec0) = Self.tangentDeproject(xiDeg: cxi, etaDeg: ceta,
                                                centerRADeg: ra0, centerDecDeg: dec0)
            var fitPairs: [(u: Double, v: Double, x: Double, y: Double)] = []
            for (catalogID, centroidID) in pairs {
                guard let p = Self.tangentProject(raDeg: cat[catalogID].raDeg,
                                                  decDeg: cat[catalogID].decDeg,
                                                  centerRADeg: ra0, centerDecDeg: dec0)
                else { continue }
                let c = centroids[centroidID]
                fitPairs.append((p.x, p.y, c.x, c.y))
            }
            guard fitPairs.count >= 3,
                  let refit = Self.fitSimilarity(fitPairs), refit.scale > 1e-9
            else { return nil }
            transform = refit
            guard let regrown = grow(transform: transform, tangentRADeg: ra0,
                                     tangentDecDeg: dec0, centroids: centroids,
                                     width: width, height: height) else { return nil }
            pairs = regrown.pairs
        }

        let (cxi, ceta) = transform.invert(width / 2, height / 2)
        let (centerRA, centerDec) = Self.tangentDeproject(xiDeg: cxi, etaDeg: ceta,
                                                          centerRADeg: ra0,
                                                          centerDecDeg: dec0)
        var sum = 0.0
        for (catalogID, centroidID) in pairs {
            guard let p = Self.tangentProject(raDeg: cat[catalogID].raDeg,
                                              decDeg: cat[catalogID].decDeg,
                                              centerRADeg: ra0, centerDecDeg: dec0)
            else { continue }
            let (px, py) = transform.apply(p.x, p.y)
            let c = centroids[centroidID]
            sum += (px - c.x) * (px - c.x) + (py - c.y) * (py - c.y)
        }
        let residual = (sum / Double(pairs.count)).squareRoot()
        // Camera model: A = −s·cos(roll), B = −s·sin(roll) → roll = atan2(−B, −A).
        let roll = Self.wrap360(atan2(-transform.b, -transform.a) * 180.0 / .pi)
        return Solution(centerRADeg: centerRA, centerDecDeg: centerDec, rollDeg: roll,
                        plateScalePxPerDeg: transform.scale, matchedCount: pairs.count,
                        residualPx: residual)
    }

    // MARK: - Triangle invariants

    /// Vertices reordered so A is opposite the longest side a, B opposite b,
    /// C opposite c (a ≥ b ≥ c); invariants are (b/a, c/a). Nil for degenerate or
    /// near-collinear triangles.
    private static func canonicalTriangle(_ p0: Int, _ p1: Int, _ p2: Int,
                                          coords: (Int) -> (x: Double, y: Double))
        -> (ids: (Int, Int, Int), ratioB: Double, ratioC: Double, sideA: Double)? {
        let ids = [p0, p1, p2]
        func distance(_ i: Int, _ j: Int) -> Double {
            let a = coords(i), b = coords(j)
            return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        let sides = [distance(ids[1], ids[2]), distance(ids[0], ids[2]), distance(ids[0], ids[1])]
        let order = [0, 1, 2].sorted { sides[$0] > sides[$1] }
        let a = sides[order[0]], b = sides[order[1]], c = sides[order[2]]
        guard a > 0, c / a >= minFlatness else { return nil }
        return ((ids[order[0]], ids[order[1]], ids[order[2]]), b / a, c / a, a)
    }

    private static func binKey(_ ratioB: Double, _ ratioC: Double) -> Int {
        Int(ratioB / ratioBinWidth) * 1024 + Int(ratioC / ratioBinWidth)
    }

    private func lookup(ratioB: Double, ratioC: Double) -> [Int] {
        let b0 = Int(ratioB / Self.ratioBinWidth)
        let c0 = Int(ratioC / Self.ratioBinWidth)
        let reach = Int(Self.ratioTolerance / Self.ratioBinWidth) + 1
        var out: [Int] = []
        for db in -reach...reach {
            for dc in -reach...reach {
                guard let candidates = bins[(b0 + db) * 1024 + (c0 + dc)] else { continue }
                for index in candidates {
                    let e = entries[index]
                    if abs(e.ratioB - ratioB) <= Self.ratioTolerance,
                       abs(e.ratioC - ratioC) <= Self.ratioTolerance {
                        out.append(index)
                    }
                }
            }
        }
        return out
    }

    // MARK: - Similarity transform (4-parameter, no reflection)

    /// x = A·u − B·v + tx, y = B·u + A·v + ty.
    private struct Similarity {
        var a: Double, b: Double, tx: Double, ty: Double
        var scale: Double { (a * a + b * b).squareRoot() }
        func apply(_ u: Double, _ v: Double) -> (Double, Double) {
            (a * u - b * v + tx, b * u + a * v + ty)
        }
        func invert(_ x: Double, _ y: Double) -> (Double, Double) {
            let det = a * a + b * b
            let dx = x - tx, dy = y - ty
            return ((a * dx + b * dy) / det, (a * dy - b * dx) / det)
        }
    }

    /// Closed-form least squares for the 4-parameter similarity.
    private static func fitSimilarity(_ pairs: [(u: Double, v: Double, x: Double, y: Double)])
        -> Similarity? {
        let n = Double(pairs.count)
        guard n >= 2 else { return nil }
        var mu = 0.0, mv = 0.0, mx = 0.0, my = 0.0
        for p in pairs { mu += p.u; mv += p.v; mx += p.x; my += p.y }
        mu /= n; mv /= n; mx /= n; my /= n
        var numA = 0.0, numB = 0.0, den = 0.0
        for p in pairs {
            let du = p.u - mu, dv = p.v - mv
            let dx = p.x - mx, dy = p.y - my
            numA += du * dx + dv * dy
            numB += du * dy - dv * dx
            den += du * du + dv * dv
        }
        guard den > 0 else { return nil }
        let a = numA / den, b = numB / den
        return Similarity(a: a, b: b, tx: mx - a * mu + b * mv, ty: my - b * mu - a * mv)
    }

    // MARK: - Spherical / tangent-plane geometry (public: shared with tests)

    static func unitVector(raDeg: Double, decDeg: Double) -> SIMD3<Double> {
        let ra = raDeg * .pi / 180.0, dec = decDeg * .pi / 180.0
        return SIMD3(cos(dec) * cos(ra), cos(dec) * sin(ra),
                     sin(dec))
    }

    /// Angular separation in degrees between two sky positions.
    public static func angularSeparationDeg(ra1Deg: Double, dec1Deg: Double,
                                            ra2Deg: Double, dec2Deg: Double) -> Double {
        let d = simd_dot(unitVector(raDeg: ra1Deg, decDeg: dec1Deg),
                         unitVector(raDeg: ra2Deg, decDeg: dec2Deg))
        return acos(max(-1, min(1, d))) * 180.0 / .pi
    }

    /// Gnomonic projection: sky → (ξ east, η north) in degrees on the tangent
    /// plane at (centerRA, centerDec). Nil when the point is on or behind the
    /// tangent-plane horizon.
    public static func tangentProject(raDeg: Double, decDeg: Double,
                                      centerRADeg: Double, centerDecDeg: Double)
        -> (x: Double, y: Double)? {
        let dra = (raDeg - centerRADeg) * .pi / 180.0
        let dec = decDeg * .pi / 180.0, dec0 = centerDecDeg * .pi / 180.0
        let denominator = sin(dec) * sin(dec0)
                        + cos(dec) * cos(dec0) * cos(dra)
        guard denominator > 0.05 else { return nil }
        let xi = cos(dec) * sin(dra) / denominator
        let eta = (sin(dec) * cos(dec0)
                 - cos(dec) * sin(dec0) * cos(dra)) / denominator
        return (xi * 180.0 / .pi, eta * 180.0 / .pi)
    }

    /// Inverse gnomonic: tangent-plane (ξ, η) in degrees → (RA, Dec) degrees,
    /// RA wrapped to 0..<360.
    public static func tangentDeproject(xiDeg: Double, etaDeg: Double,
                                        centerRADeg: Double, centerDecDeg: Double)
        -> (raDeg: Double, decDeg: Double) {
        let x = xiDeg * .pi / 180.0, y = etaDeg * .pi / 180.0
        let dec0 = centerDecDeg * .pi / 180.0
        let rho = (x * x + y * y).squareRoot()
        guard rho > 1e-12 else { return (wrap360(centerRADeg), centerDecDeg) }
        let c = atan(rho)
        let sinC = sin(c), cosC = cos(c)
        let dec = asin(max(-1, min(1, cosC * sin(dec0)
                                             + y * sinC * cos(dec0) / rho)))
        let ra = centerRADeg * .pi / 180.0
               + atan2(x * sinC,
                              rho * cos(dec0) * cosC - y * sin(dec0) * sinC)
        return (wrap360(ra * 180.0 / .pi), dec * 180.0 / .pi)
    }

    /// The documented camera model: tangent-plane (ξ, η) → pixel. Used by tests
    /// to synthesize fields; `solve` recovers exactly these parameters.
    public static func pixel(xiDeg: Double, etaDeg: Double, imageSize: CGSize,
                             plateScalePxPerDeg: Double, rollDeg: Double) -> CGPoint {
        let t = rollDeg * .pi / 180.0
        let ct = cos(t), st = sin(t)
        let vx = -xiDeg, vy = -etaDeg
        return CGPoint(x: Double(imageSize.width) / 2 + plateScalePxPerDeg * (ct * vx - st * vy),
                       y: Double(imageSize.height) / 2 + plateScalePxPerDeg * (st * vx + ct * vy))
    }

    static func wrap360(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360.0)
        return r < 0 ? r + 360.0 : r
    }

    // MARK: - Embedded catalog
    //
    // Brightest stars to V ≤ 3.5 — J2000 positions from the Yale Bright Star
    // Catalog (BSC5), tight doubles (< 0.1°, e.g. Alpha Crucis) merged keeping
    // the brighter component, sorted brightest-first. Name is the proper name
    // where one exists, else Bayer/Flamsteed + constellation.
    // Excluded on purpose (BSC lists them at historic maxima, but they are far
    // fainter than V 3.5 almost all the time and would act as phantom pattern
    // stars): T CrB (HR 5958, recurrent nova, V≈10 outside ~week-long outbursts)
    // and Mira (omicron Cet, long-period variable, V≈9 for most of its cycle).
    public static let catalog: [BrightStar] = [
        BrightStar("Sirius", 101.2871, -16.7161, -1.46),
        BrightStar("Canopus", 95.9879, -52.6958, -0.72),
        BrightStar("Arcturus", 213.9154, 19.1825, -0.04),
        BrightStar("Rigil Kentaurus", 219.8996, -60.8353, -0.01),
        BrightStar("Vega", 279.2346, 38.7836, 0.03),
        BrightStar("Capella", 79.1725, 45.9981, 0.08),
        BrightStar("Rigel", 78.6346, -8.2017, 0.12),
        BrightStar("Procyon", 114.8254, 5.2250, 0.38),
        BrightStar("Achernar", 24.4288, -57.2367, 0.46),
        BrightStar("Betelgeuse", 88.7929, 7.4069, 0.50),
        BrightStar("Hadar", 210.9558, -60.3731, 0.61),
        BrightStar("Altair", 297.6958, 8.8683, 0.77),
        BrightStar("Aldebaran", 68.9800, 16.5092, 0.85),
        BrightStar("Antares", 247.3517, -26.4319, 0.96),
        BrightStar("Spica", 201.2983, -11.1614, 0.98),
        BrightStar("Pollux", 116.3287, 28.0261, 1.14),
        BrightStar("Fomalhaut", 344.4129, -29.6222, 1.16),
        BrightStar("Mimosa", 191.9300, -59.6886, 1.25),
        BrightStar("Deneb", 310.3579, 45.2803, 1.25),
        BrightStar("Acrux", 186.6496, -63.0992, 1.33),
        BrightStar("Regulus", 152.0929, 11.9672, 1.35),
        BrightStar("Adhara", 104.6562, -28.9722, 1.50),
        BrightStar("Gacrux", 187.7913, -57.1133, 1.63),
        BrightStar("Shaula", 263.4021, -37.1039, 1.63),
        BrightStar("Bellatrix", 81.2829, 6.3497, 1.64),
        BrightStar("Elnath", 81.5729, 28.6075, 1.65),
        BrightStar("Miaplacidus", 138.3000, -69.7172, 1.68),
        BrightStar("Alnilam", 84.0533, -1.2019, 1.70),
        BrightStar("Alnair", 332.0583, -46.9611, 1.74),
        BrightStar("Alioth", 193.5071, 55.9597, 1.77),
        BrightStar("Gamma2 Vel", 122.3833, -47.3367, 1.78),
        BrightStar("Mirfak", 51.0808, 49.8611, 1.79),
        BrightStar("Dubhe", 165.9321, 61.7508, 1.79),
        BrightStar("Wezen", 107.0979, -26.3933, 1.84),
        BrightStar("Kaus Australis", 276.0429, -34.3847, 1.85),
        BrightStar("Avior", 125.6283, -59.5097, 1.86),
        BrightStar("Alkaid", 206.8850, 49.3133, 1.86),
        BrightStar("Sargas", 264.3300, -42.9978, 1.87),
        BrightStar("Menkalinan", 89.8821, 44.9475, 1.90),
        BrightStar("Atria", 252.1662, -69.0278, 1.92),
        BrightStar("Alhena", 99.4279, 16.3992, 1.93),
        BrightStar("Peacock", 306.4121, -56.7350, 1.94),
        BrightStar("Delta Vel", 131.1758, -54.7083, 1.96),
        BrightStar("Mirzam", 95.6750, -17.9558, 1.98),
        BrightStar("Castor", 113.6500, 31.8883, 1.98),
        BrightStar("Alphard", 141.8967, -8.6586, 1.98),
        BrightStar("Hamal", 31.7933, 23.4625, 2.00),
        BrightStar("Polaris", 37.9529, 89.2642, 2.02),
        BrightStar("Nunki", 283.8163, -26.2967, 2.02),
        BrightStar("Diphda", 10.8975, -17.9867, 2.04),
        BrightStar("Alnitak", 85.1896, -1.9428, 2.05),
        BrightStar("Alpheratz", 2.0971, 29.0906, 2.06),
        BrightStar("Mirach", 17.4329, 35.6206, 2.06),
        BrightStar("Saiph", 86.9392, -9.6697, 2.06),
        BrightStar("Menkent", 211.6708, -36.3700, 2.06),
        BrightStar("Kochab", 222.6763, 74.1556, 2.08),
        BrightStar("Rasalhague", 263.7337, 12.5600, 2.08),
        BrightStar("Beta Gru", 340.6671, -46.8847, 2.10),
        BrightStar("Algol", 47.0421, 40.9556, 2.12),
        BrightStar("Denebola", 177.2650, 14.5719, 2.14),
        BrightStar("Gamma Cen", 190.3792, -48.9597, 2.17),
        BrightStar("Sadr", 305.5571, 40.2567, 2.20),
        BrightStar("Suhail", 136.9992, -43.4325, 2.21),
        BrightStar("Schedar", 10.1271, 56.5372, 2.23),
        BrightStar("Mintaka", 83.0017, -0.2992, 2.23),
        BrightStar("Alphecca", 233.6721, 26.7147, 2.23),
        BrightStar("Eltanin", 269.1517, 51.4889, 2.23),
        BrightStar("Naos", 120.8963, -40.0033, 2.25),
        BrightStar("Aspidiske", 139.2725, -59.2753, 2.25),
        BrightStar("Almach", 30.9750, 42.3297, 2.26),
        BrightStar("Caph", 2.2946, 59.1497, 2.27),
        BrightStar("Mizar", 200.9812, 54.9253, 2.27),
        BrightStar("Epsilon Sco", 252.5408, -34.2933, 2.29),
        BrightStar("Epsilon Cen", 204.9717, -53.4664, 2.30),
        BrightStar("Alpha Lup", 220.4825, -47.3883, 2.30),
        BrightStar("Eta Cen", 218.8767, -42.1578, 2.31),
        BrightStar("Dschubba", 240.0833, -22.6217, 2.32),
        BrightStar("Merak", 165.4604, 56.3825, 2.37),
        BrightStar("Ankaa", 6.5708, -42.3061, 2.39),
        BrightStar("Enif", 326.0467, 9.8750, 2.39),
        BrightStar("Girtab", 265.6221, -39.0300, 2.41),
        BrightStar("Scheat", 345.9438, 28.0828, 2.42),
        BrightStar("Sabik", 257.5946, -15.7247, 2.43),
        BrightStar("Phecda", 178.4575, 53.6947, 2.44),
        BrightStar("Alderamin", 319.6450, 62.5856, 2.44),
        BrightStar("Aludra", 111.0238, -29.3031, 2.45),
        BrightStar("Epsilon Cyg", 311.5529, 33.9703, 2.46),
        BrightStar("Navi", 14.1771, 60.7167, 2.47),
        BrightStar("Markab", 346.1904, 15.2053, 2.49),
        BrightStar("Kappa Vel", 140.5283, -55.0108, 2.50),
        BrightStar("Menkar", 45.5700, 4.0897, 2.53),
        BrightStar("Zeta Cen", 208.8850, -47.2883, 2.55),
        BrightStar("Zosma", 168.5271, 20.5236, 2.56),
        BrightStar("Zeta Oph", 249.2896, -10.5672, 2.56),
        BrightStar("Arneb", 83.1825, -17.8222, 2.58),
        BrightStar("Gienah", 183.9517, -17.5419, 2.59),
        BrightStar("Delta Cen", 182.0896, -50.7225, 2.60),
        BrightStar("Ascella", 285.6529, -29.8803, 2.60),
        BrightStar("Algieba", 154.9929, 19.8417, 2.61),
        BrightStar("Zubeneschamali", 229.2517, -9.3831, 2.61),
        BrightStar("Mahasim", 89.9304, 37.2125, 2.62),
        BrightStar("Acrab", 241.3592, -19.8056, 2.62),
        BrightStar("Sheratan", 28.6600, 20.8081, 2.64),
        BrightStar("Phact", 84.9121, -34.0742, 2.64),
        BrightStar("Kraz", 188.5967, -23.3967, 2.65),
        BrightStar("Unukalhai", 236.0671, 6.4256, 2.65),
        BrightStar("Ruchbah", 21.4542, 60.2353, 2.68),
        BrightStar("Muphrid", 208.6713, 18.3978, 2.68),
        BrightStar("Beta Lup", 224.6329, -43.1339, 2.68),
        BrightStar("Kabdhilinan", 74.2483, 33.1661, 2.69),
        BrightStar("Mu Vel", 161.6925, -49.4200, 2.69),
        BrightStar("Alpha Mus", 189.2958, -69.1356, 2.69),
        BrightStar("Lesath", 262.6908, -37.2958, 2.69),
        BrightStar("Pi Pup", 109.2858, -37.0975, 2.70),
        BrightStar("Izar", 221.2467, 27.0742, 2.70),
        BrightStar("Kaus Media", 275.2487, -29.8281, 2.70),
        BrightStar("Tarazed", 296.5650, 10.6133, 2.72),
        BrightStar("Yed Prior", 243.5863, -3.6944, 2.74),
        BrightStar("Eta Dra", 245.9979, 61.5142, 2.74),
        BrightStar("Iota Cen", 200.1492, -36.7122, 2.75),
        BrightStar("Zubenelgenubi", 222.7196, -16.0417, 2.75),
        BrightStar("Theta Car", 160.7392, -64.3944, 2.76),
        BrightStar("Nair Al Saif", 83.8583, -5.9100, 2.77),
        BrightStar("Kornephoros", 247.5550, 21.4897, 2.77),
        BrightStar("Cebalrai", 265.8683, 4.5672, 2.77),
        BrightStar("Gamma Lup", 233.7854, -41.1669, 2.78),
        BrightStar("Cursa", 76.9625, -5.0864, 2.79),
        BrightStar("Rastaban", 262.6083, 52.3014, 2.79),
        BrightStar("Beta Hyi", 6.4379, -77.2542, 2.80),
        BrightStar("Delta Cru", 183.7862, -58.7489, 2.80),
        BrightStar("Tureis", 121.8858, -24.3042, 2.81),
        BrightStar("Zeta Her", 250.3217, 31.6031, 2.81),
        BrightStar("Kaus Borealis", 276.9925, -25.4217, 2.81),
        BrightStar("Alniyat", 248.9708, -28.2161, 2.82),
        BrightStar("Algenib", 3.3092, 15.1836, 2.83),
        BrightStar("Vindemiatrix", 195.5442, 10.9592, 2.83),
        BrightStar("Nihal", 82.0613, -20.7594, 2.84),
        BrightStar("Zeta Per", 58.5329, 31.8836, 2.85),
        BrightStar("Betria", 238.7854, -63.4306, 2.85),
        BrightStar("Beta Ara", 261.3250, -55.5300, 2.85),
        BrightStar("Head of Hydrus", 29.6925, -61.5697, 2.86),
        BrightStar("Alpha Tuc", 334.6254, -60.2597, 2.86),
        BrightStar("Alcyone", 56.8713, 24.1050, 2.87),
        BrightStar("Al Fawaris", 296.2437, 45.1308, 2.87),
        BrightStar("Deneb Algedi", 326.7600, -16.1272, 2.87),
        BrightStar("Tejat Posterior", 95.7400, 22.5136, 2.88),
        BrightStar("Epsilon Per", 59.4633, 40.0103, 2.89),
        BrightStar("Gatria", 229.7275, -68.6794, 2.89),
        BrightStar("Pi Sco", 239.7129, -26.1142, 2.89),
        BrightStar("Al Niyat", 245.2971, -25.5928, 2.89),
        BrightStar("Albaldah", 287.4408, -21.0236, 2.89),
        BrightStar("Gomeisa", 111.7875, 8.2894, 2.90),
        BrightStar("Chara", 194.0071, 38.3183, 2.90),
        BrightStar("Sadalsuud", 322.8896, -5.5711, 2.91),
        BrightStar("Gamma Per", 46.1992, 53.5064, 2.93),
        BrightStar("Tau Pup", 102.4842, -50.6147, 2.93),
        BrightStar("Matar", 340.7504, 30.2214, 2.94),
        BrightStar("Zaurak", 59.5075, -13.5086, 2.95),
        BrightStar("Algorab", 187.4663, -16.5156, 2.95),
        BrightStar("Alpha Ara", 262.9604, -49.8761, 2.95),
        BrightStar("Sadalmelik", 331.4458, -0.3197, 2.96),
        BrightStar("Mebsuta", 100.9829, 25.1311, 2.98),
        BrightStar("Ras Elased Australis", 146.4629, 23.7742, 2.98),
        BrightStar("Haldus", 75.4921, 43.8233, 2.99),
        BrightStar("Alnasl", 271.4521, -30.4242, 2.99),
        BrightStar("Deneb el Okab", 286.3525, 13.8633, 2.99),
        BrightStar("Beta Tri", 32.3858, 34.9872, 3.00),
        BrightStar("Tien Kwan", 84.4113, 21.1425, 3.00),
        BrightStar("Minkar", 182.5312, -22.6197, 3.00),
        BrightStar("Gamma Hya", 199.7304, -23.1717, 3.00),
        BrightStar("Delta Per", 55.7313, 47.7875, 3.01),
        BrightStar("Upsilon Car", 146.7754, -65.0719, 3.01),
        BrightStar("Psi UMa", 167.4158, 44.4986, 3.01),
        BrightStar("Aldhanab", 328.4821, -37.3650, 3.01),
        BrightStar("Furud", 95.0783, -30.0633, 3.02),
        BrightStar("Omicron2 CMa", 105.7562, -23.8333, 3.02),
        BrightStar("Seginus", 218.0196, 38.3083, 3.03),
        BrightStar("Iota1 Sco", 266.8963, -40.1269, 3.03),
        BrightStar("Mu Cen", 207.4042, -42.4739, 3.04),
        BrightStar("Tania Australis", 155.5821, 41.4994, 3.05),
        BrightStar("Beta Mus", 191.5704, -68.1081, 3.05),
        BrightStar("Pherkad", 230.1821, 71.8339, 3.05),
        BrightStar("Altais", 288.1388, 67.6617, 3.07),
        BrightStar("Mu1 Sco", 252.9675, -38.0475, 3.08),
        BrightStar("Albireo", 292.6804, 27.9597, 3.08),
        BrightStar("Dabih", 305.2529, -14.7814, 3.08),
        BrightStar("Hydrobius", 133.8483, 5.9456, 3.11),
        BrightStar("Nu Hya", 162.4062, -16.1936, 3.11),
        BrightStar("Eta Sgr", 274.4067, -36.7617, 3.11),
        BrightStar("Alpha Ind", 309.3917, -47.2914, 3.11),
        BrightStar("Wazn", 87.7400, -35.7683, 3.12),
        BrightStar("Alpha Lyn", 140.2637, 34.3925, 3.13),
        BrightStar("HR 3803", 142.8054, -57.0344, 3.13),
        BrightStar("Lambda Cen", 173.9450, -63.0197, 3.13),
        BrightStar("Kappa Cen", 224.7904, -42.1042, 3.13),
        BrightStar("Zeta Ara", 254.6550, -55.9903, 3.13),
        BrightStar("Talitha", 134.8017, 48.0417, 3.14),
        BrightStar("Sarin", 258.7579, 24.8392, 3.14),
        BrightStar("Pi Her", 258.7617, 36.8092, 3.16),
        BrightStar("Hoedus II", 76.6287, 41.2344, 3.17),
        BrightStar("Nu Pup", 99.4404, -43.1961, 3.17),
        BrightStar("Sarir", 143.2142, 51.6772, 3.17),
        BrightStar("Aldhibain", 257.1967, 65.7147, 3.17),
        BrightStar("Phi Sgr", 281.4142, -26.9908, 3.17),
        BrightStar("Tabit", 72.4600, 6.9614, 3.19),
        BrightStar("Epsilon Lep", 76.3654, -22.3711, 3.19),
        BrightStar("Alpha Cir", 220.6267, -64.9753, 3.19),
        BrightStar("Kappa Oph", 254.4171, 9.3750, 3.20),
        BrightStar("Zeta Cyg", 318.2342, 30.2269, 3.20),
        BrightStar("HR 6630", 267.4646, -37.0433, 3.21),
        BrightStar("Errai", 354.8367, 77.6325, 3.21),
        BrightStar("Delta Lup", 230.3429, -40.6475, 3.22),
        BrightStar("Theta Aql", 302.8263, -0.8214, 3.23),
        BrightStar("Alfirk", 322.1650, 70.5608, 3.23),
        BrightStar("Acamar", 44.5654, -40.3047, 3.24),
        BrightStar("Gamma Hyi", 56.8096, -74.2389, 3.24),
        BrightStar("Yed Posterior", 244.5804, -4.6925, 3.24),
        BrightStar("Sulafat", 284.7358, 32.6894, 3.24),
        BrightStar("Sigma Pup", 112.3075, -43.3014, 3.25),
        BrightStar("Eta Ser", 275.3275, -2.8989, 3.26),
        BrightStar("Delta And", 9.8321, 30.8608, 3.27),
        BrightStar("Alpha Dor", 68.4992, -55.0450, 3.27),
        BrightStar("Alpha Pic", 102.0475, -61.9414, 3.27),
        BrightStar("Pi Hya", 211.5929, -26.6825, 3.27),
        BrightStar("Theta Oph", 260.5025, -24.9994, 3.27),
        BrightStar("Skat", 343.6625, -15.8208, 3.27),
        BrightStar("Propus", 93.7192, 22.5067, 3.28),
        BrightStar("Brachium", 226.0175, -25.2819, 3.29),
        BrightStar("Edasich", 231.2325, 58.9661, 3.29),
        BrightStar("Beta Phe", 16.5208, -46.7186, 3.31),
        BrightStar("Mu Lep", 78.2329, -16.2056, 3.31),
        BrightStar("Megrez", 183.8567, 57.0325, 3.31),
        BrightStar("Omega Car", 153.4342, -70.0381, 3.32),
        BrightStar("HR 4140", 158.0058, -61.6853, 3.32),
        BrightStar("Tau Sgr", 286.7350, -27.6706, 3.32),
        BrightStar("Eta Sco", 258.0383, -43.2392, 3.33),
        BrightStar("Azmidiske", 117.3237, -24.8597, 3.34),
        BrightStar("Chertan", 168.5600, 15.4294, 3.34),
        BrightStar("Gamma Ara", 261.3483, -56.3775, 3.34),
        BrightStar("Sinistra", 269.7567, -9.7736, 3.34),
        BrightStar("Alpha Ret", 63.6062, -62.4739, 3.35),
        BrightStar("Zeta Cep", 332.7138, 58.2011, 3.35),
        BrightStar("Eta Ori", 81.1192, -2.3969, 3.36),
        BrightStar("Alzir", 101.3225, 12.8956, 3.36),
        BrightStar("Muscida", 127.5662, 60.7181, 3.36),
        BrightStar("Delta Aql", 291.3746, 3.1147, 3.36),
        BrightStar("Heze", 203.6733, -0.5958, 3.37),
        BrightStar("Epsilon Lup", 230.6704, -44.6894, 3.37),
        BrightStar("Segin", 28.5987, 63.6700, 3.38),
        BrightStar("Epsilon Hya", 131.6942, 6.4189, 3.38),
        BrightStar("Auva", 193.9008, 3.3975, 3.38),
        BrightStar("Gorgonea Tertia", 46.2942, 38.8403, 3.39),
        BrightStar("Theta2 Tau", 67.1654, 15.8708, 3.40),
        BrightStar("HR 4050", 154.2708, -61.3322, 3.40),
        BrightStar("Homam", 340.3654, 10.8314, 3.40),
        BrightStar("Gamma Phe", 22.0913, -43.3183, 3.41),
        BrightStar("Mothallah", 28.2704, 29.5789, 3.41),
        BrightStar("Nu Cen", 207.3762, -41.6878, 3.41),
        BrightStar("Zeta Lup", 228.0712, -52.0992, 3.41),
        BrightStar("Eta Lup", 240.0304, -38.3969, 3.41),
        BrightStar("Mu Her", 266.6146, 27.7206, 3.42),
        BrightStar("Beta Pav", 311.2396, -66.2031, 3.42),
        BrightStar("Eta Cep", 311.3225, 61.8389, 3.43),
        BrightStar("Achird", 12.2750, 57.8158, 3.44),
        BrightStar("HR 3659", 137.7417, -58.9669, 3.44),
        BrightStar("Adhafera", 154.1725, 23.4172, 3.44),
        BrightStar("Al Thalimain", 286.5621, -4.8825, 3.44),
        BrightStar("Dheneb", 17.1475, -10.1822, 3.45),
        BrightStar("Tania Borealis", 154.2742, 42.9144, 3.45),
        BrightStar("Sheliak", 282.5200, 33.3628, 3.45),
        BrightStar("Kaffaljidhma", 40.8250, 3.2358, 3.47),
        BrightStar("Lambda Tau", 60.1700, 12.4903, 3.47),
        BrightStar("Sigma CMa", 105.4296, -27.9347, 3.47),
        BrightStar("Chi Car", 119.1946, -52.9822, 3.47),
        BrightStar("Delta Boo", 228.8758, 33.3147, 3.47),
        BrightStar("Gamma Sge", 299.6892, 19.4922, 3.47),
        BrightStar("Alula Borealis", 169.6196, 33.0942, 3.48),
        BrightStar("Rasalgethi", 258.6621, 14.3903, 3.48),
        BrightStar("Sadalbari", 342.5008, 24.6017, 3.48),
        BrightStar("Epsilon Gru", 342.1388, -51.3169, 3.49),
        BrightStar("Tau Cet", 26.0171, -15.9375, 3.50),
        BrightStar("Nekkar", 225.4867, 40.3906, 3.50),
    ]
}
