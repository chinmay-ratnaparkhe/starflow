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

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Camera access is off. StarFlow needs the camera to capture star exposures — enable it in Settings."
        case .cameraUnavailable:
            return "The main wide camera is unavailable."
        case .configurationFailed(let detail):
            return "Camera setup failed (\(detail))."
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

    /// Configure (once) and start the sequential capture loop with the given recipe.
    public func start(recipe: CaptureRecipe) async throws {
        guard !isRunning else { return }
        activeRecipe = recipe
        appliedExposureSeconds = min(recipe.exposureSeconds, 1.0)
        appliedISO = recipe.iso
        frameIndex = 0
        framesDelivered = 0
        lastFrameAt = nil
        lastGapSeconds = nil

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
        proxies.removeValue(forKey: id)
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
            if !photo.isRawPhoto, processedImage == nil {
                processedImage = photo.cgImageRepresentation()
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
    private struct SyntheticStarField {
        static let width = 400
        static let height = 300

        private struct Star { var x: Double; var y: Double; var amp: Double; var sigma: Double }
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
                let candidate = Star(x: 25 + nextUniform() * Double(Self.width - 50),
                                     y: 25 + nextUniform() * Double(Self.height - 50),
                                     amp: 0.25 + nextUniform() * 0.55,
                                     sigma: 1.2 + nextUniform() * 0.6)
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
            var buffer = [Float](repeating: 0.06, count: w * h)
            for i in 0..<buffer.count {
                buffer[i] += Float(0.02 * gaussianNoise())
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
                        buffer[y * w + x] += Float(star.amp * exp(-(ddx * ddx + ddy * ddy) * inv))
                    }
                }
            }
            for i in 0..<buffer.count {
                buffer[i] = min(1, max(0, buffer[i]))
            }
            return CPUStacker.grayImage(from: buffer, width: w, height: h)
        }
    }

    #endif
}
