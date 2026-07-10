import XCTest
@testable import StarFlow

/// Pure-math tests for the Mount module's planning logic: drift feed-forward rates,
/// nudge decisions, the impulse solver, cable-wrap accounting, and the pitch envelope.
/// No DockKit, no hardware — everything here must pass on the iOS Simulator.
final class NudgePlannerTests: XCTestCase {

    /// ω = 7.2921e-5 rad/s = 4.178066e-3 deg/s (hand-computed once, used as the anchor).
    private let omegaDegPerSec = 4.178066e-3

    // MARK: - Drift rates vs hand-computed values (tolerance 5%)

    func testDriftRatesEquatorEast() {
        // Equator, target due east at 30° altitude: pure vertical rise at the full
        // sidereal rate, zero azimuth drift (stars rise straight up on the equator).
        let r = NudgePlanner.driftRates(altDeg: 30, azDeg: 90, latitudeDeg: 0)
        XCTAssertEqual(r.altDegPerSec, 4.178066e-3, accuracy: 4.178066e-3 * 0.05)
        XCTAssertEqual(r.azDegPerSec, 0, accuracy: 1e-9)
    }

    func testDriftRatesMidLatitudeSouth() {
        // Lat 45°N, target due south at 40° altitude (culmination):
        // dAlt/dt = ω·cos45·sin180 = 0
        // dAz/dt  = ω·(sin45 + cos45·tan40) = ω·1.300423 = 5.4333e-3 deg/s (hand-computed).
        let r = NudgePlanner.driftRates(altDeg: 40, azDeg: 180, latitudeDeg: 45)
        XCTAssertEqual(r.altDegPerSec, 0, accuracy: 1e-9)
        XCTAssertEqual(r.azDegPerSec, 5.4333e-3, accuracy: 5.4333e-3 * 0.05)
    }

    func testDriftRatesMidLatitudeEast() {
        // Lat 40°N, target due east at 20° altitude:
        // dAlt/dt = ω·cos40 = 3.20063e-3 deg/s (hand-computed)
        // dAz/dt  = ω·sin40 = 2.68563e-3 deg/s (cos(90°) kills the tan term).
        let r = NudgePlanner.driftRates(altDeg: 20, azDeg: 90, latitudeDeg: 40)
        XCTAssertEqual(r.altDegPerSec, 3.20063e-3, accuracy: 3.20063e-3 * 0.05)
        XCTAssertEqual(r.azDegPerSec, 2.68563e-3, accuracy: 2.68563e-3 * 0.05)
    }

    func testWorstCaseDriftMatchesMeasuredConstant() {
        // The documented worst-case sky drift (0.2507 deg/min) is ω itself:
        // equator, due east. The formulas must reproduce the measured constant.
        let r = NudgePlanner.driftRates(altDeg: 30, azDeg: 90, latitudeDeg: 0)
        XCTAssertEqual(r.magnitudeDegPerSec * 60.0, GimbalConstants.skyDriftDegPerMin,
                       accuracy: GimbalConstants.skyDriftDegPerMin * 0.05)
    }

    // MARK: - Impulse solver round-trips

    func testImpulseRoundTrips() {
        // Every solvable delta must round-trip: rate × duration = requested angle,
        // with |rate| in [velocityFloor, slewRate] and duration ≤ velocityExpiry.
        let deltas: [Double] = [0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 25.0, 40.0,
                                -0.5, -3.0, -12.0]
        for delta in deltas {
            guard let imp = NudgePlanner.impulse(forDeltaDeg: delta) else {
                XCTFail("Solver returned nil for \(delta)°")
                continue
            }
            XCTAssertEqual(imp.angleDeg, delta, accuracy: abs(delta) * 1e-9 + 1e-12,
                           "round trip failed for \(delta)°")
            XCTAssertGreaterThanOrEqual(abs(imp.rateRadPerSec),
                                        GimbalConstants.velocityFloor - 1e-12,
                                        "rate below velocity floor for \(delta)°")
            XCTAssertLessThanOrEqual(abs(imp.rateRadPerSec),
                                     GimbalConstants.slewRate + 1e-12,
                                     "rate above slew rate for \(delta)°")
            XCTAssertLessThanOrEqual(imp.durationSeconds,
                                     GimbalConstants.velocityExpiry + 1e-9,
                                     "pulse outlives command expiry for \(delta)°")
            XCTAssertEqual(imp.rateRadPerSec >= 0, delta >= 0, "sign flipped for \(delta)°")
        }
    }

