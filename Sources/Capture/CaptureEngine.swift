import Foundation
import SwiftUI
import AVFoundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Errors

public enum CaptureError: LocalizedError {
    case notAuthorized
    case cameraUnavailable
    case configurationFailed(String)
    case insufficientStorage(neededBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Camera access is off. StarFlow needs the camera to capture star exposures — enable it in Settings."
        case .cameraUnavailable:
            return "The main wide camera is unavailable."
        case .configurationFailed(let detail):
            return "Camera setup failed (\(detail))."
        case .insufficientStorage(let needed):
            return "Not enough free space for this session — it needs about "
                + "\(StorageBudget.format(needed)) plus a safety reserve. Free up storage and try again."
        }
    }
}

// MARK: - CaptureEngine

/// Bench-proven night-sky capture loop (see docs/DESIGN.md — Capture module).
///
/// Device pattern (measured on iPhone: gapless 1.00–1.05 s per frame):
///  - `AVCaptureSession` with `.photo` preset on the main back wide camera.
///  - `setExposureModeCustom(min(1 s, maxExposureDuration), iso)` — 1 s is the hard
///    third-party exposure cap; "long exposure" is stacking 1 s subs, never one long frame.
///  - Focus locked at the infinity end of lens travel (`lensPosition` 1.0).
///  - Zero-shutter-lag and responsive capture OFF (they break custom-exposure pacing).
///  - Sequential capture: the next `capturePhoto` is issued from the previous frame's
///    `didFinishCapture` callback — no timers in the hot loop, no overlap.
///  - Bayer RAW is requested alongside the processed frame when the output supports it;
///    v1 stacks the processed frame's CGImage.
///  - `pause()` / `resume()` bracket gimbal nudge windows so no frame is exposed
///    while the mount is moving.
///
/// Simulator: a timer-driven synthetic starfield (drifting gaussian stars + noise)
/// feeds the same `onFrame` path so the whole app runs without hardware.
///
/// Thermal and battery state are exposed as published values; the session engine
/// applies the backoff policy (serious → longer gaps, critical → graceful stop).
///
/// Capture intelligence (see ExposurePlanner.swift):
///  - `start(recipe:quality:)` runs the base recipe through `ExposurePlanner` first.
///  - Per-frame star-focus telemetry (`focusSharpness` & friends) is computed off the
///    hot path, so the gapless pacing is untouched.
///  - `start` refuses up front when `StorageBudget` says the plan can't fit on disk.
@MainActor
public final class CaptureEngine: ObservableObject {

    public static let shared = CaptureEngine()

    // MARK: Published telemetry

    @Published public private(set) var isRunning = false
    @Published public private(set) var isPaused = false
    @Published public private(set) var framesDelivered = 0
    @Published public private(set) var lastFrameAt: Date?
    /// Measured wall-clock gap between the last two delivered frames (bench: 1.00–1.05 s).
    @Published public private(set) var lastGapSeconds: Double?
    @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published public private(set) var batteryPercent: Int?
    @Published public private(set) var isCharging = false
    @Published public private(set) var authorizationDenied = false
    /// Star-focus telemetry (see FocusMetric): variance-of-Laplacian sharpness of the
    /// newest frame, its rolling mean, and a "focus drifted" alarm. Higher = sharper.
    @Published public private(set) var focusSharpness: Double?
    @Published public private(set) var focusSharpnessMean: Double?
    @Published public private(set) var focusDrifting = false

    /// Per-frame delivery. Called on the main actor with each captured sub.
    public var onFrame: ((SubFrame) -> Void)?

    public private(set) var activeRecipe = CaptureRecipe(exposureSeconds: 1.0, iso: 800,
                                                         targetSubCount: 120, nudgeTracking: true)

    /// Extra inter-frame gap recommended for the current thermal state.
    /// `.critical` should end the session (session engine's call); the gap here is a stopgap.
    public var thermalExtraGapSeconds: Double {
        switch thermalState {
        case .serious: return 1.0
        case .critical: return 4.0
        default: return 0
        }
    }

