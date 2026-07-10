import Foundation

/// Pure-math planning for step-and-shoot framing retention.
///
/// The Flow 2 Pro cannot track continuously (velocity floor ≈ 2e-3 rad/s is ~27× sidereal),
/// so StarFlow parks the gimbal, lets the sky drift, and periodically fires a small
/// velocity impulse to re-center the frame. Everything in this file is pure Swift —
/// no DockKit, no side effects — so it is unit-testable on any platform.
public enum NudgePlanner {

    // MARK: Drift feed-forward

    /// Instantaneous alt-az drift rates of a fixed sky target, in deg/s.
    ///
    /// From the standard diurnal-motion derivatives (azimuth measured 0 = N, 90 = E):
    ///   dAlt/dt = ω · cos(lat) · sin(Az)
    ///   dAz/dt  = ω · (sin(lat) − cos(lat) · cos(Az) · tan(Alt))
    /// with ω = `GimbalConstants.siderealRate`. Worst case |dAlt/dt| = ω ≈ 0.2507 deg/min,
    /// which is exactly `GimbalConstants.skyDriftDegPerMin`.
    public struct DriftRates: Equatable, Sendable {
        public var altDegPerSec: Double
        public var azDegPerSec: Double
        public var magnitudeDegPerSec: Double {
            (altDegPerSec * altDegPerSec + azDegPerSec * azDegPerSec).squareRoot()
        }
        public init(altDegPerSec: Double, azDegPerSec: Double) {
            self.altDegPerSec = altDegPerSec
            self.azDegPerSec = azDegPerSec
        }
    }

    /// Drift rates for a target currently at (altDeg, azDeg) seen from latitudeDeg.
    /// Altitude is clamped to ±89.5° before the tangent so near-zenith targets do not
    /// blow up numerically (the session engine refuses zenith targets anyway).
    public static func driftRates(altDeg: Double, azDeg: Double, latitudeDeg: Double) -> DriftRates {
        let omegaDegPerSec = GimbalConstants.siderealRate * 180.0 / .pi
        let lat = latitudeDeg * .pi / 180.0
        let az = azDeg * .pi / 180.0
        let clampedAlt = min(max(altDeg, -89.5), 89.5) * .pi / 180.0
        let dAlt = omegaDegPerSec * cos(lat) * sin(az)
        let dAz = omegaDegPerSec * (sin(lat) - cos(lat) * cos(az) * tan(clampedAlt))
        return DriftRates(altDegPerSec: dAlt, azDegPerSec: dAz)
    }

    // MARK: Nudge decision

    /// Nudge when the accumulated drift has reached the target step size, or when the
    /// cadence timer has elapsed (whichever comes first) — per the measured 90–120 s rhythm.
    public static func shouldNudge(accumulatedDriftDeg: Double,
                                   elapsedSinceLastNudge: TimeInterval) -> Bool {
        accumulatedDriftDeg >= GimbalConstants.nudgeTargetDeg
            || elapsedSinceLastNudge >= GimbalConstants.nudgeCadence
    }

    // MARK: Impulse solver

    /// A single velocity impulse: commanded angle = rate × duration.
    /// Bench anchor: 0.5° ≈ 0.05 rad/s × 175 ms (±0.15° open loop).
    public struct Impulse: Equatable, Sendable {
        /// Signed angular rate, rad/s. |rate| is always ≥ `GimbalConstants.velocityFloor`.
        public var rateRadPerSec: Double
        /// Pulse length, s. Always ≤ `GimbalConstants.velocityExpiry`.
        public var durationSeconds: TimeInterval
        /// The angle this impulse actually commands (deg, signed).
        public var angleDeg: Double {
            rateRadPerSec * durationSeconds * 180.0 / .pi
        }
        public init(rateRadPerSec: Double, durationSeconds: TimeInterval) {
            self.rateRadPerSec = rateRadPerSec
            self.durationSeconds = durationSeconds
        }
    }

    /// Shortest pulse the firmware executes reliably; below this the rate is lowered instead.
    public static let minImpulseDuration: TimeInterval = 0.05

    /// Solve a signed angular delta (deg) into one velocity impulse.
    ///
    /// Rules, in order:
    /// - Deltas below half an encoder tick are unobservable → nil (nothing to do).
    /// - Start from the preferred rate (default `GimbalConstants.nudgeRate`), clamped
    ///   into [`velocityFloor`, `maxRateRadPerSec`].
    /// - If the pulse would be shorter than `minImpulseDuration`, lower the rate
    ///   (never below the floor) and stretch the pulse.
    /// - If the pulse would outlive the firmware command watchdog (`velocityExpiry`),
    ///   raise the rate toward `maxRateRadPerSec`. If the delta still doesn't fit,
    ///   the duration is capped at `velocityExpiry` and the impulse commands less than
    ///   requested — callers chain impulses (or use a slew) for large moves.
    public static func impulse(forDeltaDeg deltaDeg: Double,
                               preferredRateRadPerSec: Double = GimbalConstants.nudgeRate,
                               maxRateRadPerSec: Double = GimbalConstants.slewRate) -> Impulse? {
        guard abs(deltaDeg) >= GimbalConstants.encoderTickDeg / 2.0 else { return nil }
        let sign: Double = deltaDeg < 0 ? -1.0 : 1.0
        let angleRad = abs(deltaDeg) * .pi / 180.0

        var rate = min(max(preferredRateRadPerSec, GimbalConstants.velocityFloor), maxRateRadPerSec)
        var duration = angleRad / rate

        if duration < minImpulseDuration {
            rate = max(angleRad / minImpulseDuration, GimbalConstants.velocityFloor)
            duration = angleRad / rate
        } else if duration > GimbalConstants.velocityExpiry {
            rate = min(angleRad / GimbalConstants.velocityExpiry, maxRateRadPerSec)
            duration = min(angleRad / rate, GimbalConstants.velocityExpiry)
        }
        return Impulse(rateRadPerSec: rate * sign, durationSeconds: duration)
    }
}

