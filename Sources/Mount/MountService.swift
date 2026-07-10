import Foundation
import Combine

#if canImport(DockKit) && !targetEnvironment(simulator)
import DockKit
import Spatial
#endif

// MARK: - Errors

public enum MountError: LocalizedError, Equatable {
    case notConnected
    case noAuthority
    case pitchOutOfEnvelope(targetDeg: Double)
    case busy

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The gimbal isn't connected. Dock your phone on the Flow 2 Pro and try again."
        case .noAuthority:
            return "The gimbal hasn't handed over motor control. Squeeze the trigger once — the tracking light should come on."
        case .pitchOutOfEnvelope(let target):
            return String(format: "That aim needs %.1f° of pitch — the gimbal can only reach %.1f° to %.1f°. Pick a lower target or re-frame.",
                          target, GimbalConstants.pitchMinDeg, GimbalConstants.pitchMaxDeg)
        case .busy:
            return "The gimbal is already moving. Wait for the current move to finish."
        }
    }
}

// MARK: - Events

/// One-shot notifications for the session engine (state is also observable via @Published).
public enum MountEvent: Equatable, Sendable {
    case docked(name: String)
    case flapping                       // undocked, inside the debounce window — auto-recovering
    case flapRecovered                  // re-docked within debounce; pointing must be re-verified
    case undocked                       // undock outlived the debounce
    case authorityChanged(MountAuthority)
    case cableWrapWarning(netPanDeg: Double)
}

// MARK: - Mount service

/// Velocity-impulse controller for the Insta360 Flow 2 Pro over DockKit.
///
/// Control law (measured, non-negotiable): velocity impulses only — `setOrientation`
/// dead-bands below ~1.5° and flaps the session. Commands expire after ~2.6 s, so
/// sustained slews re-issue `setAngularVelocity` well inside `GimbalConstants.velocityExpiry`.
/// On simulator (or platforms without DockKit) a simulated docked mount integrates
/// commanded impulses so the whole UI and session flow run without hardware.
@MainActor
public final class MountService: ObservableObject, MountControlling {

    public static let shared = MountService()

    // MARK: Observable state

    @Published public private(set) var connection: MountConnection = .searching
    @Published public private(set) var authority: MountAuthority = .unknown
    @Published public private(set) var telemetry: MountTelemetry?
    /// Net pan since session start / last reset (deg, signed). Cable-wrap budget is ±360°.
    @Published public private(set) var netPanDeg: Double = 0
    @Published public private(set) var cableWrapWarning: Bool = false

    /// Single-consumer event hook (intended for the session engine).
    public var onEvent: ((MountEvent) -> Void)?

    // MARK: Private state

    private var started = false
    private var monitorTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var flapTask: Task<Void, Never>?
    private var motionTask: Task<Void, Error>?
    private var motionToken = 0

    private var wrap = CableWrapAccumulator()
    private var sampleCounter = 0            // bumps on every fresh encoder sample
    private var lastSampleAt: Date?
    private var estPitchDeg = 0.0            // last known encoder angles (fallbacks)
    private var estYawDeg = 0.0

    #if canImport(DockKit) && !targetEnvironment(simulator)
    private var accessory: DockAccessory?
    #else
    private let sim = SimulatedGimbal()
    #endif

    private init() {}

    // MARK: MountControlling

    public func start() {
        guard !started else { return }
        started = true
        #if canImport(DockKit) && !targetEnvironment(simulator)
        startHardwareMonitor()
        #else
        startSimulatedMount()
        #endif
    }

    /// Zero velocity and cancel any motion plan. Called on every exit path:
    /// backgrounding, session stop, errors, undocks.
    public func stopEverything() async {
        motionTask?.cancel()
        motionTask = nil
        await sendZero()
    }

    /// GoTo move: closed-loop slew re-issuing `setAngularVelocity` every 0.2 s
    /// (well inside the ~2.6 s firmware watchdog) with proportional deceleration
    /// near the target. Refuses targets outside the measured pitch envelope.
    public func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {
        try ensureReady()
        let fromPitch = telemetry?.pitchDeg ?? estPitchDeg
        let fromYaw = telemetry?.yawDeg ?? estYawDeg
        let targetPitch = fromPitch + deltaPitchDeg
        let targetYaw = fromYaw + deltaYawDeg
        guard PitchEnvelope.isWithin(targetPitch) else {
            throw MountError.pitchOutOfEnvelope(targetDeg: targetPitch)
        }
        try await runExclusiveMotion { [weak self] in
            guard let self else { return }
            try await self.slewLoop(targetPitchDeg: targetPitch, targetYawDeg: targetYaw)
        }
    }

