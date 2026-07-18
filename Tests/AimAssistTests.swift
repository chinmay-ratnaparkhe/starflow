import XCTest
@testable import StarFlow

/// Pure-math tests for Aim Assist: shortest-path yaw planning, pitch-envelope
/// clamping, and target resolution against SkyEngine. No CoreMotion anywhere —
/// everything here must pass on the iOS Simulator.
@MainActor
final class AimAssistTests: XCTestCase {

    // MARK: - Shortest-path yaw delta (wrap ±180)

    func testShortestYawDeltaAcrossNorthWrap() {
        // 350° → 10° is +20° through north, never −340°.
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 350, toDeg: 10), 20, accuracy: 1e-9)
        // And back: 10° → 350° is −20°.
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 10, toDeg: 350), -20, accuracy: 1e-9)
    }

    func testShortestYawDeltaSimpleAndZero() {
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 90, toDeg: 120), 30, accuracy: 1e-9)
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 120, toDeg: 90), -30, accuracy: 1e-9)
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 42, toDeg: 42), 0, accuracy: 1e-9)
    }

    func testShortestYawDeltaHalfTurnBoundary() {
        // Exactly opposite: +180 by the (−180, 180] convention.
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 0, toDeg: 180), 180, accuracy: 1e-9)
        // Just past opposite flips to the short negative path.
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 0, toDeg: 181), -179, accuracy: 1e-9)
        XCTAssertEqual(AimAssist.shortestYawDeltaDeg(fromDeg: 0, toDeg: 179), 179, accuracy: 1e-9)
    }

    func testShortestYawDeltaNeverExceedsHalfTurn() {
        for from in stride(from: 0.0, through: 350.0, by: 37.0) {
            for to in stride(from: 0.0, through: 350.0, by: 41.0) {
                let d = AimAssist.shortestYawDeltaDeg(fromDeg: from, toDeg: to)
                XCTAssertLessThanOrEqual(abs(d), 180.0 + 1e-9, "\(from)° → \(to)°")
                // Applying the delta must land on the target azimuth (mod 360).
                let landed = (from + d).truncatingRemainder(dividingBy: 360)
                let wrapped = landed < 0 ? landed + 360 : landed
                XCTAssertEqual(wrapped, to, accuracy: 1e-9, "\(from)° + \(d)° must land on \(to)°")
            }
        }
    }

    // MARK: - Slew plan: pitch envelope clamp

    func testPlanUnclampedInsideEnvelope() {
        // Camera at alt 10° with the mount at pitch 0°: aiming to alt 20° is a +10°
        // move, landing at mount pitch +10° — comfortably inside −38.4…+27.5.
        let plan = AimAssist.plan(currentAzimuthDeg: 100, currentAltitudeDeg: 10,
                                  mountPitchDeg: 0,
                                  target: HorizontalCoord(altitudeDeg: 20, azimuthDeg: 130))
        XCTAssertEqual(plan.deltaYawDeg, 30, accuracy: 1e-9)
        XCTAssertEqual(plan.deltaPitchDeg, 10, accuracy: 1e-9)
        XCTAssertFalse(plan.pitchClamped)
    }

    func testPlanClampsHighTargetToPitchCeiling() {
        // Aiming 50° up from a level camera would need mount pitch +50° — the head
        // tops out at +27.5°, so the plan must command the partial move and flag it.
        let plan = AimAssist.plan(currentAzimuthDeg: 0, currentAltitudeDeg: 10,
                                  mountPitchDeg: 0,
                                  target: HorizontalCoord(altitudeDeg: 60, azimuthDeg: 0))
        XCTAssertTrue(plan.pitchClamped)
        XCTAssertEqual(plan.deltaPitchDeg, GimbalConstants.pitchMaxDeg, accuracy: 1e-9)
    }

    func testPlanClampsLowTargetToPitchFloor() {
        // From mount pitch −30°, diving another −20° would pass the −38.4° floor.
        let plan = AimAssist.plan(currentAzimuthDeg: 0, currentAltitudeDeg: -10,
                                  mountPitchDeg: -30,
                                  target: HorizontalCoord(altitudeDeg: -30, azimuthDeg: 0))
        XCTAssertTrue(plan.pitchClamped)
        XCTAssertEqual(plan.deltaPitchDeg, GimbalConstants.pitchMinDeg - (-30), accuracy: 1e-9)
        // The commanded move must land exactly on the envelope edge, never past it.
        XCTAssertEqual(-30 + plan.deltaPitchDeg, GimbalConstants.pitchMinDeg, accuracy: 1e-9)
    }

    func testPlanRespectsMountOffsetFromCameraAltitude() {
        // The phone can sit tilted in the clamp: camera altitude 5° while the mount
        // reads pitch +25°. Aiming to alt 15° is a +10° camera move, but that lands
        // the MOUNT at +35° — past the ceiling, so only +2.5° is commandable.
        let plan = AimAssist.plan(currentAzimuthDeg: 200, currentAltitudeDeg: 5,
                                  mountPitchDeg: 25,
                                  target: HorizontalCoord(altitudeDeg: 15, azimuthDeg: 200))
        XCTAssertTrue(plan.pitchClamped)
        XCTAssertEqual(plan.deltaPitchDeg, GimbalConstants.pitchMaxDeg - 25, accuracy: 1e-9)
    }

    // MARK: - Pointing error estimate

    func testPointingErrorZeroOnTarget() {
        let target = HorizontalCoord(altitudeDeg: 25, azimuthDeg: 180)
        let err = AimAssist.pointingErrorDeg(
            from: AimAssist.Attitude(azimuthDeg: 180, altitudeDeg: 25), to: target)
        XCTAssertEqual(err, 0, accuracy: 1e-9)
    }

    func testPointingErrorForeshortensAzimuthByAltitude() {
        // 10° of azimuth error at 60° altitude is only ~5° of real sky arc.
        let target = HorizontalCoord(altitudeDeg: 60, azimuthDeg: 100)
        let err = AimAssist.pointingErrorDeg(
            from: AimAssist.Attitude(azimuthDeg: 90, altitudeDeg: 60), to: target)
        XCTAssertEqual(err, 10 * cos(60 * Double.pi / 180), accuracy: 1e-9)
    }

    // MARK: - Target resolution vs SkyEngine (fixed date + location)

    /// A fixed mid-2026 instant (UTC) so ephemeris output is fully deterministic.
    private let fixedDate = Date(timeIntervalSince1970: 1_783_231_200)
    private let boulder = GeoLocation(latitude: 40.0, longitude: -105.25)

    func testResolveMilkyWayCoreMatchesSkyEngine() {
        let engine = SkyEngine()
        let assist = AimAssist(sky: engine)
        let resolved = assist.resolve(target: .milkyWayCore, location: boulder, date: fixedDate)
        let expected = engine.milkyWayCorePosition(at: boulder, date: fixedDate)
        XCTAssertEqual(resolved.altitudeDeg, expected.altitudeDeg, accuracy: 1e-9)
        XCTAssertEqual(resolved.azimuthDeg, expected.azimuthDeg, accuracy: 1e-9)
    }

    func testResolveMoonMatchesSkyEngine() {
        let engine = SkyEngine()
        let assist = AimAssist(sky: engine)
        let resolved = assist.resolve(target: .moon, location: boulder, date: fixedDate)
        let expected = engine.moonInfo(at: boulder, date: fixedDate).position
        XCTAssertEqual(resolved.altitudeDeg, expected.altitudeDeg, accuracy: 1e-9)
        XCTAssertEqual(resolved.azimuthDeg, expected.azimuthDeg, accuracy: 1e-9)
    }

    func testResolvedCoordsAreWellFormed() {
        let assist = AimAssist(sky: SkyEngine())
        for target in [CelestialTarget.milkyWayCore, .moon] {
            let c = assist.resolve(target: target, location: boulder, date: fixedDate)
            XCTAssertGreaterThanOrEqual(c.altitudeDeg, -90, "\(target.rawValue)")
            XCTAssertLessThanOrEqual(c.altitudeDeg, 90, "\(target.rawValue)")
            XCTAssertGreaterThanOrEqual(c.azimuthDeg, 0, "\(target.rawValue)")
            XCTAssertLessThan(c.azimuthDeg, 360, "\(target.rawValue)")
        }
    }

    // MARK: - Registry wiring

    func testRegistryAimTargets() throws {
        let milkyway = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        XCTAssertEqual(milkyway.celestialTarget, .milkyWayCore)
        let lunar = try XCTUnwrap(ShotModeRegistry.mode(id: "lunar"))
        XCTAssertEqual(lunar.celestialTarget, .moon)
        // Modes without a single well-defined target must stay manual-aim.
        let trails = try XCTUnwrap(ShotModeRegistry.mode(id: "startrails"))
        XCTAssertNil(trails.celestialTarget)
    }
}