// MARK: - Drift accumulator

/// Integrates sky drift between nudges and answers "is it time to nudge, and by how much".
/// Feed it the target's current alt/az at any convenient rate (each capture gap works);
/// it accumulates rate × dt since the last nudge.
public struct DriftTracker: Equatable, Sendable {
    public private(set) var accumulatedAltDeg: Double = 0
    public private(set) var accumulatedAzDeg: Double = 0
    public private(set) var lastNudgeAt: Date
    private var lastUpdateAt: Date

    public init(startedAt: Date = Date()) {
        lastNudgeAt = startedAt
        lastUpdateAt = startedAt
    }

    public var accumulatedMagnitudeDeg: Double {
        (accumulatedAltDeg * accumulatedAltDeg + accumulatedAzDeg * accumulatedAzDeg).squareRoot()
    }

    /// Accumulate drift from the last update to `date` using the rates at the target's
    /// current position. Out-of-order dates are ignored.
    public mutating func update(altDeg: Double, azDeg: Double, latitudeDeg: Double,
                                at date: Date = Date()) {
        let dt = date.timeIntervalSince(lastUpdateAt)
        guard dt > 0 else { return }
        let rates = NudgePlanner.driftRates(altDeg: altDeg, azDeg: azDeg, latitudeDeg: latitudeDeg)
        accumulatedAltDeg += rates.altDegPerSec * dt
        accumulatedAzDeg += rates.azDegPerSec * dt
        lastUpdateAt = date
    }

    public func shouldNudge(at date: Date = Date()) -> Bool {
        NudgePlanner.shouldNudge(accumulatedDriftDeg: accumulatedMagnitudeDeg,
                                 elapsedSinceLastNudge: date.timeIntervalSince(lastNudgeAt))
    }

    /// The corrective move that re-centers the frame: the mount follows the sky,
    /// so the correction equals the accumulated drift (pitch ↦ altitude, yaw ↦ azimuth).
    public var correctionDeltaDeg: (pitch: Double, yaw: Double) {
        (accumulatedAltDeg, accumulatedAzDeg)
    }

    /// Call after the corrective nudge has been commanded.
    public mutating func markNudged(at date: Date = Date()) {
        accumulatedAltDeg = 0
        accumulatedAzDeg = 0
        lastNudgeAt = date
        lastUpdateAt = date
    }
}

// MARK: - Pitch envelope

/// The DockKit-commandable pitch window measured on hardware: −38.4° … +27.5°.
/// Targets outside it are refused, never silently clamped mid-session.
public enum PitchEnvelope {
    public static func isWithin(_ pitchDeg: Double) -> Bool {
        pitchDeg >= GimbalConstants.pitchMinDeg && pitchDeg <= GimbalConstants.pitchMaxDeg
    }

    public static func allowsMove(fromDeg: Double, deltaDeg: Double) -> Bool {
        isWithin(fromDeg + deltaDeg)
    }

    public static func clamped(_ pitchDeg: Double) -> Double {
        min(max(pitchDeg, GimbalConstants.pitchMinDeg), GimbalConstants.pitchMaxDeg)
    }
}

// MARK: - Cable-wrap accumulator

/// Tracks net pan since session start (or last reset) so a phone cable or long session
/// never winds the yaw axis past a full turn. Feed it raw encoder yaw samples — it
/// unwraps them via shortest-path deltas, so both wrapped (±180°) and continuous
/// encoder conventions work.
public struct CableWrapAccumulator: Equatable, Sendable {
    public private(set) var netPanDeg: Double = 0
    private var lastYawDeg: Double?

    public init() {}

    /// Warn once net pan exceeds a full turn in either direction.
    public static let budgetDeg: Double = 360.0

    public var isPastBudget: Bool { abs(netPanDeg) > Self.budgetDeg }

    /// Signed shortest angular path from one yaw reading to the next, in (−180, 180].
    public static func shortestDeltaDeg(from: Double, to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360.0)
        if d > 180.0 { d -= 360.0 } else if d < -180.0 { d += 360.0 }
        return d
    }

    public mutating func recordYawSample(_ yawDeg: Double) {
        if let last = lastYawDeg {
            netPanDeg += Self.shortestDeltaDeg(from: last, to: yawDeg)
        }
        lastYawDeg = yawDeg
    }

    /// Zero the accumulator (e.g. after the user physically unwinds the setup).
    /// The last yaw sample is kept so tracking continues seamlessly.
    public mutating func reset() {
        netPanDeg = 0
    }
}
