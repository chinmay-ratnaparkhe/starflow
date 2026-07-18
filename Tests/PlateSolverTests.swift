import XCTest
import CoreGraphics
@testable import StarFlow

/// PlateSolver vs synthesized star fields.
///
/// Fields are synthesized from the solver's own embedded catalog through the
/// documented camera model (`PlateSolver.pixel`): pick a center, plate scale,
/// and roll; project every catalog star that lands in the frame; perturb with
/// deterministic sub-pixel noise. The solver must recover the center within
/// 0.3°, the roll within 1°, and must refuse to solve star-free noise, mirrored
/// (wrong-chirality) fields, and fields whose FOV estimate is far off.
///
/// The test fields are real asterisms chosen to hold ≥ 6 catalog stars (the
/// solver's honest minimum for a verified solve at mag ≤ 3.5 catalog depth):
/// Orion, the Big Dipper, Crux, Cygnus, Cassiopeia, Scorpius, Sagittarius wide
/// field, Leo, and the Carina/Crux deep-south region.
final class PlateSolverTests: XCTestCase {

    /// Triangle table built once for the whole suite.
    private static let sharedSolver = PlateSolver()
    private var solver: PlateSolver { Self.sharedSolver }

    private let imageSize = CGSize(width: 1920, height: 1440)

