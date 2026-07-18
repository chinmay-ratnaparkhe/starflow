import Foundation
import CoreGraphics

// MARK: - Measured hardware constants (bench runs 1–3, Flow 2 Pro fw 5.50.80)

public enum GimbalConstants {
    /// Velocity commands auto-expire after ~2.6 s; re-issue within this interval for sustained motion.
    public static let velocityExpiry: TimeInterval = 2.0
    /// Minimum executable angular velocity (rad/s). Below this the motors do not move.
    public static let velocityFloor: Double = 2e-3
    /// Standard slew rate (rad/s) for GoTo moves.
    public static let slewRate: Double = 0.35
    /// Nudge rate (rad/s) for fine framing impulses.
    public static let nudgeRate: Double = 0.05
    /// Open-loop impulse accuracy (deg, 1σ) — closed loop corrects the residual.
    public static let impulseSigmaDeg: Double = 0.15
    /// Post-motion settle: wait until |ω| < this (rad/s) across 3 fresh encoder samples.
    public static let settleThreshold: Double = 2e-4
    public static let settleTimeout: TimeInterval = 6.0
    /// Encoder feed ~4 Hz, quantized to 0.00716° per tick.
    public static let encoderRateHz: Double = 4.0
    public static let encoderTickDeg: Double = 0.00716
    /// Keepalive micro-pulse period to defeat firmware inactivity sleep during capture gaps.
    public static let keepalivePeriod: TimeInterval = 15.0
    /// Undock debounce before surfacing an interruption to the user.
    public static let flapDebounce: TimeInterval = 15.0
    /// DockKit-commandable pitch envelope (deg).
    public static let pitchMinDeg: Double = -38.4
    public static let pitchMaxDeg: Double = 27.5
    /// Sidereal rate (rad/s) — used for drift feed-forward math, NOT commandable.
    public static let siderealRate: Double = 7.2921e-5
    /// Sky drift (deg/min) worst case; drives the nudge cadence.
    public static let skyDriftDegPerMin: Double = 0.2507
    /// Target nudge size and cadence for framing retention.
    public static let nudgeTargetDeg: Double = 0.5
    public static let nudgeCadence: TimeInterval = 110
}

// MARK: - Sky types

public struct GeoLocation: Equatable, Sendable {
    public var latitude: Double   // deg, +N
    public var longitude: Double  // deg, +E
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude; self.longitude = longitude
    }
}

public struct HorizontalCoord: Equatable, Sendable {
    public var altitudeDeg: Double
    public var azimuthDeg: Double   // 0 = N, 90 = E
    public init(altitudeDeg: Double, azimuthDeg: Double) {
        self.altitudeDeg = altitudeDeg; self.azimuthDeg = azimuthDeg
    }
}

public struct EquatorialCoord: Equatable, Sendable {
    public var raHours: Double      // 0..24
    public var decDeg: Double       // -90..90
    public init(raHours: Double, decDeg: Double) {
        self.raHours = raHours; self.decDeg = decDeg
    }
}

public struct MoonInfo: Equatable, Sendable {
    public var illuminatedFraction: Double   // 0..1
    public var phaseName: String
    public var position: HorizontalCoord
    public init(illuminatedFraction: Double, phaseName: String, position: HorizontalCoord) {
        self.illuminatedFraction = illuminatedFraction; self.phaseName = phaseName; self.position = position
    }
}

/// Everything the Tonight screen and mode gates need about the sky right now / tonight.
public struct SkyContext: Sendable {
    public var date: Date
    public var location: GeoLocation
    public var sunAltitudeDeg: Double
    public var isAstronomicalDark: Bool
    public var darknessWindow: (start: Date, end: Date)?
    public var moon: MoonInfo
    public var milkyWayCore: HorizontalCoord
    public var coreVisibleTonight: Bool
    public var lstHours: Double
    public init(date: Date, location: GeoLocation, sunAltitudeDeg: Double, isAstronomicalDark: Bool,
                darknessWindow: (start: Date, end: Date)?, moon: MoonInfo,
                milkyWayCore: HorizontalCoord, coreVisibleTonight: Bool, lstHours: Double) {
        self.date = date; self.location = location; self.sunAltitudeDeg = sunAltitudeDeg
        self.isAstronomicalDark = isAstronomicalDark; self.darknessWindow = darknessWindow
        self.moon = moon; self.milkyWayCore = milkyWayCore
        self.coreVisibleTonight = coreVisibleTonight; self.lstHours = lstHours
    }
}