    func testImpulseMatchesBenchAnchor() {
        // Measured on hardware: 0.5° ≈ 0.05 rad/s × 175 ms.
        guard let imp = NudgePlanner.impulse(forDeltaDeg: 0.5) else {
            return XCTFail("no impulse for the canonical 0.5° nudge")
        }
        XCTAssertEqual(imp.rateRadPerSec, GimbalConstants.nudgeRate, accuracy: 1e-9)
        XCTAssertEqual(imp.durationSeconds, 0.1745, accuracy: 0.005)
    }

    func testImpulseTinyDeltaStretchesPulseAndRespectsFloor() {
        // 0.01° at the preferred rate would be a 3.5 ms blip — the solver must stretch
        // the pulse to the minimum duration by lowering the rate, never below the floor.
        guard let imp = NudgePlanner.impulse(forDeltaDeg: 0.01) else {
            return XCTFail("0.01° is above an encoder tick and must be solvable")
        }
        XCTAssertEqual(imp.durationSeconds, NudgePlanner.minImpulseDuration, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(imp.rateRadPerSec, GimbalConstants.velocityFloor - 1e-12)
        XCTAssertEqual(imp.angleDeg, 0.01, accuracy: 1e-9)
    }

    func testImpulseSubTickDeltaIsNil() {
        // Below half an encoder tick (0.00358°) nothing observable can happen.
        XCTAssertNil(NudgePlanner.impulse(forDeltaDeg: 0.003))
        XCTAssertNil(NudgePlanner.impulse(forDeltaDeg: -0.003))
        XCTAssertNil(NudgePlanner.impulse(forDeltaDeg: 0))
    }

    func testImpulseHugeDeltaIsCappedAtExpiry() {
        // 100° cannot fit in one watchdog window even at full slew rate:
        // the solver saturates (slewRate × velocityExpiry ≈ 40.1°) and callers chain.
        guard let imp = NudgePlanner.impulse(forDeltaDeg: 100) else {
            return XCTFail("large deltas must still produce a (partial) impulse")
        }
        XCTAssertEqual(imp.durationSeconds, GimbalConstants.velocityExpiry, accuracy: 1e-9)
        XCTAssertEqual(abs(imp.rateRadPerSec), GimbalConstants.slewRate, accuracy: 1e-12)
        XCTAssertLessThan(imp.angleDeg, 100)
        XCTAssertGreaterThan(imp.angleDeg, 40)
    }

    // MARK: - Nudge decision

    func testShouldNudgeOnDriftTarget() {
        XCTAssertTrue(NudgePlanner.shouldNudge(
            accumulatedDriftDeg: GimbalConstants.nudgeTargetDeg, elapsedSinceLastNudge: 0))
        XCTAssertTrue(NudgePlanner.shouldNudge(
            accumulatedDriftDeg: GimbalConstants.nudgeTargetDeg + 0.2, elapsedSinceLastNudge: 10))
    }

    func testShouldNudgeOnCadence() {
        XCTAssertTrue(NudgePlanner.shouldNudge(
            accumulatedDriftDeg: 0.1, elapsedSinceLastNudge: GimbalConstants.nudgeCadence))
    }

    func testShouldNotNudgeEarly() {
        XCTAssertFalse(NudgePlanner.shouldNudge(accumulatedDriftDeg: 0, elapsedSinceLastNudge: 0))
        XCTAssertFalse(NudgePlanner.shouldNudge(
            accumulatedDriftDeg: GimbalConstants.nudgeTargetDeg - 0.01,
            elapsedSinceLastNudge: GimbalConstants.nudgeCadence - 1))
    }

    // MARK: - Drift accumulation since last nudge

    func testDriftTrackerAccumulatesAndResets() {
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var tracker = DriftTracker(startedAt: t0)

        // Equator, due east: pure altitude drift at ω = 4.178066e-3 deg/s.
        tracker.update(altDeg: 30, azDeg: 90, latitudeDeg: 0, at: t0.addingTimeInterval(55))
        tracker.update(altDeg: 30, azDeg: 90, latitudeDeg: 0, at: t0.addingTimeInterval(110))

        // 110 s × ω = 0.45959° (hand-computed), all in altitude.
        XCTAssertEqual(tracker.accumulatedAltDeg, 0.45959, accuracy: 0.45959 * 0.05)
        XCTAssertEqual(tracker.accumulatedAzDeg, 0, accuracy: 1e-6)
        XCTAssertEqual(tracker.accumulatedMagnitudeDeg, 0.45959, accuracy: 0.45959 * 0.05)

        // Cadence (110 s) has elapsed → nudge is due even though drift < 0.5°.
        XCTAssertTrue(tracker.shouldNudge(at: t0.addingTimeInterval(110)))

        // The correction follows the sky: same sign as the drift.
        XCTAssertGreaterThan(tracker.correctionDeltaDeg.pitch, 0)

        // After the nudge everything resets.
        tracker.markNudged(at: t0.addingTimeInterval(110))
        XCTAssertEqual(tracker.accumulatedMagnitudeDeg, 0)
        XCTAssertFalse(tracker.shouldNudge(at: t0.addingTimeInterval(111)))
    }

    func testDriftTrackerIgnoresOutOfOrderUpdates() {
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)
        var tracker = DriftTracker(startedAt: t0)
        tracker.update(altDeg: 30, azDeg: 90, latitudeDeg: 0, at: t0.addingTimeInterval(-10))
        XCTAssertEqual(tracker.accumulatedMagnitudeDeg, 0)
    }