    // MARK: Private state

    private var frameIndex = 0
    private var appliedExposureSeconds: Double = 1.0
    private var appliedISO: Double = 800
    private var observerTokens: [NSObjectProtocol] = []
    private var focusWindow = RollingSharpness(window: 10)

    #if targetEnvironment(simulator)
    private var simTask: Task<Void, Never>?
    private var synth = SyntheticStarField(seed: 0x5EED_1E55)
    #else
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.chinmay.starflow.capture.session")
    private var camera: AVCaptureDevice?
    private var rawFormat: OSType?
    private var isConfigured = false
    private var captureInFlight = false
    private var proxies: [Int64: PhotoCaptureProxy] = [:]
    #endif

    public init() {
        thermalState = ProcessInfo.processInfo.thermalState
        observeEnvironment()
    }

    // MARK: - Lifecycle

    /// Run the mode's base recipe through `ExposurePlanner` for the user's sky
    /// quality, then start the capture loop with the planned exposure/ISO.
    public func start(recipe: CaptureRecipe, quality: SkyQuality) async throws {
        try await start(recipe: ExposurePlanner.adjustedRecipe(base: recipe, quality: quality))
    }

    /// Pre-flight storage verdict for a planned session (UI hook: warn before starting).
    public nonisolated static func storagePreflight(recipe: CaptureRecipe,
                                                    keepingSubs: Bool) -> StorageBudget.Verdict {
        StorageBudget.verdict(
            freeBytes: StorageBudget.systemFreeBytes(),
            plannedBytes: StorageBudget.plannedSessionBytes(recipe: recipe,
                                                            keepingSubs: keepingSubs))
    }