public protocol SkyComputing: Sendable {
    func greenwichMeanSiderealTime(date: Date) -> Double                      // hours 0..24
    func altAz(of coord: EquatorialCoord, at location: GeoLocation, date: Date) -> HorizontalCoord
    func sunAltitude(at location: GeoLocation, date: Date) -> Double          // deg
    func moonInfo(at location: GeoLocation, date: Date) -> MoonInfo
    func milkyWayCorePosition(at location: GeoLocation, date: Date) -> HorizontalCoord
    func skyContext(at location: GeoLocation, date: Date) -> SkyContext
}

// MARK: - Mount types

public enum MountAuthority: Equatable, Sendable { case unknown, granted, denied }

public enum MountConnection: Equatable, Sendable {
    case searching
    case docked(name: String)
    case flapping(since: Date)   // undocked, inside debounce window
    case undocked
}

public struct MountTelemetry: Equatable, Sendable {
    public var pitchDeg: Double
    public var yawDeg: Double
    public var speedDegPerSec: Double
    public var batteryPercent: Int?
    public init(pitchDeg: Double, yawDeg: Double, speedDegPerSec: Double, batteryPercent: Int?) {
        self.pitchDeg = pitchDeg; self.yawDeg = yawDeg
        self.speedDegPerSec = speedDegPerSec; self.batteryPercent = batteryPercent
    }
}

@MainActor
public protocol MountControlling: AnyObject {
    var connection: MountConnection { get }
    var authority: MountAuthority { get }
    var telemetry: MountTelemetry? { get }
    func start()
    func stopEverything() async                       // zero velocity, cancel plans — every exit path
    func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws
    func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws  // velocity impulse
    func waitSettled() async -> Bool
    func keepalivePulse() async
}

// MARK: - Capture & stacking types

public struct SubFrame: Sendable {
    public var index: Int
    public var timestamp: Date
    public var exposureSeconds: Double
    public var iso: Double
    public var pixelData: CGImage?
    public init(index: Int, timestamp: Date, exposureSeconds: Double, iso: Double, pixelData: CGImage?) {
        self.index = index; self.timestamp = timestamp
        self.exposureSeconds = exposureSeconds; self.iso = iso; self.pixelData = pixelData
    }
}

public struct StackResult: Sendable {
    public var accepted: Int
    public var rejected: Int
    public var integrationSeconds: Double
    public var preview: CGImage?
    public init(accepted: Int, rejected: Int, integrationSeconds: Double, preview: CGImage?) {
        self.accepted = accepted; self.rejected = rejected
        self.integrationSeconds = integrationSeconds; self.preview = preview
    }
}

public protocol Stacking: AnyObject {
    func reset(width: Int, height: Int)
    func add(frame: SubFrame) -> Bool                 // false = rejected (misaligned/cloudy)
    func currentResult() -> StackResult
    func finalImage() -> CGImage?
}

/// How a shot mode's sub-frames are combined into one image.
///  - registered:   star-align every frame against the reference before averaging
///                  (deep-sky stacks — needs actual stars in frame).
///  - trails:       lighten (per-pixel max) blend with no alignment — the sky's
///                  motion IS the shot (star trails).
///  - unregistered: plain running mean with no alignment (timelapse frames, scenes
///                  where registration has nothing to lock onto).
public enum StackingStyle: String, Equatable, Sendable {
    case registered
    case trails
    case unregistered
}

// MARK: - Shot modes

/// A sky target Aim Assist can slew to automatically during the Aim phase.
/// Raw values are stable strings so shot-mode definitions stay declarative.
public enum CelestialTarget: String, Sendable {
    case milkyWayCore
    case moon

    /// Human name as used in live status copy ("Aim Assist: slewing to the Milky Way…").
    public var displayName: String {
        switch self {
        case .milkyWayCore: return "the Milky Way"
        case .moon: return "the Moon"
        }
    }
}

public enum Feasibility: Equatable, Sendable {
    case great
    case possible(note: String)
    case notTonight(reason: String)
    case notWithPhone(reason: String)
}