    // MARK: - Cable-wrap accumulation

    func testCableWrapAccumulatesAcrossWrapBoundaries() {
        var wrap = CableWrapAccumulator()
        wrap.recordYawSample(0)
        // A full positive turn reported through a ±180°-wrapped encoder:
        // 0 → 120 → −120 → 0 is three shortest-path steps of +120°.
        for sample in [120.0, -120.0, 0.0] { wrap.recordYawSample(sample) }
        XCTAssertEqual(wrap.netPanDeg, 360, accuracy: 1e-9)
        XCTAssertFalse(wrap.isPastBudget, "±360° exactly is at budget, not past it")

        wrap.recordYawSample(120)
        XCTAssertEqual(wrap.netPanDeg, 480, accuracy: 1e-9)
        XCTAssertTrue(wrap.isPastBudget, "past +360° must warn")
    }

    func testCableWrapNegativeDirection() {
        var wrap = CableWrapAccumulator()
        wrap.recordYawSample(0)
        for sample in [-120.0, 120.0, 0.0, -120.0] { wrap.recordYawSample(sample) }
        XCTAssertEqual(wrap.netPanDeg, -480, accuracy: 1e-9)
        XCTAssertTrue(wrap.isPastBudget, "past −360° must warn too")
    }

    func testCableWrapResetKeepsTrackingContinuity() {
        var wrap = CableWrapAccumulator()
        wrap.recordYawSample(0)
        wrap.recordYawSample(120)
        wrap.reset()
        XCTAssertEqual(wrap.netPanDeg, 0)
        XCTAssertFalse(wrap.isPastBudget)
        // The last sample (120°) is retained, so the next delta is measured from there.
        wrap.recordYawSample(0)
        XCTAssertEqual(wrap.netPanDeg, -120, accuracy: 1e-9)
    }

    // MARK: - Pitch envelope clamp

    func testPitchEnvelopeBounds() {
        XCTAssertTrue(PitchEnvelope.isWithin(GimbalConstants.pitchMinDeg))
        XCTAssertTrue(PitchEnvelope.isWithin(GimbalConstants.pitchMaxDeg))
        XCTAssertTrue(PitchEnvelope.isWithin(0))
        XCTAssertFalse(PitchEnvelope.isWithin(GimbalConstants.pitchMaxDeg + 0.1))
        XCTAssertFalse(PitchEnvelope.isWithin(GimbalConstants.pitchMinDeg - 0.1))
    }

    func testPitchEnvelopeMoveRefusal() {
        // From +20°, another +10° would hit +30° — beyond the +27.5° hardware limit.
        XCTAssertFalse(PitchEnvelope.allowsMove(fromDeg: 20, deltaDeg: 10))
        // From +20°, −50° lands at −30° — inside the −38.4° floor.
        XCTAssertTrue(PitchEnvelope.allowsMove(fromDeg: 20, deltaDeg: -50))
        // From 0°, −40° lands at −40° — below the floor, refused.
        XCTAssertFalse(PitchEnvelope.allowsMove(fromDeg: 0, deltaDeg: -40))
    }

    func testPitchEnvelopeClampedValues() {
        XCTAssertEqual(PitchEnvelope.clamped(50), GimbalConstants.pitchMaxDeg, accuracy: 1e-12)
        XCTAssertEqual(PitchEnvelope.clamped(-50), GimbalConstants.pitchMinDeg, accuracy: 1e-12)
        XCTAssertEqual(PitchEnvelope.clamped(10), 10, accuracy: 1e-12)
    }
}