    /// Configure (once) and start the sequential capture loop with the given recipe.
    public func start(recipe: CaptureRecipe) async throws {
        guard !isRunning else { return }
        // Storage pre-flight: refuse to start a session plan the disk can't hold
        // ("keep RAW subs" persists ~30 MB per frame — see StorageBudget).
        let plannedBytes = StorageBudget.plannedSessionBytes(
            recipe: recipe, keepingSubs: UserDefaults.standard.bool(forKey: "keepSubs"))
        if case .refuse = StorageBudget.verdict(freeBytes: StorageBudget.systemFreeBytes(),
                                                plannedBytes: plannedBytes) {
            throw CaptureError.insufficientStorage(neededBytes: plannedBytes)
        }
        activeRecipe = recipe
        appliedExposureSeconds = min(recipe.exposureSeconds, 1.0)
        appliedISO = recipe.iso
        frameIndex = 0
        framesDelivered = 0
        lastFrameAt = nil
        lastGapSeconds = nil
        focusWindow.reset()
        focusSharpness = nil
        focusSharpnessMean = nil
        focusDrifting = false

        #if targetEnvironment(simulator)
        isRunning = true
        isPaused = false
        startSimulatedLoop()
        #else
        try await ensureAuthorized()
        try await configureIfNeeded(recipe: recipe)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [session = self.session] in
                if !session.isRunning { session.startRunning() }
                continuation.resume()
            }
        }
        // AVCaptureSession reverts custom exposure when it starts running, so the
        // lock must be RE-applied after startRunning and we must WAIT until the
        // sensor is genuinely integrating near the target before the first capture
        // (bench-measured: firing early yields ~8 ms auto-exposure frames at 15 fps).
        if let camera {
            _ = try? await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Double, Double), Error>) in
                sessionQueue.async { [recipe = self.activeRecipe] in
                    do { cont.resume(returning: try Self.lockNightExposure(on: camera, recipe: recipe)) }
                    catch { cont.resume(throwing: error) }
                }
            }
            let target = min(activeRecipe.exposureSeconds, 1.0)
            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline {
                let current = CMTimeGetSeconds(camera.exposureDuration)
                if current >= target * 0.5 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            appliedExposureSeconds = CMTimeGetSeconds(camera.exposureDuration)
            appliedISO = Double(camera.iso)
        }
        isRunning = true
        isPaused = false
        captureNext()
        #endif
    }

    /// Stop the loop and the session. Any in-flight frame is dropped.
    public func stop() {
        isRunning = false
        isPaused = false
        #if targetEnvironment(simulator)
        simTask?.cancel()
        simTask = nil
        #else
        // Disown any in-flight capture so its late completion can't leak a stale
        // frame (or clobber `captureInFlight`) into a session started after us.
        proxies.removeAll()
        captureInFlight = false
        sessionQueue.async { [session = self.session] in
            if session.isRunning { session.stopRunning() }
        }
        #endif
    }

    /// Pause frame issuing (nudge window: never capture during motion).
    /// The in-flight exposure finishes and is delivered; no new one starts.
    public func pause() {
        guard isRunning else { return }
        isPaused = true
    }

    /// Resume the sequential loop after a nudge window.
    public func resume() {
        guard isRunning, isPaused else { return }
        isPaused = false
        #if !targetEnvironment(simulator)
        if !captureInFlight { captureNext() }
        #endif
    }

    // MARK: - Environment observers

    private func observeEnvironment() {
        let thermal = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.thermalState = ProcessInfo.processInfo.thermalState }
        }
        observerTokens.append(thermal)

        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshBattery() }
            }
            observerTokens.append(token)
        }
        #endif
    }

    #if canImport(UIKit)
    private func refreshBattery() {
        let device = UIDevice.current
        let level = device.batteryLevel
        batteryPercent = level >= 0 ? Int((level * 100).rounded()) : nil
        isCharging = device.batteryState == .charging || device.batteryState == .full
    }
    #endif

    // MARK: - Frame delivery (shared)

    private func deliver(image: CGImage?) {
        guard let image else { return }
        let now = Date()
        if let last = lastFrameAt { lastGapSeconds = now.timeIntervalSince(last) }
        lastFrameAt = now
        let sub = SubFrame(index: frameIndex, timestamp: now,
                           exposureSeconds: appliedExposureSeconds,
                           iso: appliedISO, pixelData: image)
        frameIndex += 1
        framesDelivered += 1
        onFrame?(sub)
        updateFocusMetric(with: image)
    }

    /// Focus telemetry runs detached at utility priority: the ~128 px downscale +
    /// Laplacian never sits between `didFinishCapture` and the next `capturePhoto`,
    /// so the measured gapless pacing (1.00–1.05 s per frame) stays intact.
    private func updateFocusMetric(with image: CGImage) {
        Task.detached(priority: .utility) { [weak self] in
            guard let sharpness = FocusMetric.sharpness(of: image) else { return }
            await self?.recordFocusSample(sharpness)
        }
    }

    private func recordFocusSample(_ sharpness: Double) {
        focusWindow.record(sharpness)
        focusSharpness = sharpness
        focusSharpnessMean = focusWindow.mean
        focusDrifting = focusWindow.isDegraded()
    }

    // MARK: - Device capture path

    #if !targetEnvironment(simulator)

    private struct ConfigOutcome {
        let camera: AVCaptureDevice
        let rawFormat: OSType?
        let exposureSeconds: Double
        let iso: Double
    }

    private func ensureAuthorized() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationDenied = false
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationDenied = !granted
            if !granted { throw CaptureError.notAuthorized }
        default:
            authorizationDenied = true
            throw CaptureError.notAuthorized
        }
    }

    private func configureIfNeeded(recipe: CaptureRecipe) async throws {
        if isConfigured {
            guard let camera else { throw CaptureError.cameraUnavailable }
            let result: Result<(Double, Double), Error> = await withCheckedContinuation { continuation in
                sessionQueue.async {
                    do {
                        let applied = try Self.lockNightExposure(on: camera, recipe: recipe)
                        continuation.resume(returning: .success(applied))
                    } catch {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
            let applied = try result.get()
            appliedExposureSeconds = applied.0
            appliedISO = applied.1
            return
        }

        let result: Result<ConfigOutcome, Error> = await withCheckedContinuation { continuation in
            sessionQueue.async { [session = self.session, photoOutput = self.photoOutput] in
                do {
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    session.sessionPreset = .photo

                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                               for: .video, position: .back) else {
                        throw CaptureError.cameraUnavailable
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw CaptureError.configurationFailed("cannot add camera input")
                    }
                    session.addInput(input)
                    guard session.canAddOutput(photoOutput) else {
                        throw CaptureError.configurationFailed("cannot add photo output")
                    }
                    session.addOutput(photoOutput)

                    // Bench-proven pacing: speed prioritization, ZSL and responsive capture OFF.
                    photoOutput.maxPhotoQualityPrioritization = .speed
                    if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = false }
                    if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = false }

                    let raw = photoOutput.availableRawPhotoPixelFormatTypes
                        .first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })

                    let applied = try Self.lockNightExposure(on: device, recipe: recipe)
                    continuation.resume(returning: .success(
                        ConfigOutcome(camera: device, rawFormat: raw,
                                      exposureSeconds: applied.0, iso: applied.1)))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        let outcome = try result.get()
        camera = outcome.camera
        rawFormat = outcome.rawFormat
        appliedExposureSeconds = outcome.exposureSeconds
        appliedISO = outcome.iso
        isConfigured = true
    }

    /// Custom exposure at min(1 s, format max) + clamped ISO + locked infinity focus.
    /// Returns the (exposureSeconds, iso) actually applied after clamping.
    private nonisolated static func lockNightExposure(on device: AVCaptureDevice,
                                                      recipe: CaptureRecipe) throws -> (Double, Double) {
        do {
            try device.lockForConfiguration()
        } catch {
            throw CaptureError.configurationFailed("device lock: \(error.localizedDescription)")
        }
        defer { device.unlockForConfiguration() }

        var appliedSeconds = min(recipe.exposureSeconds, 1.0)
        var appliedISO = recipe.iso
        if device.isExposureModeSupported(.custom) {
            let format = device.activeFormat
            var duration = CMTime(seconds: appliedSeconds, preferredTimescale: 1_000_000_000)
            if duration > format.maxExposureDuration { duration = format.maxExposureDuration }
            if duration < format.minExposureDuration { duration = format.minExposureDuration }
            let iso = max(format.minISO, min(Float(recipe.iso), format.maxISO))
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            appliedSeconds = CMTimeGetSeconds(duration)
            appliedISO = Double(iso)
        }
        if device.isLockingFocusWithCustomLensPositionSupported {
            // lensPosition 1.0 = far end of travel (stars live at infinity).
            device.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil)
        } else if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        return (appliedSeconds, appliedISO)
    }

    /// Focus-sweep support: move the lens to `position` (0…1; 1.0 = the infinity
    /// end this engine locks by default) and await the physical move. The
    /// sequential capture loop keeps running — the exposure already in flight
    /// spans the move (the sweep burns it as a settle frame, see
    /// `FocusSweepPlan.settleFramesPerStep`); frames exposed after it see the
    /// new position. No-op when the camera isn't configured or custom lens
    /// positions are unsupported.
    public func setLensPosition(_ position: Float) async {
        guard let camera else { return }
        let clamped = max(0, min(1, position))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                guard camera.isLockingFocusWithCustomLensPositionSupported else {
                    continuation.resume()
                    return
                }
                do {
                    try camera.lockForConfiguration()
                } catch {
                    continuation.resume()
                    return
                }
                camera.setFocusModeLocked(lensPosition: clamped) { _ in
                    continuation.resume()
                }
                camera.unlockForConfiguration()
            }
        }
    }

    /// Issue one capture; the next one is chained from `didFinishCapture`.
    private func captureNext() {
        guard isRunning, !isPaused, !captureInFlight else { return }
        captureInFlight = true

        let settings: AVCapturePhotoSettings
        if let raw = rawFormat, photoOutput.availableRawPhotoPixelFormatTypes.contains(raw) {
            settings = AVCapturePhotoSettings(rawPixelFormatType: raw,
                                              processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.photoQualityPrioritization = .speed
        settings.flashMode = .off

        let id = settings.uniqueID
        let proxy = PhotoCaptureProxy { [weak self] image, error in
            Task { @MainActor in
                self?.finishCapture(id: id, image: image, error: error)
            }
        }
        proxies[id] = proxy
        sessionQueue.async { [photoOutput = self.photoOutput] in
            photoOutput.capturePhoto(with: settings, delegate: proxy)
        }
    }

    private func finishCapture(id: Int64, image: CGImage?, error: Error?) {
        // A completion whose proxy was already disowned belongs to a stopped
        // session — ignore it entirely (its frame must not enter a newer stack).
        guard proxies.removeValue(forKey: id) != nil else { return }
        captureInFlight = false
        guard isRunning else { return }
        if error == nil { deliver(image: image) }
        scheduleNextCapture()
    }

    private func scheduleNextCapture() {
        guard isRunning, !isPaused else { return }
        let gap = max(0, activeRecipe.intervalSeconds) + thermalExtraGapSeconds
        if gap <= 0 {
            captureNext()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(gap))
            guard let self, self.isRunning, !self.isPaused else { return }
            self.captureNext()
        }
    }

    /// Collects the processed frame across delegate callbacks and reports once on
    /// `didFinishCapture` — the point from which the next capture is chained.
    private final class PhotoCaptureProxy: NSObject, AVCapturePhotoCaptureDelegate {
        private let completion: (CGImage?, Error?) -> Void
        private var processedImage: CGImage?

        init(completion: @escaping (CGImage?, Error?) -> Void) {
            self.completion = completion
        }

        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishProcessingPhoto photo: AVCapturePhoto,
                         error: Error?) {
            guard error == nil else { return }
            // The Bayer RAW plane arrives here too (photo.isRawPhoto == true);
            // v1 stacks the processed twin. RAW persistence lands in a later round.
            // Fall back to the embedded preview if the full-size CGImage is
            // unavailable — a real (smaller) sensor image beats a dropped frame.
            if !photo.isRawPhoto, processedImage == nil {
                processedImage = photo.cgImageRepresentation()
                    ?? photo.previewCGImageRepresentation()
            }
        }

        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                         error: Error?) {
            completion(processedImage, error)
        }
    }

    #endif

    // MARK: - Simulator capture path

    #if targetEnvironment(simulator)

    private func startSimulatedLoop() {
        simTask?.cancel()
        simTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                let recipe = self.activeRecipe
                let gap = min(recipe.exposureSeconds, 1.0)
                    + max(0.05, recipe.intervalSeconds)
                    + self.thermalExtraGapSeconds
                try? await Task.sleep(for: .seconds(gap))
                guard !Task.isCancelled, self.isRunning else { return }
                if self.isPaused { continue }
                self.deliver(image: self.synth.renderFrame(index: self.frameIndex))
            }
        }
    }

    /// Small inline synthetic starfield so the app runs end-to-end in the simulator:
    /// 40 gaussian stars over a noisy pedestal, drifting slowly like a real unguided sky.
    /// Stars are COLOURED (warm orange giants through blue-white dwarfs, like a real
    /// field) so the colour stacking pipeline shows colour throughout the app.
    private struct SyntheticStarField {
        static let width = 400
        static let height = 300

        private struct Star {
            var x: Double; var y: Double; var amp: Double; var sigma: Double
            var tintR: Double; var tintG: Double; var tintB: Double
        }
        private var stars: [Star] = []
        private var noiseState: UInt64

        init(seed: UInt64) {
            noiseState = seed
            var state = seed
            func nextUniform() -> Double {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
            }
            while stars.count < 40 {
                // Colour-index proxy: 0 = warm (K/M star), 1 = cool blue-white (B/A star).
                // Tint is luminance-normalised so amp keeps meaning "brightness".
                let t = nextUniform()
                var r = 1.0 - 0.45 * t          // 1.00 → 0.55
                var g = 0.72 + 0.08 * t          // 0.72 → 0.80
                var b = 0.50 + 0.50 * t          // 0.50 → 1.00
                let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                r /= lum; g /= lum; b /= lum
                let candidate = Star(x: 25 + nextUniform() * Double(Self.width - 50),
                                     y: 25 + nextUniform() * Double(Self.height - 50),
                                     amp: 0.25 + nextUniform() * 0.55,
                                     sigma: 1.2 + nextUniform() * 0.6,
                                     tintR: r, tintG: g, tintB: b)
                let clear = stars.allSatisfy {
                    let dx = $0.x - candidate.x, dy = $0.y - candidate.y
                    return dx * dx + dy * dy > 256
                }
                if clear { stars.append(candidate) }
            }
        }

        private mutating func gaussianNoise() -> Double {
            func draw() -> Double {
                noiseState &+= 0x9E37_79B9_7F4A_7C15
                var z = noiseState
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
                return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0)
            }
            let u1 = max(draw(), 1e-12)
            let u2 = draw()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }

        mutating func renderFrame(index: Int) -> CGImage? {
            let w = Self.width, h = Self.height
            // Slow unguided drift, capped so stars stay in frame on long sim runs.
            let dx = min(20.0, 0.35 * Double(index))
            let dy = min(8.0, 0.12 * Double(index))
            var bufR = [Float](repeating: 0.06, count: w * h)
            var bufG = [Float](repeating: 0.06, count: w * h)
            var bufB = [Float](repeating: 0.06, count: w * h)
            for i in 0..<bufR.count {
                bufR[i] += Float(0.02 * gaussianNoise())
                bufG[i] += Float(0.02 * gaussianNoise())
                bufB[i] += Float(0.02 * gaussianNoise())
            }
            for star in stars {
                let px = star.x + dx
                let py = star.y + dy
                let r = Int((4 * star.sigma).rounded(.up))
                let x0 = max(0, Int(px) - r), x1 = min(w - 1, Int(px) + r)
                let y0 = max(0, Int(py) - r), y1 = min(h - 1, Int(py) + r)
                guard x0 <= x1, y0 <= y1 else { continue }
                let inv = 1.0 / (2 * star.sigma * star.sigma)
                for y in y0...y1 {
                    for x in x0...x1 {
                        let ddx = Double(x) - px
                        let ddy = Double(y) - py
                        let psf = star.amp * exp(-(ddx * ddx + ddy * ddy) * inv)
                        let i = y * w + x
                        bufR[i] += Float(psf * star.tintR)
                        bufG[i] += Float(psf * star.tintG)
                        bufB[i] += Float(psf * star.tintB)
                    }
                }
            }
            for i in 0..<bufR.count {
                bufR[i] = min(1, max(0, bufR[i]))
                bufG[i] = min(1, max(0, bufG[i]))
                bufB[i] = min(1, max(0, bufB[i]))
            }
            return CPUStacker.rgbImage(r: bufR, g: bufG, b: bufB, width: w, height: h)
        }
    }

    #endif
}

