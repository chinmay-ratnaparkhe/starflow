import Foundation

// MARK: - FramingGuide
//
// Pure math for the Aim-phase framing overlay: where does a celestial target
// (the Milky Way core, the Moon) sit relative to the frame center, given where
// the camera currently points?
//
// Inputs come from the same sources Aim Assist already trusts — the camera
// attitude (compass azimuth + gravity altitude, `AimAssist.readAttitude`) and a
// `SkyEngine`-resolved target — so the guidance inherits the documented ±10°
// compass accuracy budget. The main camera's 73° field of view means even a
// worst-case reading still points the user the right way.
//
// No CoreMotion, no clocks, no globals here: everything is unit-tested in
// Tests/MilkyWaySessionPolishTests.swift. The UI layer (SessionView) owns the
// sensor polling and degrades gracefully when motion data is unavailable.

public enum FramingGuide {

    /// Angular offset of the target from the frame center, in screen-intuitive
    /// axes: `rightDeg` positive when the target sits right of center (pan
    /// right to center it), `upDeg` positive when it sits above (tilt up).
    /// The azimuth arc is foreshortened by cos(target altitude) — the same
    /// small-angle treatment `AimAssist.pointingErrorDeg` uses, good far from
    /// the zenith, which is all the gimbal's pitch envelope can reach anyway.
    public struct Offset: Equatable, Sendable {
        public var rightDeg: Double
        public var upDeg: Double
        public init(rightDeg: Double, upDeg: Double) {
            self.rightDeg = rightDeg; self.upDeg = upDeg
        }
        /// Total angular separation from frame center (deg).
        public var separationDeg: Double {
            (rightDeg * rightDeg + upDeg * upDeg).squareRoot()
        }
    }

    /// Inside this separation the target counts as centered — well under the
    /// compass noise floor, so the copy never chases sensor jitter.
    public static let centeredWithinDeg: Double = 3.0

    /// Pure offset: camera pointing (horizon coordinates, 0 = N / 90 = E) →
    /// target position, wrapped through the shortest azimuth path so a camera
    /// at 350° and a target at 10° reads as 20° right, never 340° left.
    public static func offset(cameraAzimuthDeg: Double, cameraAltitudeDeg: Double,
                              target: HorizontalCoord) -> Offset {
        let dAz = CableWrapAccumulator.shortestDeltaDeg(from: cameraAzimuthDeg,
                                                        to: target.azimuthDeg)
        let right = dAz * cos(target.altitudeDeg * .pi / 180.0)
        let up = target.altitudeDeg - cameraAltitudeDeg
        return Offset(rightDeg: right, upDeg: up)
    }

    /// Human guidance line: "Core: 12° left", "Core: 8° right, 5° down", or the
    /// centered confirmation. Components under half a degree are dropped rather
    /// than shown as "0°".
    public static func guidanceLine(offset: Offset, targetName: String) -> String {
        guard offset.separationDeg >= centeredWithinDeg else {
            return "\(targetName) centered — hold this framing."
        }
        var parts: [String] = []
        let right = Int(abs(offset.rightDeg).rounded())
        let up = Int(abs(offset.upDeg).rounded())
        if right >= 1 { parts.append("\(right)° \(offset.rightDeg >= 0 ? "right" : "left")") }
        if up >= 1 { parts.append("\(up)° \(offset.upDeg >= 0 ? "up" : "down")") }
        guard !parts.isEmpty else {
            return "\(targetName) centered — hold this framing."
        }
        return "\(targetName): " + parts.joined(separator: ", ")
    }

    /// Screen rotation for a "point that way" arrow: 0° = straight up,
    /// clockwise positive (90° = right). Nil when the target is centered —
    /// an arrow with nowhere to point should not be drawn.
    public static func arrowAngleDeg(offset: Offset) -> Double? {
        guard offset.separationDeg >= centeredWithinDeg else { return nil }
        var angle = atan2(offset.rightDeg, offset.upDeg) * 180.0 / .pi
        if angle < 0 { angle += 360.0 }
        return angle
    }
}