    /// Fine framing move: open-loop velocity impulses (angle = rate × time),
    /// yaw first then pitch, each solved by `NudgePlanner.impulse` so the rate
    /// never dips below the measured velocity floor.
    public func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {
        try ensureReady()
        let fromPitch = telemetry?.pitchDeg ?? estPitchDeg
        guard PitchEnvelope.allowsMove(fromDeg: fromPitch, deltaDeg: deltaPitchDeg) else {
            throw MountError.pitchOutOfEnvelope(targetDeg: fromPitch + deltaPitchDeg)
        }
        try await runExclusiveMotion { [weak self] in
            guard let self else { return }
            try await self.executeImpulses(deltaDeg: deltaYawDeg, axis: .yaw)
            try await self.executeImpulses(deltaDeg: deltaPitchDeg, axis: .pitch)
        }
    }

    /// True once 3 fresh encoder samples in a row report |ω| below
    /// `GimbalConstants.settleThreshold`; false on `settleTimeout`.
    public func waitSettled() async -> Bool {
        let thresholdDegPerSec = GimbalConstants.settleThreshold * 180.0 / .pi
        let deadline = Date().addingTimeInterval(GimbalConstants.settleTimeout)
        let pollNanos = UInt64(0.5 / GimbalConstants.encoderRateHz * 1_000_000_000)
        var lastSeen = sampleCounter
        var freshBelow = 0
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollNanos)
            if Task.isCancelled { return false }
            guard sampleCounter != lastSeen else { continue }   // only count FRESH samples
            lastSeen = sampleCounter
            guard let t = telemetry else { continue }
            if abs(t.speedDegPerSec) < thresholdDegPerSec {
                freshBelow += 1
                if freshBelow >= 3 { return true }
            } else {
                freshBelow = 0
            }
        }
        return false
    }

    /// Net-zero micro-motion that defeats the firmware inactivity sleep during long
    /// capture gaps. Each half-pulse is ~0.003° — under half an encoder tick, so the
    /// frame never moves. Schedule every `GimbalConstants.keepalivePeriod`.
    public func keepalivePulse() async {
        guard case .docked = connection, authority == .granted, motionTask == nil else { return }
        let v = GimbalConstants.velocityFloor
        await sendVelocity(pitchRadPerSec: 0, yawRadPerSec: v)
        try? await Task.sleep(nanoseconds: 30_000_000)
        await sendVelocity(pitchRadPerSec: 0, yawRadPerSec: -v)
        try? await Task.sleep(nanoseconds: 30_000_000)
        await sendZero()
    }

    // MARK: Cable wrap

    /// Zero the net-pan accumulator (after the user physically unwinds the setup).
    public func resetCableWrap() {
        wrap.reset()
        netPanDeg = 0
        if cableWrapWarning { cableWrapWarning = false }
    }

    // MARK: Guards & exclusive motion

    private func ensureReady() throws {
        guard case .docked = connection else { throw MountError.notConnected }
        guard authority == .granted else { throw MountError.noAuthority }
    }

    /// Runs one motion plan at a time. Whatever happens — success, error, cancellation
    /// via `stopEverything()` — velocity is zeroed before control returns.
    private func runExclusiveMotion(_ body: @escaping @MainActor () async throws -> Void) async throws {
        guard motionTask == nil else { throw MountError.busy }
        let task = Task { @MainActor in try await body() }
        motionToken &+= 1
        let token = motionToken
        motionTask = task
        defer { if motionToken == token { motionTask = nil } }
        do {
            try await task.value
            await sendZero()
        } catch {
            await sendZero()
            throw error
        }
    }

    // MARK: Impulse execution

    private enum MotionAxis { case pitch, yaw }

    private func executeImpulses(deltaDeg: Double, axis: MotionAxis) async throws {
        var remaining = deltaDeg
        var chained = 0
        while let imp = NudgePlanner.impulse(forDeltaDeg: remaining), chained < 8 {
            try Task.checkCancellation()
            switch axis {
            case .pitch: await sendVelocity(pitchRadPerSec: imp.rateRadPerSec, yawRadPerSec: 0)
            case .yaw: await sendVelocity(pitchRadPerSec: 0, yawRadPerSec: imp.rateRadPerSec)
            }
            try await sleepSeconds(imp.durationSeconds)
            await sendZero()
            remaining -= imp.angleDeg
            chained += 1
            if abs(remaining) < GimbalConstants.encoderTickDeg / 2.0 { break }
            try await sleepSeconds(0.08)    // let the motors breathe between chained pulses
        }
    }

    // MARK: Slew loop

    private func slewLoop(targetPitchDeg: Double, targetYawDeg: Double) async throws {
        let toleranceDeg = 0.1
        let controlPeriod = 0.2             // s — re-issue interval, far inside velocityExpiry
        let gain = 1.2                      // 1/s — proportional deceleration near target
        let travelDeg = max(abs(targetPitchDeg - (telemetry?.pitchDeg ?? estPitchDeg)),
                            abs(targetYawDeg - (telemetry?.yawDeg ?? estYawDeg)))
        let deadline = Date().addingTimeInterval(10.0 + travelDeg / 5.0)
        while true {
            try Task.checkCancellation()
            let remPitch = targetPitchDeg - (telemetry?.pitchDeg ?? estPitchDeg)
            let remYaw = targetYawDeg - (telemetry?.yawDeg ?? estYawDeg)
            if abs(remPitch) <= toleranceDeg && abs(remYaw) <= toleranceDeg { break }
            if Date() >= deadline { break }
            await sendVelocity(
                pitchRadPerSec: proportionalRate(remainingDeg: remPitch, gain: gain, toleranceDeg: toleranceDeg),
                yawRadPerSec: proportionalRate(remainingDeg: remYaw, gain: gain, toleranceDeg: toleranceDeg))
            try await sleepSeconds(controlPeriod)
        }
        await sendZero()
    }

    private func proportionalRate(remainingDeg: Double, gain: Double, toleranceDeg: Double) -> Double {
        guard abs(remainingDeg) > toleranceDeg else { return 0 }
        let remRad = remainingDeg * .pi / 180.0
        var mag = abs(remRad) * gain
        mag = min(mag, GimbalConstants.slewRate)
        mag = max(mag, GimbalConstants.velocityFloor)
        return remainingDeg < 0 ? -mag : mag
    }

    private func sleepSeconds(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    // MARK: Connection state machine (shared by hardware and simulator paths)

    private func handleDocked(name: String) {
        flapTask?.cancel()
        flapTask = nil
        let wasFlapping: Bool
        if case .flapping = connection { wasFlapping = true } else { wasFlapping = false }
        connection = .docked(name: name)
        onEvent?(wasFlapping ? .flapRecovered : .docked(name: name))
    }

    private func handleUndocked() {
        guard case .docked = connection else { return }   // .searching / .flapping / .undocked: no-op
        motionTask?.cancel()
        motionTask = nil
        Task { [weak self] in await self?.sendZero() }
        connection = .flapping(since: Date())
        onEvent?(.flapping)
        flapTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(GimbalConstants.flapDebounce * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if case .flapping = self.connection {
                self.connection = .undocked
                self.authority = .unknown
                self.onEvent?(.undocked)
            }
        }
    }

    private func setAuthority(_ newValue: MountAuthority) {
        guard newValue != authority else { return }
        authority = newValue
        onEvent?(.authorityChanged(newValue))
    }

    // MARK: Telemetry ingest (shared)

    private func ingestEncoderSample(pitchDeg: Double, yawDeg: Double, batteryPercent: Int?) {
        let now = Date()
        var speed = 0.0
        if let last = lastSampleAt, let prev = telemetry {
            let dt = now.timeIntervalSince(last)
            if dt > 0 {
                let dPitch = pitchDeg - prev.pitchDeg
                let dYaw = CableWrapAccumulator.shortestDeltaDeg(from: prev.yawDeg, to: yawDeg)
                speed = (dPitch * dPitch + dYaw * dYaw).squareRoot() / dt
            }
        }
        lastSampleAt = now
        estPitchDeg = pitchDeg
        estYawDeg = yawDeg

        wrap.recordYawSample(yawDeg)
        if netPanDeg != wrap.netPanDeg { netPanDeg = wrap.netPanDeg }
        let pastBudget = wrap.isPastBudget
        if pastBudget != cableWrapWarning {
            cableWrapWarning = pastBudget
            if pastBudget { onEvent?(.cableWrapWarning(netPanDeg: wrap.netPanDeg)) }
        }

        telemetry = MountTelemetry(pitchDeg: pitchDeg, yawDeg: yawDeg,
                                   speedDegPerSec: speed, batteryPercent: batteryPercent)
        sampleCounter &+= 1
    }

    // MARK: Velocity transport

    private func sendZero() async {
        await sendVelocity(pitchRadPerSec: 0, yawRadPerSec: 0)
    }

    private func sendVelocity(pitchRadPerSec: Double, yawRadPerSec: Double) async {
        #if canImport(DockKit) && !targetEnvironment(simulator)
        guard let acc = accessory else { return }
        do {
            // DockKit axes: x = pitch, y = yaw, z = roll (roll is inert on the Flow 2 Pro).
            try await acc.setAngularVelocity(Vector3D(x: pitchRadPerSec, y: yawRadPerSec, z: 0))
        } catch {
            // Undock race — the state-change stream drives recovery.
        }
        #else
        sim.setVelocity(pitchRadPerSec: pitchRadPerSec, yawRadPerSec: yawRadPerSec)
        #endif
    }

    // MARK: Hardware path

    #if canImport(DockKit) && !targetEnvironment(simulator)

    private func startHardwareMonitor() {
        monitorTask = Task { [weak self] in
            // Take manual control: system subject tracking off, we drive velocities.
            do { try await DockAccessoryManager.shared.setSystemTrackingEnabled(false) } catch {}
            do {
                for try await change in try DockAccessoryManager.shared.accessoryStateChanges {
                    guard let self, !Task.isCancelled else { break }
                    self.applyStateChange(change)
                }
            } catch {
                self?.connection = .undocked
            }
        }
    }

    private func applyStateChange(_ change: DockAccessory.StateChange) {
        // Motor authority rides on the tracking-button state: trigger squeeze enables it,
        // and it auto-restores after re-docks (measured, bench run 3).
        setAuthority(change.trackingButtonEnabled ? .granted : .denied)

        switch change.state {
        case .docked:
            if let acc = change.accessory {
                accessory = acc
                let alreadyDocked: Bool
                if case .docked = connection { alreadyDocked = true } else { alreadyDocked = false }
                if !alreadyDocked {
                    startHardwareTelemetry(acc)
                    handleDocked(name: "Flow 2 Pro")
                }
            }
        default:
            telemetryTask?.cancel()
            telemetryTask = nil
            handleUndocked()
        }
    }

    private func startHardwareTelemetry(_ acc: DockAccessory) {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            do {
                for try await motion in try acc.motionStates {
                    guard let self, !Task.isCancelled else { break }
                    let pos = motion.angularPositions
                    self.ingestEncoderSample(pitchDeg: pos.x * 180.0 / .pi,
                                             yawDeg: pos.y * 180.0 / .pi,
                                             batteryPercent: nil)
                }
            } catch {
                // Stream ends on undock; the state-change machine handles recovery.
            }
        }
    }

    #else

    // MARK: Simulator path — a docked mount whose telemetry integrates commanded impulses.

    private func startSimulatedMount() {
        monitorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)      // brief "searching" moment
            guard let self, !Task.isCancelled else { return }
            self.setAuthority(.granted)
            self.handleDocked(name: "Flow 2 Pro (Simulated)")
            let tickNanos = UInt64(1_000_000_000.0 / GimbalConstants.encoderRateHz)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: tickNanos)
                if Task.isCancelled { break }
                if case .docked = self.connection {
                    let s = self.sim.tick()
                    self.ingestEncoderSample(pitchDeg: s.pitchDeg, yawDeg: s.yawDeg,
                                             batteryPercent: s.batteryPercent)
                }
            }
        }
    }

    #endif

    // MARK: Simulator edge-case hooks (no-ops on hardware builds)

    /// Simulate a mid-session undock (starts the flap debounce). Simulator builds only.
    public func debugSimulateUndock() {
        #if !canImport(DockKit) || targetEnvironment(simulator)
        handleUndocked()
        #endif
    }

    /// Simulate a re-dock. `recenterPitch` reproduces the measured +22° pitch jump,
    /// so downstream "re-verify pointing after re-dock" flows can be exercised.
    public func debugSimulateRedock(recenterPitch: Bool = true) {
        #if !canImport(DockKit) || targetEnvironment(simulator)
        if recenterPitch { sim.recenterAfterRedock() }
        handleDocked(name: "Flow 2 Pro (Simulated)")
        setAuthority(.granted)   // trackingButtonEnabled auto-restores after re-dock (measured)
        #endif
    }

    /// Simulate the trigger squeeze / authority toggle. Simulator builds only.
    public func debugSimulateAuthority(granted: Bool) {
        #if !canImport(DockKit) || targetEnvironment(simulator)
        setAuthority(granted ? .granted : .denied)
        #endif
    }
}

