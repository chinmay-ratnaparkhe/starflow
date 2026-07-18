import Foundation
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - SessionHooks
//
// Injectable seams around everything the session engine touches that isn't the mount
// or the stacker: capture, guardians (thermal / battery / storage), nudge feed-forward,
// and time. Tests inject fast fakes; the app can install a CaptureEngine-backed set by
// replacing `SessionEngine.defaultHooksProvider` at assembly time.

public struct SessionHooks {
    /// Prepare the capture pipeline for a recipe; returns frame dimensions for the stacker.
    public var prepareCapture: (CaptureRecipe) async throws -> (width: Int, height: Int)
    /// Capture one sub-exposure (index is 0-based within the session).
    public var captureSub: (CaptureRecipe, Int) async throws -> SubFrame
    /// Tear the capture pipeline down (called on every exit path).
    public var endCapture: () async -> Void
    /// Guardians.
    public var thermalState: @MainActor () -> ProcessInfo.ThermalState
    public var batteryPercent: @MainActor () -> Int?
    public var freeDiskBytes: @MainActor () -> Int64?
    /// Drift feed-forward vector for one framing nudge (deg). The Sky/Mount integration
    /// can install a target-aware vector; the default compensates the measured worst-case
    /// sky drift along yaw.
    public var nudgeVector: @MainActor () -> (deltaPitchDeg: Double, deltaYawDeg: Double)
    /// Clock + scheduler seams (tests compress time here).
    public var now: @MainActor () -> Date
    public var sleep: (TimeInterval) async throws -> Void
    /// Storage pre-flight seam: bytes each captured sub is expected to write. Defaults
    /// to the StorageBudget estimate honoring the "Keep RAW subs" setting; declared
    /// with a default so the memberwise init above keeps its signature.
    public var estimatedBytesPerFrame: @MainActor (CaptureRecipe) -> Int64 = { recipe in
        StorageBudget.estimatedBytesPerFrame(
            recipe: recipe, keepingSubs: UserDefaults.standard.bool(forKey: "keepSubs"))
    }
    /// True when the capture closures synthesize frames instead of driving real camera
    /// hardware (simulator builds only). The UI badges everything derived from a
    /// simulated source with a "SIMULATED" pill so fake stars can never masquerade as
    /// real data. Declared with a default so the memberwise init keeps its signature.
    public var isSimulatedCapture: Bool = false
    /// Physical device tilt seam (CoreMotion gravity — the UI is portrait-locked,
    /// so interface orientation is useless in the gimbal clamp). The engine warms
    /// this up at session start and takes the authoritative sample when Capture
    /// begins; the develop phase rotates the final image upright accordingly.
    /// Declared with a default so the memberwise init keeps its signature.
    public var captureTilt: @MainActor () -> DeviceTilt = {
        GravityTiltProvider.shared.sampleTilt()
    }
    /// Focus-sweep seams (see FocusSweep.swift), all declared with defaults so
    /// the memberwise init keeps its signature:
    ///  - `setLensPosition` moves the capture lens (1.0 = infinity end). Device
    ///    builds drive the real AVCaptureDevice via `CaptureEngine`; the default
    ///    is a no-op so injected test hooks stay minimal.
    ///  - `focusScore` grades one frame's star sharpness (higher = sharper).
    ///    The default runs the real variance-of-Laplacian metric; simulator
    ///    builds override it with `FocusSweepSimulator` because synthetic
    ///    frames never defocus.
    ///  - `focusTelemetry` feeds the session's live focus chip (latest
    ///    sharpness, rolling mean, drift alarm) once per captured sub.
    public var setLensPosition: @MainActor (Float) async -> Void = { _ in }
    public var focusScore: @MainActor (SubFrame) -> Double? = { frame in
        frame.pixelData.flatMap { FocusMetric.sharpness(of: $0) }
    }
    public var focusTelemetry: @MainActor () -> (sharpness: Double?, mean: Double?, drifting: Bool)
        = { (nil, nil, false) }
    /// Plate-solve GoTo seams (feature 5), declared with defaults so the
    /// memberwise init keeps its signature:
    ///  - `detectStarField` extracts star centroids (brightest-first) from one
    ///    captured frame at native resolution — the CPUStacker detection path.
    ///    Nil when the frame can't be decoded (treated as zero stars).
    ///  - `solveStarField` plate-solves a detected field against the embedded
    ///    bright-star catalog given a rough horizontal FOV (deg). Simulator
    ///    tests inject synthetic solvable fields / scripted solutions here;
    ///    device builds run the real solver — no device-camera path exists
    ///    outside the capture seams above.
    public var detectStarField: @MainActor (SubFrame) -> GoToController.StarField? = { frame in
        guard let image = frame.pixelData else { return nil }
        let width = image.width, height = image.height
        guard let gray = CPUStacker.grayscaleFloats(from: image, width: width, height: height)
        else { return nil }
        let stars = CPUStacker.detectStars(in: gray, width: width, height: height)
        return GoToController.StarField(centroids: stars.map { CGPoint(x: $0.x, y: $0.y) },
                                        imageSize: CGSize(width: width, height: height))
    }
    public var solveStarField: @MainActor (GoToController.StarField, Double) -> PlateSolver.Solution?
        = { field, fovDeg in
            PlateSolver.shared.solve(centroids: field.centroids, imageSize: field.imageSize,
                                     fovEstimateDeg: fovDeg)
        }

    public init(prepareCapture: @escaping (CaptureRecipe) async throws -> (width: Int, height: Int),
                captureSub: @escaping (CaptureRecipe, Int) async throws -> SubFrame,
                endCapture: @escaping () async -> Void,
                thermalState: @escaping @MainActor () -> ProcessInfo.ThermalState,
                batteryPercent: @escaping @MainActor () -> Int?,
                freeDiskBytes: @escaping @MainActor () -> Int64?,
                nudgeVector: @escaping @MainActor () -> (deltaPitchDeg: Double, deltaYawDeg: Double),
                now: @escaping @MainActor () -> Date,
                sleep: @escaping (TimeInterval) async throws -> Void) {
        self.prepareCapture = prepareCapture
        self.captureSub = captureSub
        self.endCapture = endCapture
        self.thermalState = thermalState
        self.batteryPercent = batteryPercent
        self.freeDiskBytes = freeDiskBytes
        self.nudgeVector = nudgeVector
        self.now = now
        self.sleep = sleep
    }
}

public extension SessionHooks {