// MARK: - CaptureEngineBridge (device builds)

#if !targetEnvironment(simulator)

/// Adapts the push-based `CaptureEngine` (frames arrive via `onFrame`) to the
/// pull-based `SessionHooks` seam (`captureSub` awaits one frame at a time).
///
/// `SessionHooks.live()` routes here on device builds, so a session's Capture phase
/// drives the REAL camera end-to-end:
///  - `prepare` ensures camera permission (reusing the onboarding grant, or prompting
///    on first use — a denial throws `CaptureError.notAuthorized`, it never goes
///    synthetic), configures the bench-proven pipeline (custom exposure from the
///    recipe, ZSL off, sequential captures chained from `didFinishCapture`), starts
///    the `AVCaptureSession` (iOS shows the green camera-active dot), and awaits the
///    first real frame to learn the true sensor dimensions for the stacker.
///  - `captureSub` hands each real `SubFrame` (sensor CGImage included) to the
///    session engine; a 1-frame newest-wins buffer means a frame exposed during a
///    gimbal nudge is simply superseded rather than queued.
///  - `teardown` stops the session on every exit path (develop / complete / abort),
///    which turns the green dot off.
@MainActor
public enum CaptureEngineBridge {

    private static var continuation: AsyncStream<SubFrame>.Continuation?
    private static var iterator: AsyncStream<SubFrame>.Iterator?
    /// First real frame, captured during `prepare` to learn the true sensor
    /// dimensions; handed to the first `captureSub` so no exposure is wasted.
    private static var primedFrame: SubFrame?