// MARK: - Simulated gimbal

#if !canImport(DockKit) || targetEnvironment(simulator)

/// Physics stand-in for the Flow 2 Pro: integrates commanded angular velocity into
/// pitch/yaw, honors the measured velocity floor, expires commands after ~2.6 s
/// (the firmware watchdog), hard-stops at the pitch envelope, and quantizes reported
/// angles to the 0.00716° encoder tick.
private final class SimulatedGimbal {
    private var pitchDeg = 4.0
    private var yawDeg = 0.0
    private var cmdPitchRadPerSec = 0.0
    private var cmdYawRadPerSec = 0.0
    private var cmdIssuedAt: Date?
    private var lastIntegratedAt = Date()
    private let bootedAt = Date()
    /// Measured firmware watchdog: velocity commands lapse ~2.6 s after issue.
    private let commandLifetime: TimeInterval = 2.6

    func setVelocity(pitchRadPerSec: Double, yawRadPerSec: Double) {
        integrate(to: Date())
        cmdPitchRadPerSec = abs(pitchRadPerSec) >= GimbalConstants.velocityFloor ? pitchRadPerSec : 0
        cmdYawRadPerSec = abs(yawRadPerSec) >= GimbalConstants.velocityFloor ? yawRadPerSec : 0
        cmdIssuedAt = (cmdPitchRadPerSec != 0 || cmdYawRadPerSec != 0) ? Date() : nil
    }