    // MARK: - Synthesis (documented camera model, deterministic noise)

    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {   // uniform 0..<1
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992.0
        }
    }

    /// All catalog stars inside the frame, brightest-first (the order
    /// `CPUStacker.detectStars` delivers), with ±noisePx uniform jitter.
    private func synthesizeField(centerRADeg: Double, centerDecDeg: Double,
                                 fovDeg: Double, rollDeg: Double,
                                 noisePx: Double = 0.8, seed: UInt64 = 7,
                                 dropFaintest: Int = 0, spurious: Int = 0) -> [CGPoint] {
        let w = Double(imageSize.width), h = Double(imageSize.height)
        let scale = w / fovDeg
        var rng = LCG(state: seed)
        var points: [CGPoint] = []
        for star in PlateSolver.catalog {   // already brightest-first
            guard let p = PlateSolver.tangentProject(raDeg: star.raDeg, decDeg: star.decDeg,
                                                     centerRADeg: centerRADeg,
                                                     centerDecDeg: centerDecDeg) else { continue }
            let pixel = PlateSolver.pixel(xiDeg: p.x, etaDeg: p.y, imageSize: imageSize,
                                          plateScalePxPerDeg: scale, rollDeg: rollDeg)
            guard pixel.x >= 0, pixel.x < w, pixel.y >= 0, pixel.y < h else { continue }
            points.append(CGPoint(x: Double(pixel.x) + (rng.next() * 2 - 1) * noisePx,
                                  y: Double(pixel.y) + (rng.next() * 2 - 1) * noisePx))
        }
        if dropFaintest > 0, points.count > dropFaintest {
            points.removeLast(dropFaintest)
        }
        for _ in 0..<spurious {
            points.append(CGPoint(x: rng.next() * w, y: rng.next() * h))
        }
        return points
    }

    private func rollDifferenceDeg(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360.0))
        return min(d, 360.0 - d)
    }

    private func assertSolves(centerRADeg: Double, centerDecDeg: Double,
                              fovDeg: Double, rollDeg: Double,
                              field: String, file: StaticString = #filePath,
                              line: UInt = #line) {
        let points = synthesizeField(centerRADeg: centerRADeg, centerDecDeg: centerDecDeg,
                                     fovDeg: fovDeg, rollDeg: rollDeg)
        // FOV estimate deliberately 15% off — the solver only gets a rough hint.
        guard let solution = solver.solve(centroids: points, imageSize: imageSize,
                                          fovEstimateDeg: fovDeg * 1.15) else {
            return XCTFail("\(field): no solve from \(points.count) stars", file: file, line: line)
        }
        let centerError = PlateSolver.angularSeparationDeg(
            ra1Deg: solution.centerRADeg, dec1Deg: solution.centerDecDeg,
            ra2Deg: centerRADeg, dec2Deg: centerDecDeg)
        XCTAssertLessThan(centerError, 0.3,
                          "\(field): center off by \(centerError)°", file: file, line: line)
        XCTAssertLessThan(rollDifferenceDeg(solution.rollDeg, rollDeg), 1.0,
                          "\(field): roll \(solution.rollDeg) vs \(rollDeg)", file: file, line: line)
        let trueScale = Double(imageSize.width) / fovDeg
        XCTAssertEqual(solution.plateScalePxPerDeg, trueScale, accuracy: trueScale * 0.02,
                       "\(field): plate scale", file: file, line: line)
        XCTAssertGreaterThanOrEqual(solution.matchedCount, 6, file: file, line: line)
        XCTAssertLessThan(solution.residualPx, 2.0, file: file, line: line)
    }

    // MARK: - Known asterisms at known plate scale / roll

    func testSolvesOrionNorthUp() {
        assertSolves(centerRADeg: 83.0, centerDecDeg: 1.0, fovDeg: 25.0, rollDeg: 0.0,
                     field: "Orion")
    }

    func testSolvesOrionRolled30() {
        assertSolves(centerRADeg: 83.0, centerDecDeg: 1.0, fovDeg: 25.0, rollDeg: 30.0,
                     field: "Orion r30")
    }

    func testSolvesBigDipper() {
        assertSolves(centerRADeg: 195.0, centerDecDeg: 57.0, fovDeg: 34.0, rollDeg: 123.4,
                     field: "Big Dipper")
    }

    func testSolvesCrux() {
        assertSolves(centerRADeg: 187.0, centerDecDeg: -60.0, fovDeg: 20.0, rollDeg: 77.0,
                     field: "Crux")
    }

    func testSolvesCygnus() {
        assertSolves(centerRADeg: 310.0, centerDecDeg: 42.0, fovDeg: 40.0, rollDeg: 200.0,
                     field: "Cygnus")
    }

    func testSolvesCassiopeiaRollNearWrap() {
        assertSolves(centerRADeg: 10.0, centerDecDeg: 60.0, fovDeg: 22.0, rollDeg: 355.0,
                     field: "Cassiopeia")
    }

    func testSolvesScorpius() {
        assertSolves(centerRADeg: 247.0, centerDecDeg: -26.0, fovDeg: 28.0, rollDeg: 45.0,
                     field: "Scorpius")
    }

    func testSolvesWideSagittariusMainCameraFOV() {
        assertSolves(centerRADeg: 270.0, centerDecDeg: -25.0, fovDeg: 60.0, rollDeg: 10.0,
                     field: "Sagittarius wide")
    }

    func testSolvesLeo() {
        assertSolves(centerRADeg: 160.0, centerDecDeg: 15.0, fovDeg: 45.0, rollDeg: 290.0,
                     field: "Leo")
    }

    func testSolvesDeepSouthHighDeclination() {
        assertSolves(centerRADeg: 150.0, centerDecDeg: -65.0, fovDeg: 45.0, rollDeg: 180.0,
                     field: "Carina/Crux")
    }

    // MARK: - Robustness

    /// Heavier noise, two faintest stars missing, three spurious detections:
    /// still solves, still lands inside the acceptance box.
    func testSolvesDegradedField() {
        let points = synthesizeField(centerRADeg: 83.0, centerDecDeg: 1.0,
                                     fovDeg: 25.0, rollDeg: 30.0,
                                     noisePx: 1.0, seed: 3, dropFaintest: 2, spurious: 3)
        guard let solution = solver.solve(centroids: points, imageSize: imageSize,
                                          fovEstimateDeg: 28.0) else {
            return XCTFail("degraded Orion field did not solve")
        }
        let centerError = PlateSolver.angularSeparationDeg(
            ra1Deg: solution.centerRADeg, dec1Deg: solution.centerDecDeg,
            ra2Deg: 83.0, dec2Deg: 1.0)
        XCTAssertLessThan(centerError, 0.3)
        XCTAssertLessThan(rollDifferenceDeg(solution.rollDeg, 30.0), 1.0)
        XCTAssertGreaterThanOrEqual(solution.matchedCount, 6)
    }

    // MARK: - No false solves

    /// Random scatter must never produce a solution — a wrong GoTo answer is far
    /// worse than none.
    func testRejectsRandomScatterFields() {
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            var rng = LCG(state: seed)
            let points = (0..<30).map { _ in
                CGPoint(x: rng.next() * Double(imageSize.width),
                        y: rng.next() * Double(imageSize.height))
            }
            XCTAssertNil(solver.solve(centroids: points, imageSize: imageSize,
                                      fovEstimateDeg: 25.0),
                         "false solve on random scatter, seed \(seed)")
        }
    }

    func testRejectsTooFewCentroids() {
        XCTAssertNil(solver.solve(centroids: [], imageSize: imageSize, fovEstimateDeg: 25.0))
        let four = [CGPoint(x: 100, y: 100), CGPoint(x: 900, y: 200),
                    CGPoint(x: 500, y: 800), CGPoint(x: 1400, y: 1100)]
        XCTAssertNil(solver.solve(centroids: four, imageSize: imageSize, fovEstimateDeg: 25.0))
    }

    /// A mirrored field (x flipped — wrong chirality) must refuse to solve.
    /// Side-ratio invariants survive reflection, so the hash lookups all hit;
    /// this exercises the no-reflection similarity fit, its residual gate, and
    /// the inlier verification end to end.
    func testRejectsMirroredFields() {
        let fields: [(ra: Double, dec: Double, fov: Double, roll: Double)] = [
            (83.0, 1.0, 25.0, 0.0),        // Orion
            (195.0, 57.0, 34.0, 123.4),    // Big Dipper
            (187.0, -60.0, 20.0, 77.0),    // Crux
            (247.0, -26.0, 28.0, 45.0),    // Scorpius
            (270.0, -25.0, 60.0, 10.0),    // Sagittarius wide
        ]
        for f in fields {
            let mirrored = synthesizeField(centerRADeg: f.ra, centerDecDeg: f.dec,
                                           fovDeg: f.fov, rollDeg: f.roll)
                .map { CGPoint(x: imageSize.width - $0.x, y: $0.y) }
            XCTAssertNil(solver.solve(centroids: mirrored, imageSize: imageSize,
                                      fovEstimateDeg: f.fov * 1.15),
                         "mirrored field must not solve: \(f)")
        }
    }

    /// A wildly wrong FOV estimate (3× either way, outside the ±60% scale
    /// window) must refuse rather than force a fit.
    func testRejectsWildlyWrongFOVEstimate() {
        let points = synthesizeField(centerRADeg: 83.0, centerDecDeg: 1.0,
                                     fovDeg: 25.0, rollDeg: 0.0)
        XCTAssertNil(solver.solve(centroids: points, imageSize: imageSize,
                                  fovEstimateDeg: 75.0),
                     "3× overestimated FOV must not solve")
        XCTAssertNil(solver.solve(centroids: points, imageSize: imageSize,
                                  fovEstimateDeg: 8.0),
                     "3× underestimated FOV must not solve")
    }

    // MARK: - Catalog & geometry sanity

    func testCatalogIsBrightestFirstAndSane() {
        let catalog = PlateSolver.catalog
        XCTAssertGreaterThan(catalog.count, 250)
        XCTAssertLessThan(catalog.count, 320)
        XCTAssertEqual(catalog.first?.name, "Sirius")
        for star in catalog {
            XCTAssertGreaterThanOrEqual(star.raDeg, 0.0)
            XCTAssertLessThan(star.raDeg, 360.0)
            XCTAssertGreaterThanOrEqual(star.decDeg, -90.0)
            XCTAssertLessThanOrEqual(star.decDeg, 90.0)
            XCTAssertLessThanOrEqual(star.mag, 3.5)
        }
        for i in 1..<catalog.count {
            XCTAssertLessThanOrEqual(catalog[i - 1].mag, catalog[i].mag,
                                     "catalog must stay brightest-first")
        }
        // Spot-check a J2000 position: Vega, RA 18h36m56.3s, Dec +38°47'01".
        guard let vega = catalog.first(where: { $0.name == "Vega" }) else {
            return XCTFail("Vega missing from catalog")
        }
        XCTAssertEqual(vega.raDeg, 279.2346, accuracy: 0.01)
        XCTAssertEqual(vega.decDeg, 38.7836, accuracy: 0.01)
    }

    /// Pin the projection and camera-model sign conventions against hardcoded
    /// first-principles expectations. The solve tests above synthesize fields
    /// through the solver's own projection, so a consistent sign flip there
    /// would cancel and still pass them — these anchors are the independent
    /// ground truth for the documented "north up, east LEFT, y down" contract.
    func testProjectionAndCameraModelSignConventions() {
        // A star 1° east of center (larger RA) has positive ξ, zero η …
        guard let east = PlateSolver.tangentProject(raDeg: 81.0, decDeg: 0.0,
                                                    centerRADeg: 80.0, centerDecDeg: 0.0),
              let north = PlateSolver.tangentProject(raDeg: 80.0, decDeg: 1.0,
                                                     centerRADeg: 80.0, centerDecDeg: 0.0)
        else { return XCTFail("anchor projections failed") }
        XCTAssertEqual(east.x, 1.0001, accuracy: 0.001)   // tan(1°) in degrees
        XCTAssertEqual(east.y, 0.0, accuracy: 1e-9)
        // … a star 1° north has zero ξ, positive η …
        XCTAssertEqual(north.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(north.y, 1.0001, accuracy: 0.001)
        // … and at roll 0 east lands LEFT of center (direct sky view):
        let pxEast = PlateSolver.pixel(xiDeg: 1.0, etaDeg: 0.0, imageSize: imageSize,
                                       plateScalePxPerDeg: 50.0, rollDeg: 0.0)
        XCTAssertEqual(Double(pxEast.x), 910.0, accuracy: 1e-6)   // 960 − 50
        XCTAssertEqual(Double(pxEast.y), 720.0, accuracy: 1e-6)
        // … while north lands ABOVE center (pixel y grows down):
        let pxNorth = PlateSolver.pixel(xiDeg: 0.0, etaDeg: 1.0, imageSize: imageSize,
                                        plateScalePxPerDeg: 50.0, rollDeg: 0.0)
        XCTAssertEqual(Double(pxNorth.x), 960.0, accuracy: 1e-6)
        XCTAssertEqual(Double(pxNorth.y), 670.0, accuracy: 1e-6)  // 720 − 50
    }

    /// Gnomonic projection round-trips through its inverse.
    func testTangentProjectionRoundTrip() {
        let cases: [(ra: Double, dec: Double, ra0: Double, dec0: Double)] = [
            (83.0, 1.0, 80.0, 5.0),
            (10.0, 60.0, 355.0, 55.0),      // RA wrap across 0
            (150.0, -65.0, 160.0, -60.0),
            (270.0, -25.0, 250.0, -20.0),
        ]
        for c in cases {
            guard let p = PlateSolver.tangentProject(raDeg: c.ra, decDeg: c.dec,
                                                     centerRADeg: c.ra0, centerDecDeg: c.dec0)
            else { return XCTFail("projection failed for \(c)") }
            let back = PlateSolver.tangentDeproject(xiDeg: p.x, etaDeg: p.y,
                                                    centerRADeg: c.ra0, centerDecDeg: c.dec0)
            let separation = PlateSolver.angularSeparationDeg(
                ra1Deg: back.raDeg, dec1Deg: back.decDeg, ra2Deg: c.ra, dec2Deg: c.dec)
            XCTAssertLessThan(separation, 1e-9, "round trip drifted for \(c)")
        }
    }
}