    /// Default hooks. Guardians read real system state on every platform.
    ///
    /// Capture routing (the rule that keeps field sessions honest):
    ///  - DEVICE builds drive the REAL bench-proven `CaptureEngine` through
    ///    `CaptureEngineBridge` — permission is ensured at session start (reusing the
    ///    onboarding grant, or prompting on first use), the AVCaptureSession runs for
    ///    exactly the Capture→Develop window (iOS shows the green camera dot), and every
    ///    SubFrame carries a real sensor CGImage. There is NO synthetic fallback here;
    ///    if the camera can't run, the error surfaces as a session interruption.
    ///  - SIMULATOR builds (no camera hardware exists) synthesize drifting starfield
    ///    frames and set `isSimulatedCapture` so the UI badges everything "SIMULATED".
    static func live() -> SessionHooks {
        #if targetEnvironment(simulator)
        var hooks = SessionHooks(
            prepareCapture: { _ in (SessionHooks.syntheticSize, SessionHooks.syntheticSize) },
            captureSub: { recipe, index in
                // Pace the synthetic capture like a real exposure so the session feels honest.
                let ns = UInt64(max(0.05, recipe.exposureSeconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
                return SessionHooks.syntheticFrame(recipe: recipe, index: index)
            },
            endCapture: {},
            thermalState: { ProcessInfo.processInfo.thermalState },
            batteryPercent: { SessionHooks.systemBatteryPercent() },
            freeDiskBytes: { SessionHooks.systemFreeDiskBytes() },
            nudgeVector: {
                // Worst-case measured sky drift, fed forward along yaw once per cadence.
                let yaw = GimbalConstants.skyDriftDegPerMin * GimbalConstants.nudgeCadence / 60.0
                return (deltaPitchDeg: 0, deltaYawDeg: yaw)
            },
            now: { Date() },
            sleep: { seconds in
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            })
        hooks.isSimulatedCapture = true
        // Simulator focus model: synthetic starfield frames never defocus, so a
        // shared `FocusSweepSimulator` simulates the sharpness peak the sweep
        // hunts for, and feeds the live focus chip through the same telemetry
        // code path the device uses.
        let focusSim = FocusSweepSimulator()
        hooks.setLensPosition = { position in focusSim.setLens(Double(position)) }
        hooks.focusScore = { _ in focusSim.score() }
        hooks.focusTelemetry = { focusSim.tick() }
        return hooks
        #else
        var hooks = SessionHooks(
            prepareCapture: { recipe in
                try await CaptureEngineBridge.prepare(recipe: recipe)
            },
            captureSub: { recipe, index in
                try await CaptureEngineBridge.captureSub(recipe: recipe, index: index)
            },
            endCapture: {
                await CaptureEngineBridge.teardown()
                // Stop gravity sampling with the camera — every exit path lands here.
                await GravityTiltProvider.shared.stopUpdates()
            },
            thermalState: { ProcessInfo.processInfo.thermalState },
            batteryPercent: { SessionHooks.systemBatteryPercent() },
            freeDiskBytes: { SessionHooks.systemFreeDiskBytes() },
            nudgeVector: {
                // Worst-case measured sky drift, fed forward along yaw once per cadence.
                let yaw = GimbalConstants.skyDriftDegPerMin * GimbalConstants.nudgeCadence / 60.0
                return (deltaPitchDeg: 0, deltaYawDeg: yaw)
            },
            now: { Date() },
            sleep: { seconds in
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            })
        // Device focus seams: the sweep moves the REAL lens through the running
        // capture engine, and the focus chip mirrors the telemetry the engine
        // already computes off the hot path (no duplicate per-frame math).
        hooks.setLensPosition = { position in
            await CaptureEngine.shared.setLensPosition(position)
        }
        hooks.focusTelemetry = {
            let engine = CaptureEngine.shared
            return (engine.focusSharpness, engine.focusSharpnessMean, engine.focusDrifting)
        }
        return hooks
        #endif
    }

    // MARK: System guardians

    @MainActor
    static func systemBatteryPercent() -> Int? {
        #if targetEnvironment(simulator)
        return 100
        #elseif canImport(UIKit)
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level >= 0 ? Int((level * 100).rounded()) : nil
        #else
        return nil
        #endif
    }

    static func systemFreeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Synthetic starfield (simulator / dev capture path)

    static let syntheticSize = 256

    /// Deterministic starfield with a slow per-frame drift, so the real stacker has
    /// something meaningful to register against in the simulator.
    static func syntheticFrame(recipe: CaptureRecipe, index: Int) -> SubFrame {
        let side = syntheticSize
        var image: CGImage?
        if let ctx = CGContext(data: nil, width: side, height: side,
                               bitsPerComponent: 8, bytesPerRow: side,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue) {
            ctx.setFillColor(gray: 0.03, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            var rng = SplitMix64(seed: 0xC0FFEE_D00D)
            let drift = Double(index) * 0.12   // px of simulated sky drift per frame
            for _ in 0..<130 {
                let x = Double(rng.next() % 100_000) / 100_000 * Double(side)
                let y = Double(rng.next() % 100_000) / 100_000 * Double(side)
                let brightness = 0.25 + Double(rng.next() % 1000) / 1000 * 0.75
                let radius = 0.7 + Double(rng.next() % 1000) / 1000 * 0.9
                ctx.setFillColor(gray: CGFloat(brightness), alpha: 1)
                ctx.fillEllipse(in: CGRect(x: x + drift - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
            }
            image = ctx.makeImage()
        }
        return SubFrame(index: index, timestamp: Date(),
                        exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                        pixelData: image)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - CloudTimeBudget (pure math, unit-tested)

/// The honest accounting for cloud pauses: frames the cloud gate skips must NOT
/// consume the shot's planned sub count — they extend the session instead, so a
/// "600-sub Milky Way stack" still delivers 600 stacked subs after a cloud bank.
/// The extension is capped at `extensionFactor` × the plan's wall time so a sky
/// that never clears can never trap a session forever. No actor, no clocks —
/// tests script the numbers directly.
public enum CloudTimeBudget {

    /// A session may run up to this multiple of its planned wall time before
    /// cloud-skipped frames start consuming the plan again.
    public static let extensionFactor: Double = 2.0

    /// Wall-clock seconds the capture plan expects: every sub plus its cadence gap.
    public static func plannedWallSeconds(recipe: CaptureRecipe) -> Double {
        Double(max(0, recipe.targetSubCount))
            * (max(0, recipe.exposureSeconds) + max(0, recipe.intervalSeconds))
    }

    /// True while a cloud-skipped frame may still extend the session.
    public static func allowsExtension(plannedSeconds: Double,
                                       elapsedSeconds: Double) -> Bool {
        elapsedSeconds < plannedSeconds * extensionFactor
    }

    /// Steady-state status line while frames are being skipped under clouds.
    /// Honest about the cost: how much session time the wait has added, and —
    /// once the budget is spent — that the session will wrap up rather than
    /// keep waiting (which can mean fewer subs than planned; the landing
    /// report counts them).
    public static func waitLine(skippedFrames: Int, frameSeconds: Double,
                                extending: Bool) -> String {
        guard extending else {
            return "Clouds have used the extra session time — wrapping up rather than waiting longer."
        }
        let added = Double(max(0, skippedFrames)) * max(0, frameSeconds)
        let time = added < 60
            ? "\(Int(added.rounded())) s"
            : "\(Int((added / 60).rounded())) min"
        return "Waiting out clouds — \(time) added, the stack is safe."
    }
}

// MARK: - SessionEngine

/// The flight computer. Walks a shot through
/// Connect → Aim → Calibrate → Capture → Develop → Complete,
/// surviving every edge case in DESIGN.md: authority gating, flapping (undock/re-dock),
/// re-dock recenter (pointing invalidated), thermal/battery/storage guardians,
/// keepalive during idle gaps, backgrounding, and abort from anywhere.
@MainActor
public final class SessionEngine: ObservableObject {

    public static let shared = SessionEngine()

    // MARK: Published session state

    @Published public private(set) var phase: SessionPhase = .connect
    @Published public private(set) var interruption: SessionInterruption?
    @Published public private(set) var stats = SessionStats()
    @Published public private(set) var latestPreview: CGImage?
    @Published public private(set) var activeShot: ShotModeItem?
    @Published public private(set) var isRunning = false
    /// Re-dock may recenter the head (+22° pitch jump observed) — when true, the UI
    /// should ask the user to re-check framing.
    @Published public private(set) var pointingInvalidated = false
    /// Set after returning from background: UI shows a "resume session?" prompt.
    @Published public private(set) var awaitingResume = false
    /// One-line human status for the session screen.
    @Published public private(set) var statusDetail = "Ready"
    /// Rolling measured sky condition for the current session, classified from
    /// per-frame star counts + background levels by `SkyConditionMonitor`.
    /// `.unknown` until enough starry frames establish a baseline.
    @Published public private(set) var skyCondition: SkyCondition = .unknown
    /// Focus-sweep progress/verdict for this session (see FocusSweep.swift).
    /// Stays `.inactive` for modes that never sweep (trails, timelapse).
    @Published public private(set) var focusSweepStatus: FocusSweepStatus = .inactive
    /// Live focus telemetry mirrored once per captured sub (device: the capture
    /// engine's variance-of-Laplacian meter; simulator: the focus model).
    /// Drives the session screen's focus chip and its drift warning.
    @Published public private(set) var focusSharpness: Double?
    @Published public private(set) var focusSharpnessMean: Double?
    @Published public private(set) var focusDrifting = false

    // MARK: Published telemetry mirrors

    @Published public private(set) var mountConnection: MountConnection = .searching
    @Published public private(set) var mountAuthority: MountAuthority = .unknown
    @Published public private(set) var mountTelemetry: MountTelemetry?
    @Published public private(set) var thermal: ProcessInfo.ThermalState = .nominal
    @Published public private(set) var phoneBatteryPercent: Int?

    /// 0…1 across the capture plan. Counts plan slots actually consumed:
    /// accepted + rejected + the slots clouds ate after the extension budget
    /// was spent (`subsLostToClouds`). Cloud skips inside the budget extend
    /// the session instead of consuming the plan, so they don't move this.
    public var progress: Double {
        guard let target = activeShot?.recipe.targetSubCount, target > 0 else { return 0 }
        let consumed = stats.subsAccepted + stats.subsRejected + stats.subsLostToClouds
        return min(1, Double(consumed) / Double(target))
    }

    /// True when this session's frames come from a synthetic capture source
    /// (simulator builds only). The UI shows a rose "SIMULATED" pill wherever this
    /// engine's data is rendered so fake stars can never masquerade as real ones.
    public var captureSourceIsSimulated: Bool { hooks.isSimulatedCapture }

    // MARK: Dependencies

    /// Test/preview seam. `SessionHooks.live()` already routes to the real
    /// `CaptureEngine` on device builds — no assembly-time replacement is needed.
    public static var defaultHooksProvider: () -> SessionHooks = { SessionHooks.live() }

    /// Defaulted engine setting: while the measured sky condition is `.cloudy`
    /// during a REGISTERED-stack session, keep capturing but skip handing
    /// frames to the stacker (they would only be rejected by registration, and
    /// skipping saves the CPU for the moment the sky opens). Trails and
    /// timelapse styles are never gated — clouds are part of those shots.
    public var pauseStackingWhenCloudy = true

    /// Defaulted engine setting: before a REGISTERED-stack session starts
    /// stacking, sweep the lens through a ladder of positions near infinity and
    /// lock the sharpest (see FocusSweep.swift). Skips itself gracefully under
    /// clouds, starless frames (indoors), or a sharpness signal too weak to
    /// trust — a skipped sweep never costs more than one probe frame. The
    /// Settings toggle with the same name can veto it (defaults on).
    public var autoFocusSweep = true

    /// User-facing veto from Settings → Capture; unset means on.
    private var focusSweepUserEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoFocusSweep") as? Bool ?? true
    }

    private let mount: MountControlling
    /// Explicitly injected stacker (tests/previews). When present it is used for every
    /// session verbatim; when nil, `start(shot:)` picks a stacker per mode.
    private let injectedStacker: Stacking?
    /// The stacker for the current session (mode-aware unless one was injected).
    private var stacker: Stacking
    private let hooks: SessionHooks

    public init(mount: MountControlling? = nil,
                stacker: Stacking? = nil,
                hooks: SessionHooks? = nil) {
        self.mount = mount ?? MountService.shared
        self.injectedStacker = stacker
        self.stacker = stacker ?? CPUStacker()
        self.hooks = hooks ?? SessionEngine.defaultHooksProvider()
    }

    /// Mode-aware stacker selection: star trails lighten-blend (registration would
    /// erase the arcs), timelapse plain unregistered mean, everything else the
    /// registered star stack.
    static func makeStacker(style: StackingStyle) -> Stacking {
        switch style {
        case .registered:
            return CPUStacker()
        case .trails:
            return TrailsBlender()
        case .unregistered:
            return CPUStacker(kappaSigma: nil, registration: false)
        }
    }

    // MARK: Private state

    private var sessionTask: Task<Void, Never>?
    private var generation = 0
    private var backgroundPaused = false
    private var lastNudgeAt: Date?
    private var lastMountActivityAt = Date.distantPast
    private var netYawDeg: Double = 0
    private var thermalBackoffSeconds: TimeInterval = 0
    private var batteryWarned = false
    private var gimbalBatteryWarned = false
    private var rejectionStreak = 0
    /// Consecutive rejections whose CPUStacker reason was "too few stars" — drives the
    /// "this mode needs the night sky" guidance without interrupting the session.
    private var noStarStreak = 0
    /// Per-session sky-condition classifier (rebuilt on every `start`).
    private var skyMonitor = SkyConditionMonitor()
    /// Measured sky-background samples (0…1) from this session's frames —
    /// feeds the one-shot mid-session exposure refinement.
    private var backgroundSamples: [Double] = []
    /// The single mid-session ISO adjustment has been evaluated (applied or
    /// declined) — "one adjustment mid-session max" lives here.
    private var exposureRefineEvaluated = false
    /// Number of measured frames before the exposure refinement is evaluated.
    static let refineAfterSamples = 5
    /// Stack grid dimensions from `prepareCapture` — the grid frame measurement
    /// runs on when the stacker can't provide an observation itself.
    private var captureDims = (width: 0, height: 0)
    /// Plate-solve GoTo state (feature 5). `goToActive` goes true after the
    /// first successful acquire — drift cross-checks only run once a solve has
    /// proven the sky is solvable tonight.
    private var goToActive = false
    /// Set on flap recovery: pointing may have jumped (re-dock recenter), so a
    /// GoTo-capable session re-acquires before capture resumes.
    private var pendingReacquire = false
    private var lastDriftCheckAt: Date?
    private var nudgesAtLastDriftCheck = 0
    /// Drift cross-check cadence: every 10 min, or after 5 framing nudges,
    /// whichever comes first.
    static let driftCheckInterval: TimeInterval = 600
    static let driftCheckNudgeCount = 5
    /// Measured drift above this gets a corrective impulse (deg).
    static let driftToleranceDeg = 1.0
    private let pollInterval: TimeInterval = 0.25
    private let previewEvery = 10

    private enum Halt: Error { case graceful }

    // MARK: - Public controls

    public func start(shot: ShotModeItem) {
        guard sessionTask == nil else { return }
        generation += 1
        let gen = generation
        // Mode-aware stacking: trails lighten-blend / timelapse unregistered mean /
        // registered star stack. An injected stacker (tests) always wins.
        if injectedStacker == nil {
            stacker = SessionEngine.makeStacker(style: shot.stackingStyle)
        }
        activeShot = shot
        isRunning = true
        interruption = nil
        pointingInvalidated = false
        awaitingResume = false
        backgroundPaused = false
        batteryWarned = false
        gimbalBatteryWarned = false
        rejectionStreak = 0
        noStarStreak = 0
        skyMonitor = SkyConditionMonitor()
        skyCondition = .unknown
        backgroundSamples = []
        exposureRefineEvaluated = false
        focusSweepStatus = .inactive
        focusSharpness = nil
        focusSharpnessMean = nil
        focusDrifting = false
        captureDims = (0, 0)
        goToActive = false
        pendingReacquire = false
        lastDriftCheckAt = nil
        nudgesAtLastDriftCheck = 0
        netYawDeg = 0
        thermalBackoffSeconds = 0
        lastNudgeAt = nil
        lastMountActivityAt = .distantPast
        latestPreview = nil
        var fresh = SessionStats()
        fresh.startedAt = hooks.now()
        // Warm the gravity sampler up and take a provisional tilt reading; the
        // authoritative sample lands when the Capture phase begins (the phone is
        // clamped and framed by then). Portrait UI lock makes gravity the only
        // honest orientation source.
        fresh.captureTilt = hooks.captureTilt()
        stats = fresh
        phase = .connect
        statusDetail = "Starting \(shot.name)…"
        sessionTask = Task { [weak self] in
            await self?.run(shot: shot, gen: gen)
        }
    }

    /// Safe from any state: cancels the session, zeroes the motors, and keeps whatever
    /// was already stacked.
    public func abort() {
        generation += 1
        sessionTask?.cancel()
        sessionTask = nil
        let hadData = stats.subsAccepted > 0
        interruption = nil
        awaitingResume = false
        backgroundPaused = false
        isRunning = false
        let mount = self.mount
        let endCapture = hooks.endCapture
        Task {
            await mount.stopEverything()
            await endCapture()
        }
        if hadData {
            if let final = stacker.finalImage() { latestPreview = oriented(final) }
            phase = .complete
            statusDetail = "Session ended early — \(stats.subsAccepted) frames kept."
        } else {
            phase = .connect
            activeShot = nil
            statusDetail = "Ready"
        }
    }

    /// App left the foreground: zero the motors, pause capture, remember where we were.
    public func handleBackgrounded() async {
        guard isRunning else { return }
        backgroundPaused = true
        interruption = .backgrounded
        statusDetail = "Backgrounded — capture paused, motors zeroed."
        await mount.stopEverything()
    }

    /// Back in the foreground: hold the pause and prompt the user to resume.
    public func handleForegrounded() async {
        guard isRunning, backgroundPaused else { return }
        backgroundPaused = false
        awaitingResume = true
        statusDetail = "Welcome back — resume the session?"
    }

    /// User confirmed the resume prompt after foregrounding.
    public func resume() {
        guard awaitingResume else { return }
        awaitingResume = false
        if interruption == .backgrounded { interruption = nil }
        if activeShot?.needsGimbal == true {
            mount.start()
            statusDetail = "Resuming — reconnecting to the gimbal…"
        } else {
            statusDetail = "Resuming…"
        }
    }

    // MARK: - State machine

    private func run(shot: ShotModeItem, gen: Int) async {
        do {
            try await connectPhase(shot: shot)
            try await aimPhase(shot: shot)
            try await calibratePhase(shot: shot)
            try await capturePhase(shot: shot)
        } catch is CancellationError {
            // Our own cancellation: abort() already finalized state and stopped the mount.
            // A cancellation that leaked from a dependency while the session is still live
            // (generation unchanged, task not cancelled) must NOT strand a zombie session —
            // fall through and save the partial stack instead.
            guard gen == generation, !Task.isCancelled else { return }
            statusDetail = "Capture hit a problem — saving the partial stack."
        } catch {
            // Halt.graceful (guardians) or an unexpected capture error: save what we have.
            guard gen == generation else { return }
            if !(error is Halt) {
                statusDetail = "Capture hit a problem — saving the partial stack."
            }
        }
        guard gen == generation else { return }
        await developPhase()
        guard gen == generation else { return }
        phase = .complete
        statusDetail = completionSummary()
        await mount.stopEverything()
        if gen == generation {
            isRunning = false
            sessionTask = nil
        }
    }

    // MARK: Connect — dock + authority gate

    private func connectPhase(shot: ShotModeItem) async throws {
        phase = .connect
        try await waitWhileSuspended()
        guard shot.needsGimbal else {
            statusDetail = "No gimbal needed — keep the phone rock steady."
            return
        }
        statusDetail = "Searching for gimbal…"
        mount.start()
        while !isDocked {
            syncMirrors()
            try Task.checkCancellation()
            try await hooks.sleep(pollInterval)
        }
        syncMirrors()
        // Authority gate: DockKit control needs the trigger squeeze.
        if mount.authority != .granted {
            interruption = .authorityNeeded
            statusDetail = "Squeeze the gimbal trigger to hand StarFlow the controls."
            while mount.authority != .granted {
                try Task.checkCancellation()
                try await hooks.sleep(pollInterval)
                syncMirrors()
            }
            interruption = nil
        }
        statusDetail = "Gimbal connected."
        syncMirrors()
    }

    // MARK: Aim

    private func aimPhase(shot: ShotModeItem) async throws {
        phase = .aim
        try await waitWhileSuspended()
        statusDetail = "Frame your target…"
        if shot.needsGimbal {
            _ = await mount.waitSettled()
            lastMountActivityAt = hooks.now()
        }
        if shot.needsGimbal, let target = shot.celestialTarget {
            await runAimAssist(target: target)
            try Task.checkCancellation()
        }
        try await hooks.sleep(0.5)
    }

    /// Compass-coarse auto-aim before the manual framing confirm. Best-effort by
    /// design: any failure (no location fix, no motion hardware, authority revoked,
    /// envelope refusal…) falls back to manual framing with an explanatory status —
    /// it must NEVER end the session.
    ///
    /// This is the COARSE half of aiming (±5–15° compass budget, target in the
    /// 73° frame). The PRECISE half — plate-solve GoTo to ≤ 0.5° — runs at the
    /// start of the Capture phase (`runGoToAcquire`), because a solve needs a
    /// live camera frame and the capture pipeline only exists from that point.
    private func runAimAssist(target: CelestialTarget) async {
        guard mount.authority == .granted else {
            statusDetail = "Squeeze the gimbal trigger for auto-aim, or frame manually."
            return
        }
        guard let location = AppLocation.shared.current else {
            statusDetail = "No location fix yet — frame \(target.displayName) manually."
            return
        }
        let assist = AimAssist()
        let coord = assist.resolve(target: target, location: location, date: hooks.now())
        guard coord.altitudeDeg > 0 else {
            statusDetail = "Aim Assist skipped: \(target.displayName) is below the horizon "
                + "right now — frame manually or wait for it to rise."
            return
        }
        statusDetail = "Aim Assist: slewing to \(target.displayName)…"
        do {
            let outcome = try await assist.slewToTarget(mount: mount, to: coord) { [weak self] stage in
                if stage == .refining { self?.statusDetail = "Aim Assist: refining…" }
            }
            lastMountActivityAt = hooks.now()
            if outcome.pitchClamped {
                statusDetail = "Aimed as far as the tilt range allows — nudge the framing "
                    + "by hand, then confirm."
            } else {
                statusDetail = "Target in frame — confirm framing."
            }
        } catch MountError.noAuthority {
            statusDetail = "Squeeze the gimbal trigger for auto-aim, or frame manually."
        } catch is CancellationError {
            // Our own cancellation propagates from aimPhase's checkCancellation;
            // a cancellation leaked by a dependency just means: frame manually.
            statusDetail = "Aim Assist interrupted — frame \(target.displayName) manually."
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription
                ?? "the gimbal refused the move"
            statusDetail = "Aim Assist couldn't finish (\(reason)) "
                + "— frame \(target.displayName) manually."
        }
    }

    // MARK: Calibrate — test impulse + settle check

    private func calibratePhase(shot: ShotModeItem) async throws {
        phase = .calibrate
        try await waitWhileSuspended()
        guard shot.needsGimbal else { return }
        statusDetail = "Calibrating — test nudge and settle check…"
        do {
            // Out-and-back impulse pair: verifies authority end-to-end and leaves framing intact.
            try await mount.nudge(deltaPitchDeg: 0, deltaYawDeg: GimbalConstants.nudgeTargetDeg)
            try await mount.nudge(deltaPitchDeg: 0, deltaYawDeg: -GimbalConstants.nudgeTargetDeg)
        } catch is CancellationError {
            // Propagate only our own cancellation (abort). A motion plan cancelled under
            // us (undock or backgrounding zeroes the motors mid-nudge) must not end the
            // session — the pause/flap gateway picks it up on the next pass.
            try Task.checkCancellation()
            statusDetail = "Calibration interrupted — continuing."
        } catch {
            statusDetail = "Calibration nudge refused (envelope edge?) — continuing without it."
        }
        let settled = await mount.waitSettled()
        if !settled {
            statusDetail = "Mount didn't fully settle — starting anyway; first frames may be soft."
        }
        lastMountActivityAt = hooks.now()
    }

    // MARK: Capture loop

    private func capturePhase(shot: ShotModeItem) async throws {
        phase = .capture
        // Mutable copy: the one-shot mid-session exposure refinement may adjust
        // ISO after the first measured frames (never the shutter, never the plan
        // shape — sub count, tracking, and cadence are the mode's contract).
        var recipe = shot.recipe

        // Storage pre-flight: refuse a plan the disk can't hold BEFORE the first frame
        // (StorageBudget owns the math; hooks.estimatedBytesPerFrame is the seam).
        // The in-flight guardian below still watches the 1 GB floor during capture.
        let plannedBytes = StorageBudget.plannedSessionBytes(
            recipe: recipe, bytesPerFrame: hooks.estimatedBytesPerFrame(recipe))
        switch StorageBudget.verdict(freeBytes: hooks.freeDiskBytes(), plannedBytes: plannedBytes) {
        case .refuse:
            interruption = .storageLow
            statusDetail = "Not enough free space — this session needs about "
                + "\(StorageBudget.format(plannedBytes)) plus a safety reserve. "
                + "Free up storage and try again."
            throw Halt.graceful
        case .warn:
            statusDetail = "Storage is tight — the session may stop early if space runs out."
        case .ok:
            break
        }

        // Bring the capture pipeline up. On device this requests camera permission
        // (or reuses the onboarding grant) and starts the real AVCaptureSession —
        // a denial or hardware failure must surface loudly, never fall back to
        // synthetic frames.
        let dims: (width: Int, height: Int)
        do {
            dims = try await hooks.prepareCapture(recipe)
        } catch CaptureError.notAuthorized {
            interruption = .cameraDenied
            statusDetail = "Camera access is off — StarFlow can't capture stars without it. "
                + "Enable Camera for StarFlow in Settings, then start the session again."
            throw Halt.graceful
        } catch let error as CaptureError {
            if case .insufficientStorage = error { interruption = .storageLow }
            statusDetail = error.errorDescription ?? "Camera setup failed."
            throw Halt.graceful
        }
        // Authoritative tilt sample: framing is confirmed and the phone sits in
        // the clamp exactly the way it will for every sub. This drives the
        // develop-phase rotation that makes the final image match the live view.
        stats.captureTilt = hooks.captureTilt()
        captureDims = dims
        stacker.reset(width: dims.width, height: dims.height)

        // Plate-solve GoTo stage (feature 5): the camera is live now, so the
        // compass-coarse aim from the Aim phase can be upgraded to solver
        // precision (≤ 0.5°). It runs here — not in the Aim phase — because a
        // solve needs a real frame and the capture pipeline only exists from
        // this point. Best-effort: any failure narrates why and the session
        // continues on the AimAssist aim.
        await runGoToAcquire(shot: shot, recipe: recipe, reacquire: false)
        try Task.checkCancellation()

        // Focus-sweep stage (between Calibrate and the capture loop): the
        // camera is live and locked at infinity — try to do better than the
        // hard stop before the first stacked frame. Never fatal; a skip or a
        // flat curve just keeps the infinity lock.
        try await focusSweepStage(shot: shot, recipe: recipe)

        // Hold the sweep's verdict line ("Locked best focus." / a skip reason)
        // for the first frame instead of instantly clobbering it — the per-sub
        // counter takes over from the second frame anyway.
        if case .inactive = focusSweepStatus { statusDetail = "Capturing…" }

        // Cloud-time budget: cloud-skipped frames extend the session instead of
        // consuming the plan, capped at 2× the planned wall time (see
        // CloudTimeBudget). `index` counts PLAN slots; `attempt` counts every
        // shutter actuation, skipped or not.
        let plannedWallSeconds = CloudTimeBudget.plannedWallSeconds(recipe: recipe)
        let captureStartedAt = hooks.now()
        var cloudExtensionActive = true

        var index = 0
        var attempt = 0
        while index < recipe.targetSubCount {
            try Task.checkCancellation()
            syncMirrors()
            try await pauseGateway(shot: shot)     // background pause + flap handling
            if pendingReacquire {
                // Flap recovery invalidated pointing (re-dock can recenter the
                // head) — GoTo-capable sessions re-acquire the target with a
                // solve before capture resumes (registered style only; the
                // guard inside no-ops for everything else).
                pendingReacquire = false
                await runGoToAcquire(shot: shot, recipe: recipe, reacquire: true)
                try Task.checkCancellation()
            }
            try runGuardians()                     // thermal / battery / storage
            if shot.needsGimbal {
                if recipe.nudgeTracking {
                    try await nudgeIfDue()
                } else {
                    await keepaliveIfIdle()        // HOLD modes: defeat firmware sleep
                }
                await driftCheckIfDue(shot: shot, recipe: recipe)
                try Task.checkCancellation()
            }

            let frame = try await hooks.captureSub(recipe, attempt)
            attempt += 1
            syncFocusTelemetry()
            // Cloud gate (defaulted engine setting): while the measured sky is
            // cloudy in a registered-stack session, keep capturing but skip the
            // accumulate — registration would only reject these frames. The
            // monitor keeps watching every frame so it notices the gap opening.
            let cloudGateActive = pauseStackingWhenCloudy
                && shot.stackingStyle == .registered
            let skippedForClouds = cloudGateActive && skyCondition == .cloudy
            var skyAdvicePosted = false
            if skippedForClouds {
                // `feedRefine: false`: a cloud-lit background is real but
                // unrepresentative of the sky the stack exposes under — it must
                // not steer the one-shot ISO refinement that outlives the clouds.
                skyAdvicePosted = observeSky(frame: frame, cpuStacker: nil,
                                             gated: cloudGateActive, feedRefine: false)
                stats.subsSkippedClouds += 1
                // A skipped frame must not consume the plan — extend the
                // session instead, until clouds have doubled its wall time.
                let elapsed = hooks.now().timeIntervalSince(captureStartedAt)
                cloudExtensionActive = CloudTimeBudget.allowsExtension(
                    plannedSeconds: plannedWallSeconds, elapsedSeconds: elapsed)
                if !cloudExtensionActive {
                    index += 1   // budget spent: clouds now count down the plan
                    stats.subsLostToClouds += 1
                }
            } else {
                let accepted = stacker.add(frame: frame)
                skyAdvicePosted = observeSky(frame: frame, cpuStacker: stacker as? CPUStacker,
                                             gated: cloudGateActive)
                if accepted {
                    stats.subsAccepted += 1
                    stats.integrationSeconds += frame.exposureSeconds
                    rejectionStreak = 0
                    noStarStreak = 0
                    if stats.subsAccepted % previewEvery == 0 {
                        // Rotated the same way as the final image, so the live view
                        // and the landing report can never disagree on orientation.
                        latestPreview = oriented(stacker.currentResult().preview) ?? latestPreview
                    }
                } else {
                    stats.subsRejected += 1
                    rejectionStreak += 1
                    // CPUStacker-specific diagnostics (deliberately not on the Stacking
                    // protocol) — read via conditional cast.
                    if (stacker as? CPUStacker)?.lastRejectionReason == "too few stars" {
                        noStarStreak += 1
                    } else {
                        noStarStreak = 0
                    }
                    if rejectionStreak == 8 {
                        statusDetail = "Several frames rejected in a row — clouds rolling in, "
                            + "or no stars in frame? Check the sky."
                    }
                    if noStarStreak == 10 {
                        // Guidance only — the session keeps running (the sky may clear).
                        statusDetail = "No stars detected — frames are real, but this mode "
                            + "needs the night sky. Try Star Trails to test indoors."
                    }
                }
                index += 1
            }
            // One-shot exposure refinement: once the first few frames have
            // MEASURED the sky background, trade gain in whichever direction
            // the histogram says (see ExposurePlanner.refine). Narrated once.
            var refineNarrated = false
            if !skippedForClouds {
                refineNarrated = refineExposureIfReady(recipe: &recipe,
                                                       style: shot.stackingStyle)
            }
            if skippedForClouds && !skyAdvicePosted {
                // Steady-state cloud pause: re-post the honest waiting line every
                // frame. Without this, any status written mid-pause (resume flow,
                // thermal/battery guardians, flap recovery) would stick on screen
                // for the rest of the cloud bank while frames are silently
                // skipped — matching how the sub counter refreshes each frame on
                // the normal path. The transition frame itself is excluded so the
                // "Clouds rolling in" advice still holds for at least one frame.
                statusDetail = CloudTimeBudget.waitLine(
                    skippedFrames: stats.subsSkippedClouds,
                    frameSeconds: recipe.exposureSeconds + recipe.intervalSeconds,
                    extending: cloudExtensionActive)
            } else if (cloudGateActive && skyCondition == .cloudy) || skyAdvicePosted
                        || refineNarrated {
                // Hold the sky advice on screen for at least one frame instead
                // of overwriting it with the sub counter immediately.
            } else if rejectionStreak < 8 {
                var line = "Sub \(index)/\(recipe.targetSubCount) · "
                    + "\(Int(stats.integrationSeconds)) s integrated"
                if skyCondition != .clear && skyCondition != .unknown {
                    line += " · \(skyCondition.displayName) sky"
                }
                statusDetail = line
            }

            let gap = recipe.intervalSeconds + thermalBackoffSeconds
            if gap > 0, index < recipe.targetSubCount {
                try await waitGap(gap, shot: shot)
            }
        }
    }

    // MARK: Focus sweep (between Calibrate and the capture loop)

    /// Optional focus-sweep stage for registered star stacks: probe the sky,
    /// then try a coarse→fine ladder of lens positions near infinity, score
    /// each on live frames with the existing sharpness metric, and lock the
    /// best (see FocusSweep.swift). Skips gracefully — never fails the session —
    /// when the measured sky is cloudy/overexposed, the frame is starless
    /// (indoors), or the sharpness signal is too weak to trust.
    private func focusSweepStage(shot: ShotModeItem, recipe: CaptureRecipe) async throws {
        guard autoFocusSweep, focusSweepUserEnabled,
              shot.stackingStyle == .registered else { return }
        let plan = FocusSweepPlan()
        if skyCondition == .cloudy || skyCondition == .overexposed {
            focusSweepStatus = .skipped(reason: "sky is \(skyCondition.displayName)")
            statusDetail = "Focus sweep skipped — the sky is \(skyCondition.displayName) "
                + "right now. Staying at the infinity lock."
            return
        }
        statusDetail = "Focus check — reading the stars…"
        do {
            // Probe frame: the sweep is only worth 30-odd frames when there are
            // actual stars to sharpen. The probe also feeds the sky monitor, so
            // no exposure is wasted.
            let probe = try await hooks.captureSub(recipe, 0)
            observeSky(frame: probe, cpuStacker: nil, gated: pauseStackingWhenCloudy)
            if let image = probe.pixelData,
               let observation = SkyConditionMonitor.measure(image: image,
                                                            width: captureDims.width,
                                                            height: captureDims.height,
                                                            at: probe.timestamp),
               observation.starCount < plan.minProbeStars {
                focusSweepStatus = .skipped(
                    reason: "only \(observation.starCount) stars in frame")
                statusDetail = "Focus sweep skipped — not enough stars to measure "
                    + "(\(observation.starCount) in frame). Staying at the infinity lock."
                return
            }
            guard let probeScore = hooks.focusScore(probe), probeScore > 0 else {
                focusSweepStatus = .skipped(reason: "sharpness signal too weak")
                statusDetail = "Focus sweep skipped — sharpness signal too weak to "
                    + "trust. Staying at the infinity lock."
                return
            }
            // "Up to" because the fine ladder only runs when the coarse pass
            // finds a real peak — and the progress chip counts to the same
            // planned total, so the two never disagree.
            statusDetail = "Focus sweep: trying up to \(plan.plannedPositions) lens positions…"
            let sweepHooks = self.hooks
            let io = FocusSweep.IO(
                setLens: { position in await sweepHooks.setLensPosition(Float(position)) },
                captureFrame: { [weak self] in
                    // The sweep is a ~half-minute stage outside the capture
                    // loop's gateways: honor a background pause instead of
                    // scoring pocket frames, and keep the gimbal awake (the
                    // firmware inactivity timeout is shorter than the sweep).
                    if let self {
                        try await self.waitWhileSuspended()
                        if shot.needsGimbal { await self.keepaliveIfIdle() }
                    }
                    return try await sweepHooks.captureSub(recipe, 0)
                },
                score: { frame in sweepHooks.focusScore(frame) },
                onStep: { [weak self] step, planned in
                    guard let self else { return }
                    self.focusSweepStatus = .running(step: step, planned: planned)
                    if step == plan.coarseSteps + 1 {
                        self.statusDetail = "Focus sweep: refining near the peak…"
                    }
                })
            let outcome = try await FocusSweep.run(plan: plan, io: io)
            focusSweepStatus = .locked(position: outcome.position,
                                       decisive: outcome.decisive)
            statusDetail = outcome.decisive
                ? "Locked best focus."
                : "No clear focus peak — keeping the infinity lock."
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A capture hiccup during the sweep must not end the session:
            // restore the infinity lock and continue — if capture is genuinely
            // broken, the capture loop surfaces it loudly right after.
            await hooks.setLensPosition(Float(plan.upperBound))
            focusSweepStatus = .skipped(reason: "sweep interrupted")
            statusDetail = "Focus sweep couldn't finish — continuing at the infinity lock."
        }
    }

    // MARK: Plate-solve GoTo (feature 5)

    /// True when this session can close the aiming loop with plate solves:
    /// a gimbal session with a registered stack whose recipe actually produces
    /// solvable STAR fields (trails/timelapse never re-aim — the framing IS the
    /// shot). Star-field targets only: a Lunar Detail recipe (1/125 s, ISO 100,
    /// tele framing) can't register a single catalog star, so every solve would
    /// fail and the fallback copy would blame clouds on a clear moonlit night —
    /// dishonest narration for a shot the solver was never going to help.
    private func goToSupported(_ shot: ShotModeItem) -> Bool {
        shot.needsGimbal && shot.celestialTarget == .milkyWayCore
            && shot.stackingStyle == .registered
    }

    /// The GoTo world seams, routed through the EXISTING capture hooks so
    /// simulator tests inject synthetic solvable fields and no device-camera
    /// path is reachable from tests. Each solve frame is a probe (index 0,
    /// same as the focus sweep) — it never counts against the capture plan.
    private func makeGoToIO(recipe: CaptureRecipe) -> GoToController.IO {
        let hooks = self.hooks
        return GoToController.IO(
            captureField: { [weak self] in
                if let self { try await self.waitWhileSuspended() }
                let frame = try await hooks.captureSub(recipe, 0)
                // Undecodable frame = nothing to read: an empty field flows
                // through the controller's honest tooFewStars path.
                return hooks.detectStarField(frame)
                    ?? GoToController.StarField(centroids: [], imageSize: .zero)
            },
            solve: { field, fovDeg in hooks.solveStarField(field, fovDeg) },
            now: { hooks.now() })
    }

    /// Run one GoTo acquire (initial aim refinement, or the re-acquire after a
    /// flap recovery). Best-effort by design: every failure narrates an honest
    /// status and leaves the session running on the coarse AimAssist aim —
    /// it must NEVER end the session. Cancellation is re-surfaced by the
    /// caller's `Task.checkCancellation()`.
    private func runGoToAcquire(shot: ShotModeItem, recipe: CaptureRecipe,
                                reacquire: Bool) async {
        guard goToSupported(shot), let target = shot.celestialTarget else { return }
        guard mount.authority == .granted else {
            statusDetail = "Plate-solve aim needs gimbal control — keeping the compass aim."
            return
        }
        guard let location = AppLocation.shared.current else {
            statusDetail = "Plate-solve aim needs a location fix — keeping the compass aim."
            return
        }
        let coord = AimAssist().resolve(target: target, location: location, date: hooks.now())
        guard coord.altitudeDeg > 0 else { return }   // below horizon — Aim phase explained
        statusDetail = reacquire
            ? "Gimbal back — re-acquiring \(target.displayName) with a plate solve…"
            : "Refining aim on \(target.displayName) with a plate solve…"
        do {
            let outcome = try await GoToController().acquire(
                target: coord, location: location, mount: mount,
                io: makeGoToIO(recipe: recipe)) { [weak self] line in
                    self?.statusDetail = line
                }
            goToActive = true
            pointingInvalidated = false          // pointing verified by the solve
            lastDriftCheckAt = hooks.now()
            nudgesAtLastDriftCheck = stats.nudges
            lastMountActivityAt = hooks.now()
            statusDetail = String(format: "Locked on %@ — %.1f° from center.",
                                  target.displayName, outcome.finalErrorDeg)
        } catch is CancellationError {
            // Our own cancellation propagates via the caller's checkCancellation;
            // a leaked one just means: continue on the coarse aim.
            statusDetail = "Aim refinement interrupted — continuing on the compass aim."
        } catch let failure as GoToController.Failure {
            statusDetail = "Plate-solve aim skipped — \(failure.fallbackReason) "
                + (reacquire ? "Check your framing (re-dock can recenter the head)."
                             : "Keeping the compass aim — fine-tune by hand.")
        } catch {
            statusDetail = "Plate-solve aim couldn't finish — keeping the compass aim."
        }
    }

    /// Mid-session drift cross-check: every 10 minutes, or after 5 framing
    /// nudges, one extra solve verifies the frame still points at the target;
    /// drift over 1° gets a corrective impulse, narrated. Only runs once GoTo
    /// has locked on at least once this session (`goToActive`) — if the sky
    /// never solved, there is nothing trustworthy to cross-check against.
    private func driftCheckIfDue(shot: ShotModeItem, recipe: CaptureRecipe) async {
        guard goToActive, goToSupported(shot), let target = shot.celestialTarget,
              let location = AppLocation.shared.current else { return }
        // A measured-cloudy sky cannot solve — don't burn a probe frame on a
        // guaranteed failure while the cloud gate is already narrating the wait.
        // The cadence clock is deliberately NOT advanced here, so the first
        // check after the sky clears re-verifies pointing right away.
        guard skyCondition != .cloudy else { return }
        let now = hooks.now()
        let elapsed = lastDriftCheckAt.map { now.timeIntervalSince($0) } ?? .infinity
        let nudgesSince = stats.nudges - nudgesAtLastDriftCheck
        guard elapsed >= Self.driftCheckInterval
                || nudgesSince >= Self.driftCheckNudgeCount else { return }
        lastDriftCheckAt = now
        nudgesAtLastDriftCheck = stats.nudges
        let coord = AimAssist().resolve(target: target, location: location, date: now)
        guard coord.altitudeDeg > 0 else { return }
        do {
            let outcome = try await GoToController().driftCheck(
                target: coord, location: location, mount: mount,
                io: makeGoToIO(recipe: recipe),
                toleranceDeg: Self.driftToleranceDeg) { [weak self] line in
                    self?.statusDetail = line
                }
            if outcome.corrected {
                stats.driftCorrections += 1
                lastMountActivityAt = hooks.now()
                statusDetail = String(format: "Drift corrected — the frame was %.1f° off "
                                      + "%@.", outcome.driftDeg, target.displayName)
            }
        } catch is CancellationError {
            // The capture loop's checkCancellation right after us handles it.
        } catch let failure as GoToController.Failure {
            // Benign: one missed cross-check. Narrate the honest typed reason —
            // a mount-side refusal must never be blamed on the solve — and only
            // promise nudge tracking when this recipe actually runs it.
            statusDetail = "Drift check skipped — \(failure.fallbackReason) "
                + (recipe.nudgeTracking ? "Nudge tracking continues."
                                        : "Keeping the current aim.")
        } catch {
            statusDetail = "Drift check couldn't finish — "
                + (recipe.nudgeTracking ? "relying on nudge tracking."
                                        : "keeping the current aim.")
        }
    }

    // MARK: Mid-session exposure refinement (measured sky background)

    /// One-shot ISO refinement from the MEASURED sky background: after the
    /// first few observed frames, take the median background and let
    /// `ExposurePlanner.refine` decide — too near saturation drops a stop, a
    /// darker-than-planned sky raises one, anything healthy stands. Evaluated
    /// at most once per session (applied or declined), registered-stack
    /// sessions only (a mid-run gain step would print a visible seam into a
    /// trails blend). Returns true when the adjustment was applied + narrated.
    private func refineExposureIfReady(recipe: inout CaptureRecipe,
                                       style: StackingStyle) -> Bool {
        guard !exposureRefineEvaluated,
              style == .registered,
              backgroundSamples.count >= SessionEngine.refineAfterSamples else { return false }
        exposureRefineEvaluated = true
        let sorted = backgroundSamples.sorted()
        let median = sorted[sorted.count / 2]
        let current = ExposurePlanner.Plan(exposureSeconds: recipe.exposureSeconds,
                                           iso: recipe.iso, note: "")
        guard let tuned = ExposurePlanner.refine(measuredBackground: median,
                                                 current: current) else { return false }
        recipe.iso = tuned.iso
        statusDetail = tuned.note
        return true
    }

    /// Mirror the focus telemetry seam into the published chip values
    /// (only writing on change, like the mount mirrors).
    private func syncFocusTelemetry() {
        let telemetry = hooks.focusTelemetry()
        if focusSharpness != telemetry.sharpness { focusSharpness = telemetry.sharpness }
        if focusSharpnessMean != telemetry.mean { focusSharpnessMean = telemetry.mean }
        if focusDrifting != telemetry.drifting { focusDrifting = telemetry.drifting }
    }

    // MARK: Sky-condition monitoring

    /// Feed one captured frame's measurements to the sky monitor and surface
    /// advice on condition transitions. Prefers the observation `CPUStacker`
    /// already produced for this exact frame (star list + background are
    /// by-products of stacking); falls back to measuring the frame directly on
    /// the same stack grid when the stacker can't provide one (trails blends,
    /// frames skipped during a cloud pause). Returns true when a transition
    /// advice line was posted to `statusDetail`. `feedRefine` is false for
    /// frames the cloud gate skipped: their measured background is clouds, not
    /// sky, and must not contaminate the one-shot exposure refinement's median.
    @discardableResult
    private func observeSky(frame: SubFrame, cpuStacker: CPUStacker?, gated: Bool,
                            feedRefine: Bool = true) -> Bool {
        let observation: SkyObservation?
        if let fromStacker = cpuStacker?.lastSkyObservation,
           fromStacker.timestamp == frame.timestamp {
            observation = fromStacker
        } else if let image = frame.pixelData {
            observation = SkyConditionMonitor.measure(image: image,
                                                      width: captureDims.width,
                                                      height: captureDims.height,
                                                      at: frame.timestamp)
        } else {
            observation = nil
        }
        guard let observation else { return false }
        // Every measured NON-cloud-skipped frame feeds the refinement.
        if feedRefine { backgroundSamples.append(observation.backgroundLevel) }
        let previous = skyCondition
        let updated = skyMonitor.ingest(observation)
        guard updated != previous else { return false }
        skyCondition = updated
        stats.skyCondition = updated
        if let advice = SessionEngine.skyAdvice(from: previous, to: updated, gated: gated) {
            statusDetail = advice
            return true
        }
        return false
    }

    /// Honest one-liners for measured sky-condition transitions. `gated` is true
    /// only when the cloud gate will actually pause the stack for this session
    /// (registered style with `pauseStackingWhenCloudy` on) — the copy must
    /// never promise a pause or a resume that trails/timelapse sessions, which
    /// blend every frame clouds included, do not perform.
    static func skyAdvice(from old: SkyCondition, to new: SkyCondition,
                          gated: Bool) -> String? {
        switch new {
        case .cloudy:
            return gated
                ? "Clouds rolling in — the stack is safe, waiting for a gap…"
                : "Clouds rolling in — star counts have collapsed."
        case .clear:
            if old == .unknown { return nil }
            return gated
                ? "Sky cleared — resuming the stack."
                : "Sky cleared — stars are back."
        case .hazy:
            if old == .unknown {
                return "Hazy sky measured — faint stars are muted tonight."
            }
            if old == .cloudy {
                return gated
                    ? "Clouds thinning to haze — resuming the stack."
                    : "Clouds thinning to haze — some stars are back."
            }
            return "Haze moving in — star counts are dropping."
        case .overexposed:
            return "Sky background is near saturation — too much light here for faint stars."
        case .unknown:
            return nil
        }
    }

    // MARK: Develop — final stack (runs on every save path, full or partial)

    private func developPhase() async {
        phase = .develop
        statusDetail = "Developing — stacking \(stats.subsAccepted) frames…"
        await hooks.endCapture()
        if let final = stacker.finalImage() {
            latestPreview = oriented(final)
        } else if let preview = stacker.currentResult().preview {
            latestPreview = oriented(preview)
        }
    }

    /// Rotate a stacker output so it displays upright for the way the phone was
    /// physically held (Seattle field report: sensor-native landscape frames were
    /// exported sideways). The Logbook thumbnail and the share sheet both read
    /// `latestPreview`, so orienting here fixes every downstream surface at once.
    /// Simulated sources synthesize upright frames — no rotation applies.
    private func oriented(_ image: CGImage?) -> CGImage? {
        guard let image else { return nil }
        guard !hooks.isSimulatedCapture else { return image }
        let rotation = ImageOrientation.rotationToUpright(for: stats.captureTilt)
        return ImageOrientation.rotated(image, by: rotation) ?? image
    }

    // MARK: Pause + flap gateway

    private func waitWhileSuspended() async throws {
        while backgroundPaused || awaitingResume {
            try Task.checkCancellation()
            try await hooks.sleep(pollInterval)
        }
    }

    private func pauseGateway(shot: ShotModeItem) async throws {
        try await waitWhileSuspended()
        guard shot.needsGimbal else { return }
        try await guardFlap()
    }

    /// Undock handling: pause capture immediately, debounce, auto-resume on re-dock,
    /// and mark pointing invalidated (re-dock can recenter the head).
    private func guardFlap() async throws {
        if isDocked { return }
        let flapStart: Date
        if case .flapping(let since) = mount.connection {
            flapStart = since
        } else {
            flapStart = hooks.now()
        }
        interruption = .gimbalFlapping
        statusDetail = "Gimbal connection dropped — capture paused, waiting for re-dock…"
        syncMirrors()
        while true {
            try Task.checkCancellation()
            try await waitWhileSuspended()
            if isDocked {
                stats.flapsRecovered += 1
                pointingInvalidated = true   // never assume pointing continuity after re-dock
                pendingReacquire = true      // GoTo-capable sessions re-verify with a solve
                interruption = nil
                statusDetail = "Gimbal back — check your framing (re-dock can recenter the head)."
                _ = await mount.waitSettled()
                lastMountActivityAt = hooks.now()
                syncMirrors()
                return
            }
            if interruption != .gimbalLost,
               hooks.now().timeIntervalSince(flapStart) > GimbalConstants.flapDebounce {
                interruption = .gimbalLost
                statusDetail = "Gimbal lost — re-dock the phone to resume, or end the session."
            }
            try await hooks.sleep(pollInterval)
            syncMirrors()
        }
    }

    // MARK: Guardians

    private func runGuardians() throws {
        // Thermal: .serious backs the cadence off; .critical stops gracefully and saves.
        let t = hooks.thermalState()
        if thermal != t { thermal = t }
        switch t {
        case .critical:
            interruption = .thermalCritical
            statusDetail = "Phone is too hot — stopping and saving what we have."
            throw Halt.graceful
        case .serious:
            if thermalBackoffSeconds == 0 { thermalBackoffSeconds = 2.0 }
            if interruption == nil {
                interruption = .thermalBackoff
                statusDetail = "Running warm — spacing frames out to cool down."
            }
        default:
            thermalBackoffSeconds = 0
            if interruption == .thermalBackoff { interruption = nil }
        }

        // Phone battery: warn at 30%, stop + save at 20%.
        if let pct = hooks.batteryPercent() {
            if phoneBatteryPercent != pct { phoneBatteryPercent = pct }
            if pct <= 20 {
                interruption = .batteryLow(percent: pct)
                statusDetail = "Battery at \(pct)% — stopping and saving."
                throw Halt.graceful
            } else if pct <= 30 {
                if !batteryWarned {
                    batteryWarned = true
                    if interruption == nil { interruption = .batteryLow(percent: pct) }
                    statusDetail = "Battery at \(pct)% — the session stops automatically at 20%."
                }
            } else if batteryWarned, let cur = interruption, case .batteryLow = cur {
                interruption = nil
            }
        }

        // Storage: stop + save below 1 GB free.
        if let free = hooks.freeDiskBytes(), free < 1_000_000_000 {
            interruption = .storageLow
            statusDetail = "Storage nearly full — stopping and saving."
            throw Halt.graceful
        }

        // Gimbal battery: advisory only (the mount dying mid-hold just becomes a flap).
        if let gb = mount.telemetry?.batteryPercent, gb <= 15, !gimbalBatteryWarned {
            gimbalBatteryWarned = true
            statusDetail = "Gimbal battery at \(gb)% — it may power down soon."
        }
    }

    // MARK: Nudge scheduling (step-and-shoot framing retention)

    private func nudgeIfDue() async throws {
        let now = hooks.now()
        guard let last = lastNudgeAt else {
            lastNudgeAt = now   // cadence clock starts at the first sub
            return
        }
        guard now.timeIntervalSince(last) >= GimbalConstants.nudgeCadence else {
            await keepaliveIfIdle()
            return
        }
        let v = hooks.nudgeVector()
        // Cable-wrap budget: net pan tracking stays within ±360°.
        if abs(netYawDeg + v.deltaYawDeg) > 360 {
            statusDetail = "Cable-wrap budget reached — holding framing without further nudges."
            lastNudgeAt = now
            return
        }
        statusDetail = "Nudging to hold framing…"
        do {
            try await mount.nudge(deltaPitchDeg: v.deltaPitchDeg, deltaYawDeg: v.deltaYawDeg)
            _ = await mount.waitSettled()
            stats.nudges += 1
            netYawDeg += v.deltaYawDeg
        } catch is CancellationError {
            // Propagate only our own cancellation (abort). A motion plan cancelled under
            // us (undock or backgrounding zeroes the motors mid-nudge) must not end the
            // session — the pause/flap gateway picks it up on the next loop pass.
            try Task.checkCancellation()
            statusDetail = "Nudge interrupted — holding framing."
        } catch {
            statusDetail = "Nudge refused (pitch envelope?) — continuing without it."
        }
        lastNudgeAt = now
        lastMountActivityAt = hooks.now()
    }

    // MARK: Keepalive (defeat firmware inactivity sleep during idle gaps)

    private func keepaliveIfIdle() async {
        guard hooks.now().timeIntervalSince(lastMountActivityAt) > GimbalConstants.keepalivePeriod
        else { return }
        await mount.keepalivePulse()
        lastMountActivityAt = hooks.now()
    }

    // MARK: Interval waits (chunked so keepalive + pause checks keep running)

    private func waitGap(_ seconds: TimeInterval, shot: ShotModeItem) async throws {
        var remaining = seconds
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = min(1.0, remaining)
            try await hooks.sleep(chunk)
            remaining -= chunk
            if shot.needsGimbal { await keepaliveIfIdle() }
            try await pauseGateway(shot: shot)
        }
    }

    // MARK: Mirrors + helpers

    private var isDocked: Bool {
        if case .docked = mount.connection { return true }
        return false
    }

    private func syncMirrors() {
        if mountConnection != mount.connection { mountConnection = mount.connection }
        if mountAuthority != mount.authority { mountAuthority = mount.authority }
        if mountTelemetry != mount.telemetry { mountTelemetry = mount.telemetry }
    }

    private func completionSummary() -> String {
        let minutes = Int(stats.integrationSeconds) / 60
        let seconds = Int(stats.integrationSeconds) % 60
        var line = "\(stats.subsAccepted) frames · \(minutes)m \(seconds)s integrated"
        if stats.nudges > 0 { line += " · \(stats.nudges) nudges" }
        if stats.driftCorrections > 0 { line += " · \(stats.driftCorrections) drift fixes" }
        if stats.flapsRecovered > 0 { line += " · \(stats.flapsRecovered) reconnects" }
        if stats.subsSkippedClouds > 0 {
            line += " · \(stats.subsSkippedClouds) cloud frames waited out"
        }
        return line
    }
}