    /// Ensure authorization, start the real camera, and return the live-stack grid
    /// dimensions for the stacker — the true sensor aspect ratio (measured from the
    /// first delivered frame) bounded to `liveStackMaxSide`, because `CPUStacker`
    /// rescales every full-size photo into the reset grid and must keep pace with
    /// the 1 s capture cadence.
    public static func prepare(recipe: CaptureRecipe) async throws -> (width: Int, height: Int) {
        await teardown()   // idempotent clean slate if a previous session leaked
        let engine = CaptureEngine.shared
        let (stream, cont) = AsyncStream.makeStream(of: SubFrame.self,
                                                    bufferingPolicy: .bufferingNewest(1))
        continuation = cont
        iterator = stream.makeAsyncIterator()
        engine.onFrame = { frame in _ = cont.yield(frame) }
        do {
            try await engine.start(recipe: recipe)
            let first = try await nextFrame()
            guard let image = first.pixelData else {
                throw CaptureError.configurationFailed("first frame carried no image data")
            }
            primedFrame = first
            return liveStackGrid(width: image.width, height: image.height)
        } catch {
            await teardown()
            throw error
        }
    }

    /// Longest side of the live-stack grid. Full 12 MP registration per sub would
    /// starve the capture cadence; ~1 MP preserves plenty of stars for alignment.
    private static let liveStackMaxSide = 1024

