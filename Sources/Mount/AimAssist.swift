import Foundation
import CoreMotion

// MARK: - Errors

/// Failures specific to Aim Assist's sensing side. Mount-side failures reuse
/// `MountError` (`.notConnected`, `.noAuthority`, …) so callers handle one vocabulary.
public enum AimAssistError: LocalizedError, Equatable {
    case motionUnavailable      // no device-motion hardware (Simulator, unsupported device)
    case attitudeTimeout        // compass/attitude never produced a valid sample

    public var errorDescription: String? {
        switch self {
        case .motionUnavailable:
            return "Motion sensors aren't available here, so Aim Assist can't tell where the camera points."
        case .attitudeTimeout:
            return "Couldn't get a stable compass reading — frame the target by hand."
        }
    }
}

// MARK: - AimAssist

/// Compass-coarse automatic aiming: slews the gimbal until the phone's main camera
/// points at a celestial target (Milky Way core, Moon) computed by `SkyEngine`.
///
/// Accuracy budget (deliberate): the iPhone magnetometer is good to ~5–15° and the
/// main camera's field of view is 73°, so even a worst-case compass error still lands
/// the target inside the frame. Aim Assist gets the target *in frame*; the user
/// fine-tunes by hand.
///
/// Geometry assumptions (documented, not enforced):
/// - The phone rides the Flow 2 Pro clamp with the REAR camera facing the scene —
///   the camera looks along the device's −Z axis. This holds in any clamp
///   orientation (landscape or portrait) because the pointing math uses the full
///   attitude rotation matrix, not screen orientation.
/// - Azimuth is MAGNETIC (reference frame `.xMagneticNorthZVertical`); magnetic
///   declination is inside the accepted error budget and is not corrected.
/// - Camera altitude comes from gravity: with camera direction c = −Z_device,
///   sin(altitude) = c · up = gravity.z (CoreMotion gravity is (0,0,−1) face-up,
///   giving −90° — the rear camera does face the ground then).
@MainActor
public final class AimAssist {

    // MARK: Types

    /// Where the camera currently points, horizon coordinates (0 = N, 90 = E, magnetic).
    public struct Attitude: Equatable, Sendable {
        public var azimuthDeg: Double     // 0..360
        public var altitudeDeg: Double    // −90..+90, + above horizon
        public init(azimuthDeg: Double, altitudeDeg: Double) {
            self.azimuthDeg = azimuthDeg; self.altitudeDeg = altitudeDeg
        }
    }

    /// One planned gimbal move toward the target, pitch pre-clamped to the envelope.
    public struct SlewPlan: Equatable, Sendable {
        public var deltaYawDeg: Double
        public var deltaPitchDeg: Double
        /// True when the full move would exit the DockKit pitch envelope — the plan
        /// commands a partial aim and the caller should tell the user to tilt by hand.
        public var pitchClamped: Bool
        public init(deltaYawDeg: Double, deltaPitchDeg: Double, pitchClamped: Bool) {
            self.deltaYawDeg = deltaYawDeg; self.deltaPitchDeg = deltaPitchDeg
            self.pitchClamped = pitchClamped
        }
    }

    /// Result of a full aim: estimated residual pointing error and whether the pitch
    /// envelope truncated the vertical component.
    public struct Outcome: Equatable, Sendable {
        public var estimatedErrorDeg: Double
        public var pitchClamped: Bool
        public init(estimatedErrorDeg: Double, pitchClamped: Bool) {
            self.estimatedErrorDeg = estimatedErrorDeg; self.pitchClamped = pitchClamped
        }
    }

    /// Progress callback stages (drives the session status line).
    public enum Stage: Equatable, Sendable { case slewing, refining }

    // MARK: Dependencies

    private let sky: SkyComputing
    /// Lazy so the pure-math surface (resolve/plan) never touches CoreMotion —
    /// tests exercise those without any motion hardware.
    private lazy var motion = CMMotionManager()

    public init(sky: SkyComputing = SkyEngine()) {
        self.sky = sky
    }

    // MARK: - Target resolution (pure — delegates to SkyEngine)

