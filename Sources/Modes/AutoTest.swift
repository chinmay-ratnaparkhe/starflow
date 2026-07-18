import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Remote end-to-end test harness.
///
/// The development machine writes `Documents/autotest/command.json` over USB
/// (house_arrest/AFC) and this runner executes REAL sessions — actual camera,
/// actual stacker, actual gimbal — writing progress, a final report, and the
/// stacked preview image back into `Documents/autotest/` for the dev machine
/// to pull and inspect. No UI interaction needed beyond launching the app.
///
/// Command file format:
///   { "id": "any-unique-string", "action": "status" }
///   { "id": "...", "action": "run_session", "modeId": "startrails", "targetSubs": 20, "timeoutSeconds": 120 }
///   { "id": "...", "action": "solve_preview", "fovDeg": 70 }   // plate-solve the latest stack preview
@MainActor
final class AutoTestRunner: ObservableObject {
    static let shared = AutoTestRunner()

    @Published private(set) var active = false
    /// When a remote session runs, the app presents the real Session UI so the
    /// person holding the phone watches exactly what the harness is doing.
    @Published var presentedShot: ShotModeItem?

    private var pollTask: Task<Void, Never>?
    private var lastHandledID: String?

    private var dir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("autotest", isDirectory: true)
    }

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lastHandledID = try? String(contentsOf: dir.appendingPathComponent("last_id.txt"), encoding: .utf8)
        writeJSON(["state": "armed", "version": "0.2.0"], to: "runner.json")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private struct Command: Decodable {
        var id: String
        var action: String
        var modeId: String?
        var targetSubs: Int?
        var timeoutSeconds: Double?
        var fovDeg: Double?
    }

    private func pollOnce() async {
        let url = dir.appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: url),
              let cmd = try? JSONDecoder().decode(Command.self, from: data),
              cmd.id != lastHandledID else { return }
        lastHandledID = cmd.id
        try? cmd.id.write(to: dir.appendingPathComponent("last_id.txt"),
                          atomically: true, encoding: .utf8)
        active = true
        defer { active = false }
        switch cmd.action {
        case "status":
            writeStatusReport(commandID: cmd.id)
        case "run_session":
            await runSession(cmd)
        case "solve_preview":
            solvePreview(cmd)
        default:
            writeJSON(["id": cmd.id, "error": "unknown action \(cmd.action)"], to: "report.json")
        }
    }

    // MARK: - Actions

    private func writeStatusReport(commandID: String) {
        var cameraAuth = "unknown"
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraAuth = "authorized"
        case .denied: cameraAuth = "denied"
        case .notDetermined: cameraAuth = "notDetermined"
        case .restricted: cameraAuth = "restricted"
        @unknown default: cameraAuth = "unknown"
        }
        #endif
        let mount = MountService.shared
        writeJSON([
            "id": commandID,
            "action": "status",
            "cameraAuthorization": cameraAuth,
            "mountConnection": String(describing: mount.connection),
            "mountAuthority": String(describing: mount.authority),
            "mountTelemetry": mount.telemetry.map { String(describing: $0) } ?? "nil",
            "sessionPhase": SessionEngine.shared.phase.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ], to: "report.json")
    }

    private func runSession(_ cmd: Command) async {
        let engine = SessionEngine.shared
        guard let shot = ShotModeRegistry.all.first(where: { $0.id == cmd.modeId }) else {
            writeJSON(["id": cmd.id, "error": "unknown modeId \(cmd.modeId ?? "nil")",
                       "known": ShotModeRegistry.all.map(\.id).joined(separator: ",")],
                      to: "report.json")
            return
        }
        let targetSubs = max(1, cmd.targetSubs ?? 15)
        let timeout = cmd.timeoutSeconds ?? Double(targetSubs) * 3 + 90
        let started = Date()

        presentedShot = shot          // surface the real Session UI on screen
        engine.start(shot: shot)

        // Observe until we have enough subs, the engine completes, or timeout.
        while Date().timeIntervalSince(started) < timeout {
            let stats = engine.stats
            writeJSON([
                "id": cmd.id,
                "state": "running",
                "phase": engine.phase.rawValue,
                "statusDetail": engine.statusDetail,
                "subsAccepted": "\(stats.subsAccepted)",
                "subsRejected": "\(stats.subsRejected)",
                "subsSkippedClouds": "\(stats.subsSkippedClouds)",
                "integrationSeconds": String(format: "%.1f", stats.integrationSeconds),
                "interruption": engine.interruption.map { String(describing: $0) } ?? "none",
                "elapsed": String(format: "%.0f", Date().timeIntervalSince(started)),
            ], to: "progress.json")
            if engine.phase == .complete { break }
            if stats.subsAccepted >= targetSubs {
                engine.abort()   // graceful: develops the stack from accepted frames
                // give develop a moment to finish
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if engine.phase != .complete { engine.abort() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Final report + stacked preview.
        let stats = engine.stats
        if let img = engine.latestPreview {
            writePNG(img, to: "preview.png")
        }
        writeJSON([
            "id": cmd.id,
            "state": "done",
            "modeId": shot.id,
            "finalPhase": engine.phase.rawValue,
            "statusDetail": engine.statusDetail,
            "subsAccepted": "\(stats.subsAccepted)",
            "subsRejected": "\(stats.subsRejected)",
            "subsSkippedClouds": "\(stats.subsSkippedClouds)",
            "subsLostToClouds": "\(stats.subsLostToClouds)",
            "integrationSeconds": String(format: "%.1f", stats.integrationSeconds),
            "nudges": "\(stats.nudges)",
            "flapsRecovered": "\(stats.flapsRecovered)",
            "interruption": engine.interruption.map { String(describing: $0) } ?? "none",
            "previewWritten": engine.latestPreview != nil ? "yes" : "no",
            "wallSeconds": String(format: "%.0f", Date().timeIntervalSince(started)),
        ], to: "report.json")

        // Keep the landing report on screen briefly, then dismiss.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        presentedShot = nil
    }

    /// Debug hook for the plate-solve core (ROADMAP #4): detect stars on the
    /// latest stacked preview with the CPUStacker detector and hand the
    /// centroids to `PlateSolver`. Reports the solved center / roll / scale or
    /// the honest failure reason. Nothing in the session loop consumes this yet
    /// — GoTo (feature 5) will close the loop.
    private func solvePreview(_ cmd: Command) {
        guard let image = SessionEngine.shared.latestPreview else {
            writeJSON(["id": cmd.id, "action": "solve_preview",
                       "solved": "no", "error": "no stack preview — run a session first"],
                      to: "report.json")
            return
        }
        let width = image.width, height = image.height
        guard let gray = CPUStacker.grayscaleFloats(from: image, width: width, height: height) else {
            writeJSON(["id": cmd.id, "action": "solve_preview",
                       "solved": "no", "error": "preview could not be decoded"],
                      to: "report.json")
            return
        }
        let stars = CPUStacker.detectStars(in: gray, width: width, height: height)
        let centroids = stars.map { CGPoint(x: $0.x, y: $0.y) }   // brightest-first
        let fov = cmd.fovDeg ?? 70.0
        let started = Date()
        let solution = PlateSolver.shared.solve(centroids: centroids,
                                                imageSize: CGSize(width: width, height: height),
                                                fovEstimateDeg: fov)
        var report: [String: String] = [
            "id": cmd.id,
            "action": "solve_preview",
            "starCount": "\(centroids.count)",
            "fovEstimateDeg": String(format: "%.1f", fov),
            "solveMillis": String(format: "%.0f", Date().timeIntervalSince(started) * 1000),
        ]
        if let s = solution {
            report["solved"] = "yes"
            report["centerRAHours"] = String(format: "%.4f", s.center.raHours)
            report["centerRADeg"] = String(format: "%.4f", s.centerRADeg)
            report["centerDecDeg"] = String(format: "%.4f", s.centerDecDeg)
            report["rollDeg"] = String(format: "%.2f", s.rollDeg)
            report["plateScalePxPerDeg"] = String(format: "%.2f", s.plateScalePxPerDeg)
            report["matchedCount"] = "\(s.matchedCount)"
            report["residualPx"] = String(format: "%.2f", s.residualPx)
        } else {
            report["solved"] = "no"
            report["error"] = "no verified match (needs ≥6 catalog stars in field — "
                            + "mag ≤3.5 catalog wants a wide or star-rich view)"
        }
        writeJSON(report, to: "report.json")
    }

    // MARK: - Output helpers

    private func writeJSON(_ dict: [String: String], to name: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func writePNG(_ image: CGImage, to name: String) {
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