    private static func liveStackGrid(width: Int, height: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > liveStackMaxSide, longest > 0 else {
            return (max(1, width), max(1, height))
        }
        let scale = Double(liveStackMaxSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    /// Await the next real sub-exposure, re-indexed to the session's own counter.
    public static func captureSub(recipe: CaptureRecipe, index: Int) async throws -> SubFrame {
        var frame: SubFrame
        if let primed = primedFrame {
            primedFrame = nil
            frame = primed
        } else {
            frame = try await nextFrame()
        }
        frame.index = index
        return frame
    }

    /// Stop the camera (green dot off) and release the frame stream. Any
    /// `captureSub` still awaiting a frame is resumed with `CancellationError`.
    public static func teardown() async {
        let engine = CaptureEngine.shared
        engine.onFrame = nil
        engine.stop()
        continuation?.finish()
        continuation = nil
        iterator = nil
        primedFrame = nil
    }

    private static func nextFrame() async throws -> SubFrame {
        guard var pending = iterator else {
            throw CaptureError.configurationFailed("capture pipeline is not running")
        }
        // Await on a LOCAL copy: AsyncStream iterators share their underlying
        // storage, and the local avoids an exclusivity conflict if `teardown()`
        // clears `iterator` while this await is suspended.
        guard let frame = await pending.next() else {
            throw CancellationError()   // stream finished (teardown / abort)
        }
        return frame
    }
}

#endif