public enum SkyQuality: Int, CaseIterable, Sendable {
    case city = 8, suburb = 6, rural = 4, dark = 2
    public var label: String {
        switch self {
        case .city: return "City (Bortle 8–9)"
        case .suburb: return "Suburbs (Bortle 5–7)"
        case .rural: return "Rural (Bortle 3–4)"
        case .dark: return "Dark site (Bortle 1–2)"
        }
    }
}

public struct CaptureRecipe: Sendable {
    public var exposureSeconds: Double     // ≤ 1.0 (hard cap)
    public var iso: Double
    public var targetSubCount: Int
    public var nudgeTracking: Bool         // step-and-shoot framing retention on
    public var intervalSeconds: Double     // 0 = back-to-back
    public init(exposureSeconds: Double, iso: Double, targetSubCount: Int,
                nudgeTracking: Bool, intervalSeconds: Double = 0) {
        self.exposureSeconds = min(exposureSeconds, 1.0)
        self.iso = iso; self.targetSubCount = targetSubCount
        self.nudgeTracking = nudgeTracking; self.intervalSeconds = intervalSeconds
    }
}

public struct TutorialStep: Identifiable, Sendable {
    public var id: Int
    public var title: String
    public var body: String
    public var symbol: String              // SF Symbol name
    public init(id: Int, title: String, body: String, symbol: String) {
        self.id = id; self.title = title; self.body = body; self.symbol = symbol
    }
}

public protocol ShotMode: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    var tagline: String { get }
    var symbol: String { get }
    var recipe: CaptureRecipe { get }
    var expectation: String { get }        // honest copy: what the result actually looks like
    var tutorial: [TutorialStep] { get }
    func feasibility(sky: SkyContext, quality: SkyQuality) -> Feasibility
}

// MARK: - Session engine

public enum SessionPhase: String, CaseIterable, Sendable {
    case connect = "Connect"
    case aim = "Aim"
    case calibrate = "Calibrate"
    case capture = "Capture"
    case develop = "Develop"
    case complete = "Complete"
}

public enum SessionInterruption: Equatable, Sendable {
    case authorityNeeded          // squeeze the trigger
    case gimbalFlapping           // undock inside debounce — auto-recovering
    case gimbalLost               // undock beyond debounce
    case thermalBackoff
    case thermalCritical
    case batteryLow(percent: Int)
    case storageLow
    case backgrounded
    case cameraDenied             // camera permission missing/denied — never go synthetic
}

public struct SessionStats: Sendable {
    public var subsAccepted: Int = 0
    public var subsRejected: Int = 0
    public var integrationSeconds: Double = 0
    public var nudges: Int = 0
    public var flapsRecovered: Int = 0
    public var startedAt: Date?
    /// How the phone was physically held in the clamp (CoreMotion gravity —
    /// the UI is portrait-locked, so interface orientation can't tell).
    /// Sampled at session start and re-sampled when the Capture phase begins;
    /// drives the develop-phase rotation that makes the final image upright.
    public var captureTilt: DeviceTilt = .portrait
    /// Last measured sky condition during capture (`SkyConditionMonitor`).
    /// `.unknown` when the monitor never saw enough starry frames to grade.
    /// Appended field with a default so the empty init keeps its meaning.
    public var skyCondition: SkyCondition = .unknown
    /// Frames captured but deliberately NOT stacked while the measured sky was
    /// cloudy (registered-stack cloud gate). Tracked apart from `subsRejected`
    /// so waiting out clouds never consumes the shot's planned sub count —
    /// the session extends instead (capped by `CloudTimeBudget`).
    /// Appended field with a default so the empty init keeps its meaning.
    public var subsSkippedClouds: Int = 0
    /// Of `subsSkippedClouds`, the plan slots clouds consumed for good AFTER
    /// the `CloudTimeBudget` extension was spent. Keeps
    /// `subsAccepted + subsRejected + subsLostToClouds` equal to the plan
    /// slots consumed, so progress math and the logbook's ended-early verdict
    /// stay exact. Appended field with a default so the empty init keeps its
    /// meaning.
    public var subsLostToClouds: Int = 0
    /// Corrective impulses fired by mid-session plate-solve drift cross-checks
    /// (feature 5 GoTo). Appended field with a default so the empty init keeps
    /// its meaning.
    public var driftCorrections: Int = 0
    public init() {}
}