    /// Current horizon coordinates of a celestial target for a location and instant.
    public func resolve(target: CelestialTarget, location: GeoLocation,
                        date: Date = Date()) -> HorizontalCoord {
        switch target {
        case .milkyWayCore:
            return sky.milkyWayCorePosition(at: location, date: date)
        case .moon:
            return sky.moonInfo(at: location, date: date).position
        }
    }

    // MARK: - Pure planning math (unit-tested, no CoreMotion)

    /// Signed shortest angular path from a current heading to a target azimuth,
    /// wrapped into (−180, 180] so the gimbal never takes the long way round.
    public static func shortestYawDeltaDeg(fromDeg: Double, toDeg: Double) -> Double {
        CableWrapAccumulator.shortestDeltaDeg(from: fromDeg, to: toDeg)
    }

    /// Plan one slew from the camera's current pointing to the target.
    ///
    /// Pitch is planned in the MOUNT frame: the commanded delta equals the camera
    /// altitude delta (the phone rides the head rigidly), and the resulting mount
    /// pitch is clamped into the measured DockKit envelope
    /// (`GimbalConstants.pitchMinDeg…pitchMaxDeg`). When clamping truncates the move,
    /// `pitchClamped` is true and the plan aims as high (or low) as the head can go.
    public static func plan(currentAzimuthDeg: Double, currentAltitudeDeg: Double,
                            mountPitchDeg: Double, target: HorizontalCoord) -> SlewPlan {
        let deltaYaw = shortestYawDeltaDeg(fromDeg: currentAzimuthDeg, toDeg: target.azimuthDeg)
        let desiredDeltaPitch = target.altitudeDeg - currentAltitudeDeg
        let desiredMountPitch = mountPitchDeg + desiredDeltaPitch
        let reachableMountPitch = PitchEnvelope.clamped(desiredMountPitch)
        return SlewPlan(deltaYawDeg: deltaYaw,
                        deltaPitchDeg: reachableMountPitch - mountPitchDeg,
                        pitchClamped: reachableMountPitch != desiredMountPitch)
    }

    /// Approximate angular pointing error (deg) from a camera attitude to a target
    /// (azimuth arc foreshortened by cos altitude — good far from the zenith, which
    /// is all the pitch envelope can reach anyway).
    public static func pointingErrorDeg(from attitude: Attitude, to target: HorizontalCoord) -> Double {
        let dAlt = target.altitudeDeg - attitude.altitudeDeg
        let dAz = shortestYawDeltaDeg(fromDeg: attitude.azimuthDeg, toDeg: target.azimuthDeg)
        let azArc = dAz * cos(target.altitudeDeg * .pi / 180.0)
        return (dAlt * dAlt + azArc * azArc).squareRoot()
    }

    /// Camera pointing from a CoreMotion attitude rotation matrix + gravity sample.
    ///
    /// Reference frame `.xMagneticNorthZVertical`: X = magnetic north, Z = up,
    /// Y = west (right-handed). The rear camera looks along device −Z.
    ///
    /// CoreMotion's matrix convention (device→reference vs reference→device) is
    /// easy to get backwards, so instead of trusting documentation we anchor on
    /// gravity: in device coordinates gravity must equal the matrix image of the
    /// reference "down" vector (0, 0, −1). Whichever convention reproduces the
    /// measured gravity vector is the one used to place the camera axis in the
    /// reference frame. Altitude is identical under both conventions (asin(−m33)).
    static func cameraAttitude(m11: Double, m12: Double, m13: Double,
                               m21: Double, m22: Double, m23: Double,
                               m31: Double, m32: Double, m33: Double,
                               gravityX: Double, gravityY: Double, gravityZ: Double) -> Attitude {
        // Hypothesis A — matrix maps device→reference (v_ref = R·v_dev):
        //   gravity_dev = Rᵀ·(0,0,−1) = (−m31, −m32, −m33), camera_ref = (−m13, −m23, −m33).
        // Hypothesis B — matrix maps reference→device (v_dev = R·v_ref):
        //   gravity_dev = R·(0,0,−1) = (−m13, −m23, −m33), camera_ref = (−m31, −m32, −m33).
        let dotA = gravityX * -m31 + gravityY * -m32 + gravityZ * -m33
        let dotB = gravityX * -m13 + gravityY * -m23 + gravityZ * -m33
        let camera: (x: Double, y: Double, z: Double) = dotA >= dotB
            ? (x: -m13, y: -m23, z: -m33)
            : (x: -m31, y: -m32, z: -m33)

        // north = +X, east = −Y (Y is west); azimuth 0 = N, 90 = E.
        var azimuthDeg = atan2(-camera.y, camera.x) * 180.0 / .pi
        if azimuthDeg < 0 { azimuthDeg += 360.0 }
        let altitudeDeg = asin(min(1.0, max(-1.0, camera.z))) * 180.0 / .pi
        return Attitude(azimuthDeg: azimuthDeg, altitudeDeg: altitudeDeg)
    }