    /// Re-docks can recenter the gimbal — a +22° pitch jump was observed on hardware.
    func recenterAfterRedock() {
        integrate(to: Date())
        pitchDeg = min(GimbalConstants.pitchMaxDeg, pitchDeg + 22.0)
    }

    func tick() -> (pitchDeg: Double, yawDeg: Double, batteryPercent: Int) {
        integrate(to: Date())
        let q = GimbalConstants.encoderTickDeg
        let battery = max(15, 82 - Int(Date().timeIntervalSince(bootedAt) / 600.0))
        return ((pitchDeg / q).rounded() * q, (yawDeg / q).rounded() * q, battery)
    }

    private func integrate(to now: Date) {
        defer { lastIntegratedAt = now }
        guard let issuedAt = cmdIssuedAt else { return }
        let activeEnd = min(now, issuedAt.addingTimeInterval(commandLifetime))
        let activeStart = max(lastIntegratedAt, issuedAt)
        let dt = activeEnd.timeIntervalSince(activeStart)
        if dt > 0 {
            let degPerRad = 180.0 / Double.pi
            pitchDeg += cmdPitchRadPerSec * dt * degPerRad
            yawDeg += cmdYawRadPerSec * dt * degPerRad
            pitchDeg = min(max(pitchDeg, GimbalConstants.pitchMinDeg), GimbalConstants.pitchMaxDeg)
        }
        if now >= issuedAt.addingTimeInterval(commandLifetime) {
            cmdPitchRadPerSec = 0
            cmdYawRadPerSec = 0
            cmdIssuedAt = nil
        }
    }
}

#endif