    // MARK: - Attitude sensing (CoreMotion)

    /// Read where the camera points right now. Starts device motion updates with the
    /// `.xMagneticNorthZVertical` reference frame (heading 0..360 relative to magnetic
    /// north) and polls until a sample with a valid heading arrives.
    ///
    /// Throws `AimAssistError.motionUnavailable` where there is no motion hardware
    /// (Simulator) and `.attitudeTimeout` when the compass never stabilizes.
    public func readAttitude(timeout: TimeInterval = 3.0) async throws -> Attitude {
        guard motion.isDeviceMotionAvailable else { throw AimAssistError.motionUnavailable }
        if !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            // heading is −1 until the magnetic reference is established.
            if let dm = motion.deviceMotion, dm.heading >= 0 {
                let r = dm.attitude.rotationMatrix
                let g = dm.gravity
                return Self.cameraAttitude(m11: r.m11, m12: r.m12, m13: r.m13,
                                           m21: r.m21, m22: r.m22, m23: r.m23,
                                           m31: r.m31, m32: r.m32, m33: r.m33,
                                           gravityX: g.x, gravityY: g.y, gravityZ: g.z)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stopMotionUpdates()
        throw AimAssistError.attitudeTimeout
    }

    /// Stop device-motion updates (idempotent; called on every slew exit path).
    public func stopMotionUpdates() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    // MARK: - Slew to target

    /// Aim the camera at `target`: read attitude → plan → `mount.slew` →
    /// `mount.waitSettled()` → re-read and refine once (2 iterations total), then
    /// estimate the residual pointing error from a final attitude read.
    ///
    /// Mount-side preconditions are surfaced as `MountError` (`.notConnected` when
    /// not docked, `.noAuthority` when the trigger squeeze is missing) so callers
    /// handle Aim Assist exactly like any other mount command.
    @discardableResult
    public func slewToTarget(mount: MountControlling, to target: HorizontalCoord,
                             onStage: (@MainActor (Stage) -> Void)? = nil) async throws -> Outcome {
        guard case .docked = mount.connection else { throw MountError.notConnected }
        guard mount.authority == .granted else { throw MountError.noAuthority }
        defer { stopMotionUpdates() }

        var pitchClamped = false
        for iteration in 0..<2 {
            onStage?(iteration == 0 ? .slewing : .refining)
            let attitude = try await readAttitude()
            let mountPitch = mount.telemetry?.pitchDeg ?? 0
            let plan = Self.plan(currentAzimuthDeg: attitude.azimuthDeg,
                                 currentAltitudeDeg: attitude.altitudeDeg,
                                 mountPitchDeg: mountPitch,
                                 target: target)
            pitchClamped = pitchClamped || plan.pitchClamped
            // Refinement below the compass noise floor is chasing sensor jitter — stop.
            if iteration > 0, abs(plan.deltaYawDeg) < 1.0, abs(plan.deltaPitchDeg) < 1.0 { break }
            try await mount.slew(deltaPitchDeg: plan.deltaPitchDeg, deltaYawDeg: plan.deltaYawDeg)
            _ = await mount.waitSettled()
        }

        let final = try await readAttitude()
        return Outcome(estimatedErrorDeg: Self.pointingErrorDeg(from: final, to: target),
                       pitchClamped: pitchClamped)
    }
}
