import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(DockKit) && !targetEnvironment(simulator)
import DockKit
import Spatial
#endif

// MARK: - DockKit experiment escape hatch
//
// `authority_experiment` calls two DockKit APIs the production code deliberately
// never uses — `DockAccessory.setOrientation(_:)` and `selectSubject(at:)`.
// They are the ONLY calls in this file whose exact signatures are not already
// exercised somewhere else in the app, so both sit behind a compile flag:
//
//     #if STARFLOW_NO_DOCKKIT_EXPERIMENTS   →  candidate reports "compiled out"
//
// If the device archive ever fails to compile on those two lines, add
//
//     SWIFT_ACTIVE_COMPILATION_CONDITIONS: STARFLOW_NO_DOCKKIT_EXPERIMENTS
//
// to the StarFlow target's `settings.base` in project.yml. The build goes green
// immediately, those two candidates report `compiledOut` instead of a result,
// and every other action is untouched. Nothing else in the app reads the flag.

/// Remote end-to-end test harness.
///
/// The development machine writes `Documents/autotest/command.json` over USB
/// (house_arrest/AFC) and this runner executes REAL sessions — actual camera,
/// actual stacker, actual gimbal — writing progress, a final report, and the
/// stacked preview image back into `Documents/autotest/` for the dev machine
/// to pull and inspect. No UI interaction needed beyond launching the app.
///
/// Every action obeys the same three rules, without exception:
///  1. it never crashes the app — failures become an `"error"` field,
///  2. it ALWAYS writes `report.json`, success or failure,
///  3. it always leaves the gimbal stopped and the camera torn down, and it
///     MEASURES both facts into the report rather than asserting them.
///
/// Command file format (only `id` and `action` are required):
///   { "id": "any-unique-string", "action": "status" }
///   { "id": "...", "action": "camera_probe" }
///   { "id": "...", "action": "gimbal_probe" }
///   { "id": "...", "action": "authority_experiment" }
///   { "id": "...", "action": "run_session", "modeId": "startrails", "targetSubs": 20, "timeoutSeconds": 120 }
///   { "id": "...", "action": "endurance", "modeId": "milkyway", "minutes": 30 }
///   { "id": "...", "action": "field_failures", "modeId": "milkyway" }
///   { "id": "...", "action": "solve_preview", "fovDeg": 70 }   // plate-solve the latest stack preview
///
/// Every session-running action also accepts `"dumpEveryN": <int>` (alias of the
/// original `"frameDumpEveryN"`; default 10, 0 = only the mandatory first
/// frames) — the cadence of the JPEG frame dumps.
///
/// Per-frame evidence written alongside the reports (see `FrameTruth.swift`):
///   frames.csv          one row per delivered frame — requested vs. ACTUAL
///                       exposure/ISO, exposure/focus/WB modes, lens position,
///                       format, RAW/ZSL/responsive flags, shot-to-shot gap,
///                       EXIF, and the stacker's star count + accept/reject.
///                       `simulated` and `sensorMeasured` say where each row's
///                       numbers came from; `honoursRequest` is 1/0 ONLY on
///                       rows a real sensor vouched for and EMPTY otherwise, so
///                       synthetic data can never be counted as a pass.
///   frames/first.jpg    the very first frame of the run, always.
///   frames/f<n>.jpg     the first three frames + every Nth (max 40 kept).
///   frames/index.json   the dumped files with their FrameTruth fields.
///   endurance.csv       one row per 30 s of an `endurance` run.
@MainActor
final class AutoTestRunner: ObservableObject {
    static let shared = AutoTestRunner()

    /// 0.4.0 changed what the evidence MEANS, not just what it contains:
    /// `honoursRequest` is now empty (not "yes") on any row without sensor
    /// read-back, `camera_probe` actually asks the sensor for the night lock,
    /// and `authority_experiment` reports whether it was conclusive at all.
    /// A report from an older harness must not be read with the new rules.
    static let harnessVersion = "0.4.0"
    static let actions = ["status", "camera_probe", "gimbal_probe", "authority_experiment",
                          "run_session", "endurance", "field_failures", "solve_preview"]

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
        // `frameTruthLog` is how the dev machine confirms the build on the phone
        // is the one that writes per-frame evidence (the `version` key is left
        // alone so an older harness keeps matching on it).
        writeJSON(["state": "armed", "version": "0.2.0",
                   "frameTruthLog": "1",
                   "evidence": "frames.csv,frames/first.jpg,frames/index.json",
                   // Schema 2 = honoursRequest is empty where there is no sensor
                   // evidence, and frames.csv carries sensorMeasured /
                   // targetExposureSeconds / exposureClamped.
                   "evidenceSchema": "2",
                   "frameCSVColumns": FrameTruth.csvColumns.joined(separator: " "),
                   // Appended capability advertisement so the dev machine can
                   // discover which actions this build actually implements.
                   "harnessVersion": Self.harnessVersion,
                   "actions": Self.actions.joined(separator: ","),
                   "simulatedMount": MountService.isSimulated ? "yes" : "no",
                   "armedAt": ISO8601DateFormatter().string(from: Date())],
                  to: "runner.json")
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
        /// Frame-dump cadence for this run (see `FrameEvidence`): every Nth
        /// frame is written to `Documents/autotest/frames/`. Omitted → 10;
        /// 0 → only the mandatory first frames. Appended field — older command
        /// files decode unchanged.
        var frameDumpEveryN: Int?
        /// Endurance run length in minutes (default 30, clamped to 1…240).
        /// Appended field — older command files decode unchanged.
        var minutes: Double?
        /// Shorter spelling of `frameDumpEveryN`. Both are accepted; this one
        /// wins when a command carries both. Appended field.
        var dumpEveryN: Int?

        /// The frame-dump cadence this command asks for, under either spelling.
        var requestedDumpEveryN: Int? { dumpEveryN ?? frameDumpEveryN }
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
        case "camera_probe":
            await perform(cmd) { await self.runCameraProbe(cmd) }
        case "gimbal_probe":
            await perform(cmd) { await self.runGimbalProbe(cmd) }
        case "authority_experiment":
            await perform(cmd) { await self.runAuthorityExperiment(cmd) }
        case "endurance":
            await perform(cmd) { await self.runEndurance(cmd) }
        case "field_failures":
            await perform(cmd) { await self.runFieldFailures(cmd) }
        default:
            writeJSON(["id": cmd.id, "error": "unknown action \(cmd.action)",
                       "known": Self.actions.joined(separator: ",")], to: "report.json")
        }
    }

    // MARK: - Action runner (never crashes, always reports, always leaves things safe)

    /// Runs one action body, stamps the standard envelope onto whatever it
    /// returns, guarantees a `report.json` write, and ALWAYS zeroes the gimbal
    /// and tears the camera down afterwards — including when the body reported
    /// its own failure.
    private func perform(_ cmd: Command, _ body: () async -> [String: Any]) async {
        let started = Date()
        writeReport(["id": cmd.id, "action": cmd.action, "state": "running",
                     "startedAt": ISO8601DateFormatter().string(from: started)],
                    to: "progress.json")
        var report = await body()
        await safeShutdown()
        report["id"] = cmd.id
        report["action"] = cmd.action
        report["state"] = "done"
        report["wallSeconds"] = round2(Date().timeIntervalSince(started))
        report["timestamp"] = ISO8601DateFormatter().string(from: Date())
        report["simulatedMount"] = MountService.isSimulated
        report["harnessVersion"] = Self.harnessVersion
        // Prove the safety contract in the report itself, not just in prose.
        report["gimbalStopped"] = await confirmStopped()
        writeReport(report, to: "report.json")
    }

    /// Zero the motors and tear the camera down. Idempotent and safe from any
    /// state — this is the single exit path every action runs through.
    private func safeShutdown() async {
        await MountService.shared.stopEverything()
        #if targetEnvironment(simulator)
        CaptureEngine.shared.stop()
        #else
        await CaptureEngineBridge.teardown()
        CaptureEngine.shared.stop()
        #endif
        FrameTruthLog.shared.flushPending()
    }

    /// Watch the encoder for ~1.5 s and report the largest speed seen. The
    /// gimbal is stopped when that peak sits under the settle threshold. This
    /// MEASURES the safety contract instead of assuming it.
    private func confirmStopped() async -> [String: Any] {
        let thresholdDegPerSec = GimbalConstants.settleThreshold * 180.0 / .pi
        let samplesBefore = MountService.shared.encoderSampleCount
        guard let peak = await maxSpeedDegPerSec(seconds: 1.5) else {
            return ["measured": false,
                    "note": "no encoder telemetry (gimbal not docked) — velocity was "
                          + "zeroed anyway"]
        }
        // A telemetry stream that stopped delivering would repeat its last
        // sample forever and read as a confident "stopped". Report how many
        // FRESH samples the window actually saw so a stale zero cannot pass
        // itself off as a measurement.
        let freshSamples = MountService.shared.encoderSampleCount - samplesBefore
        var out: [String: Any] = ["measured": freshSamples > 0,
                                  "freshEncoderSamples": freshSamples,
                                  "peakSpeedDegPerSec": round3(peak),
                                  "thresholdDegPerSec": round3(thresholdDegPerSec),
                                  "stopped": freshSamples > 0 && peak < thresholdDegPerSec]
        if freshSamples == 0 {
            out["note"] = "the encoder delivered NO fresh samples during the 1.5 s window — "
                + "peakSpeedDegPerSec is a stale reading and proves nothing; velocity was "
                + "zeroed anyway"
        }
        return out
    }

    private func maxSpeedDegPerSec(seconds: Double) async -> Double? {
        let deadline = Date().addingTimeInterval(seconds)
        var peak: Double?
        while Date() < deadline {
            if let speed = MountService.shared.telemetry?.speedDegPerSec {
                peak = max(peak ?? 0, abs(speed))
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return peak
    }

    /// Turn the frame ledger on for this run and honor the requested dump
    /// cadence (the harness exists to collect that evidence).
    private func applyFrameEvidenceSettings(_ cmd: Command) {
        FrameTruthLog.shared.isEnabled = true
        guard let requested = cmd.requestedDumpEveryN else { return }
        let sanitized = FrameEvidence.sanitizedDumpEveryN(requested)
        FrameTruthLog.shared.dumpEveryN = sanitized
        // Persist it too, so the ledger's own session-start refresh reads back
        // the SAME cadence the command asked for.
        UserDefaults.standard.set(sanitized, forKey: FrameTruthLog.dumpEveryNDefaultsKey)
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
            // Appended fields — every pre-existing key above keeps its contract.
            "harnessVersion": Self.harnessVersion,
            "actions": Self.actions.joined(separator: ","),
            "simulatedMount": MountService.isSimulated ? "yes" : "no",
            "thermalState": Self.thermalString(ProcessInfo.processInfo.thermalState),
            "batteryPercent": SessionHooks.systemBatteryPercent().map { String($0) } ?? "unknown",
            "freeDiskMB": SessionHooks.systemFreeDiskBytes()
                .map { String(Int($0 / 1_048_576)) } ?? "unknown",
            "memoryFootprintMB": Self.memoryFootprintMB()
                .map { String(format: "%.1f", $0) } ?? "unknown",
        ].merging(frameEvidenceFields(), uniquingKeysWith: { a, _ in a }), to: "report.json")
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

        // Per-frame evidence for THIS run: force the ledger on (the harness
        // exists to collect it) and honor the requested dump cadence.
        applyFrameEvidenceSettings(cmd)

        // Phase timing observed by the harness itself (0.25 s resolution). It
        // survives a session that dies mid-phase, which the engine's own
        // accounting cannot.
        var phaseFirstSeen: [String: Double] = [:]
        var phaseOrder: [String] = []
        var lastProgressWrite = Date.distantPast

        presentedShot = shot          // surface the real Session UI on screen
        engine.start(shot: shot)

        // Observe until we have enough subs, the engine completes, or timeout.
        while Date().timeIntervalSince(started) < timeout {
            let stats = engine.stats
            let elapsed = Date().timeIntervalSince(started)
            let phaseName = engine.phase.rawValue
            if phaseFirstSeen[phaseName] == nil {
                phaseFirstSeen[phaseName] = round2(elapsed)
                phaseOrder.append(phaseName)
            }
            if Date().timeIntervalSince(lastProgressWrite) >= 1.0 {
                lastProgressWrite = Date()
                writeJSON([
                    "id": cmd.id,
                    "state": "running",
                    "phase": phaseName,
                    "statusDetail": engine.statusDetail,
                    "subsAccepted": "\(stats.subsAccepted)",
                    "subsRejected": "\(stats.subsRejected)",
                    "subsSkippedClouds": "\(stats.subsSkippedClouds)",
                    "integrationSeconds": String(format: "%.1f", stats.integrationSeconds),
                    "interruption": engine.interruption.map { String(describing: $0) } ?? "none",
                    "elapsed": String(format: "%.0f", elapsed),
                    "skyCondition": engine.skyCondition.rawValue,
                    "starCount": "\(stats.lastStarCount)",
                ].merging(frameEvidenceFields(), uniquingKeysWith: { a, _ in a }),
                          to: "progress.json")
            }
            if engine.phase == .complete { break }
            if stats.subsAccepted >= targetSubs {
                engine.abort()   // graceful: develops the stack from accepted frames
                // give develop a moment to finish
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if engine.phase != .complete { engine.abort() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let finalPhase = engine.phase.rawValue
        if phaseFirstSeen[finalPhase] == nil {
            phaseFirstSeen[finalPhase] = round2(Date().timeIntervalSince(started))
            phaseOrder.append(finalPhase)
        }

        // Final report + stacked preview.
        let stats = engine.stats
        if let img = engine.latestPreview {
            writePNG(img, to: "preview.png")
        }
        // Every pre-existing key keeps its exact string contract; everything new
        // is nested under its own key, so an older parser still reads this file.
        var report: [String: Any] = [
            "id": cmd.id,
            "state": "done",
            "modeId": shot.id,
            "finalPhase": finalPhase,
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
        ]
        for (key, value) in frameEvidenceFields() where report[key] == nil {
            report[key] = value
        }
        report["action"] = "run_session"
        report["harnessVersion"] = Self.harnessVersion
        report["timestamp"] = ISO8601DateFormatter().string(from: Date())
        // Top-level provenance, matching what `perform` stamps on every other
        // action: whether the frames came from a sensor or the synthetic
        // starfield, and whether the mount was real. Nested under `capture`/
        // `mount` these are easy to miss, and a simulator run that reads like a
        // hardware run is the worst failure this report can have.
        report["simulatedCapture"] = engine.captureSourceIsSimulated
        report["simulatedMount"] = MountService.isSimulated
        report["timing"] = [
            "wallSeconds": round2(Date().timeIntervalSince(started)),
            "timeoutSeconds": timeout,
            "targetSubs": targetSubs,
            "phaseOrder": phaseOrder,
            "phaseEnteredAtSeconds": phaseFirstSeen,
            "phaseSecondsFromEngine": engine.phaseDurations.mapValues { round2($0) },
            "note": "phaseEnteredAtSeconds is the harness's own observation at 0.25 s "
                  + "resolution; phaseSecondsFromEngine is the engine's accounting and "
                  + "excludes whichever phase was still running",
        ] as [String: Any]
        report["focusSweep"] = focusSweepReport(engine.focusSweepStatus)
        report["pointing"] = [
            "aimAssistOutcome": stats.aimAssistOutcome,
            "goToOutcome": stats.goToOutcome,
            "goToAcquires": stats.goToAcquires,
            "goToFinalErrorDeg": jsonValue(stats.goToFinalErrorDeg.map { round3($0) }),
            "driftCorrections": stats.driftCorrections,
            "lastDriftDeg": jsonValue(stats.lastDriftDeg.map { round3($0) }),
            "pointingInvalidated": engine.pointingInvalidated,
        ] as [String: Any]
        report["stars"] = [
            "lastFrameStarCount": stats.lastStarCount,
            "peakStarCount": stats.peakStarCount,
            "calibrationStars": stats.calibrationStars,
            "note": "counts come from SkyConditionMonitor observations of real frames. 0 "
                  + "means NOTHING WAS MEASURED (no decodable frame reached the monitor), "
                  + "not 'a clear sky with no stars' — cross-check framesLogged and the "
                  + "starCount column in frames.csv before reading anything into a 0.",
        ] as [String: Any]
        report["clouds"] = [
            "verdict": engine.skyCondition.rawValue,
            "verdictDisplay": engine.skyCondition.displayName,
            "subsSkippedClouds": stats.subsSkippedClouds,
            "subsLostToClouds": stats.subsLostToClouds,
        ] as [String: Any]
        report["frames"] = frameArtifacts()
        report["mount"] = mountSnapshot()
        report["host"] = hostSnapshot()
        report["capture"] = [
            "sourceIsSimulated": engine.captureSourceIsSimulated,
            "timelapseVideo": jsonValue(engine.timelapseVideoURL?.lastPathComponent),
        ] as [String: Any]
        writeReport(report, to: "report.json")

        await safeShutdown()
        // Prove the safety contract for this action too — `run_session` does not
        // go through `perform`, so without this it was the one action that
        // asserted "the gimbal is stopped" without measuring it. Re-written
        // after the measurement so report.json carries the evidence.
        report["gimbalStopped"] = await confirmStopped()
        for (key, value) in frameEvidenceFields() { report[key] = value }
        report["frames"] = frameArtifacts()
        writeReport(report, to: "report.json")

        // Keep the landing report on screen briefly, then dismiss.
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        presentedShot = nil
    }

    private func focusSweepReport(_ status: FocusSweepStatus) -> [String: Any] {
        switch status {
        case .inactive:
            return ["state": "inactive", "locked": false,
                    "note": "this mode never sweeps, or the sweep is off in Settings"]
        case .running(let step, let planned):
            return ["state": "running", "locked": false, "step": step, "planned": planned]
        case .locked(let position, let decisive):
            return ["state": "locked",
                    "bestLensPosition": round3(position),
                    "locked": decisive,
                    "note": decisive
                        ? "a real sharpness peak was found and locked"
                        : "no clear peak — kept the infinity lock (lensPosition 1.0)"]
        case .skipped(let reason):
            return ["state": "skipped", "locked": false, "reason": reason]
        }
    }

    /// Debug hook for the plate-solve core (ROADMAP #4): detect stars on the
    /// latest stacked preview with the CPUStacker detector and hand the
    /// centroids to `PlateSolver`. Reports the solved center / roll / scale or
    /// the honest failure reason. The session loop's live consumer is
    /// `GoToController` (feature 5); this action stays as the on-demand probe.
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

    // MARK: - camera_probe

    /// Enumerate the FULL camera capability set. Static format facts are read
    /// without touching a session; the live values (real exposure duration, ISO,
    /// lens position, and the photo-output capabilities that only resolve once
    /// the output is attached to a running session) need a short session — which
    /// is started, sampled, and torn down here so the green dot goes back off.
    private func runCameraProbe(_ cmd: Command) async -> [String: Any] {
        await safeShutdown()   // never probe on top of a live capture pipeline
        #if canImport(AVFoundation)
        let camera = await Self.probeCamera()
        var report: [String: Any] = ["camera": camera]
        if let failure = camera["error"] { report["error"] = failure }
        report["mount"] = mountSnapshot()
        report["host"] = hostSnapshot()
        report["note"] = "the probe session runs only long enough to read live values and "
            + "is torn down before this report is written — check camera.sessionTornDown. "
            + "camera.nightLock* is the clamp test: it ASKS the sensor for 1.000 s / "
            + "ISO 3200 and reports what came back (nightLockHonoured), with "
            + "nightLockClampedByFormat separating 'the format can't' from 'the lock "
            + "didn't take'. Capability lists alone cannot catch a silent clamp."
        return report
        #else
        return ["error": "AVFoundation is unavailable in this build"]
        #endif
    }

    #if canImport(AVFoundation)

    /// Every value is a string so the whole block crosses the actor boundary as
    /// a `Sendable` dictionary and the report shape never surprises the parser.
    private nonisolated static func probeCamera() async -> [String: String] {
        var out: [String: String] = [:]
        out["authorizationStatus"] = authorizationString()
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            // The harness has no hands, and a `notDetermined` device blocks every
            // capture action — surface the prompt and record what happened rather
            // than silently reporting "no live values available".
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            out["requestedAccess"] = "yes"
            out["accessGranted"] = granted ? "yes" : "no"
            out["authorizationStatus"] = authorizationString()
        }
        out["deviceModel"] = deviceModelIdentifier()
        out["systemVersion"] = ProcessInfo.processInfo.operatingSystemVersionString

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back) else {
            out["camera"] = "none"
            out["error"] = "no back wide-angle camera (simulator, or hardware unavailable)"
            return out
        }
        out["camera"] = device.localizedName
        out["cameraUniqueID"] = device.uniqueID
        out["cameraModelID"] = device.modelID
        out["cameraDeviceType"] = device.deviceType.rawValue
        out["cameraFormatCount"] = String(device.formats.count)
        describeFormat(device.activeFormat, into: &out, prefix: "preSession")
        describeDeviceModes(device, into: &out, prefix: "preSession")

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            out["sessionRun"] = "no"
            out["error"] = "camera not authorized — live values and photo-output "
                         + "capabilities are unavailable"
            return out
        }

        // --- short session: configure, run, sample, tear down ---
        let session = AVCaptureSession()
        let output = AVCapturePhotoOutput()
        var configured = false
        session.beginConfiguration()
        session.sessionPreset = .photo
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CaptureError.configurationFailed("cannot add camera input")
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                throw CaptureError.configurationFailed("cannot add photo output")
            }
            session.addOutput(output)
            session.commitConfiguration()
            configured = true
        } catch {
            session.commitConfiguration()
            out["sessionRun"] = "no"
            out["sessionError"] = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }

        if configured {
            session.startRunning()
            out["sessionRun"] = "yes"
            // Let the sensor actually settle before reading live values.
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            out["liveSessionRunning"] = yn(session.isRunning)
            out["liveExposureDurationSeconds"] =
                String(format: "%.6f", CMTimeGetSeconds(device.exposureDuration))
            out["liveISO"] = String(format: "%.1f", device.iso)
            out["liveLensPosition"] = String(format: "%.4f", device.lensPosition)
            out["liveExposureTargetOffsetEV"] =
                String(format: "%.3f", device.exposureTargetOffset)
            describeFormat(device.activeFormat, into: &out, prefix: "live")
            describeDeviceModes(device, into: &out, prefix: "live")

            // --- THE clamp test -------------------------------------------
            // Capability lists cannot answer "will this sensor actually give me
            // 1.000 s at ISO 3200?". Only asking for it can. This applies the
            // real night lock to the real device, waits for it to take effect,
            // and reports requested vs. READ-BACK with an explicit clamp verdict.
            applyNightLockProbe(device, into: &out)
            await settle(seconds: 1.2)
            readBackNightLock(device, into: &out)

            out["isResponsiveCaptureSupported"] = yn(output.isResponsiveCaptureSupported)
            out["isZeroShutterLagSupported"] = yn(output.isZeroShutterLagSupported)
            // These are this PROBE output's defaults, not the capture engine's
            // settings — the engine forces both off during its own configure.
            // Labelled so the two can never be confused.
            out["probeOutputZeroShutterLagEnabled"] = output.isZeroShutterLagSupported
                ? yn(output.isZeroShutterLagEnabled) : "unsupported"
            out["probeOutputResponsiveCaptureEnabled"] = output.isResponsiveCaptureSupported
                ? yn(output.isResponsiveCaptureEnabled) : "unsupported"
            out["maxPhotoQualityPrioritization"] =
                prioritizationString(output.maxPhotoQualityPrioritization)
            let rawFormats = output.availableRawPhotoPixelFormatTypes
            out["rawPixelFormatCount"] = String(rawFormats.count)
            out["rawPixelFormats"] = rawFormats.map(fourCC).joined(separator: " ")
            out["rawBayerFormats"] = rawFormats
                .filter { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
                .map(fourCC).joined(separator: " ")
            out["rawAppleProRAWFormats"] = rawFormats
                .filter { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
                .map(fourCC).joined(separator: " ")
            out["hasBayerRAW"] = yn(rawFormats.contains {
                AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })

            session.stopRunning()
            session.beginConfiguration()
            for existing in session.inputs { session.removeInput(existing) }
            for existing in session.outputs { session.removeOutput(existing) }
            session.commitConfiguration()
            out["sessionTornDown"] = yn(!session.isRunning)
        }
        return out
    }

    private nonisolated static func describeFormat(_ format: AVCaptureDevice.Format,
                                                   into out: inout [String: String],
                                                   prefix: String) {
        out["\(prefix)MinExposureSeconds"] =
            String(format: "%.8f", CMTimeGetSeconds(format.minExposureDuration))
        out["\(prefix)MaxExposureSeconds"] =
            String(format: "%.6f", CMTimeGetSeconds(format.maxExposureDuration))
        out["\(prefix)MinISO"] = String(format: "%.1f", format.minISO)
        out["\(prefix)MaxISO"] = String(format: "%.1f", format.maxISO)
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        out["\(prefix)VideoDimensions"] = "\(dims.width)x\(dims.height)"
        out["\(prefix)MaxPhotoDimensions"] = format.supportedMaxPhotoDimensions
            .map { "\($0.width)x\($0.height)" }.joined(separator: " ")
        out["\(prefix)FrameRateRanges"] = format.videoSupportedFrameRateRanges
            .map { String(format: "%.2f-%.2f", $0.minFrameRate, $0.maxFrameRate) }
            .joined(separator: " ")
        out["\(prefix)VideoHDRSupported"] = yn(format.isVideoHDRSupported)
    }

    private nonisolated static func describeDeviceModes(_ device: AVCaptureDevice,
                                                        into out: inout [String: String],
                                                        prefix: String) {
        out["\(prefix)ExposureCustomSupported"] = yn(device.isExposureModeSupported(.custom))
        out["\(prefix)ExposureLockedSupported"] = yn(device.isExposureModeSupported(.locked))
        out["\(prefix)ExposureContinuousSupported"] =
            yn(device.isExposureModeSupported(.continuousAutoExposure))
        var focusModes: [String] = []
        if device.isFocusModeSupported(.locked) { focusModes.append("locked") }
        if device.isFocusModeSupported(.autoFocus) { focusModes.append("autoFocus") }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            focusModes.append("continuousAutoFocus")
        }
        out["\(prefix)FocusModesSupported"] =
            focusModes.isEmpty ? "none" : focusModes.joined(separator: " ")
        out["\(prefix)CustomLensPositionSupported"] =
            yn(device.isLockingFocusWithCustomLensPositionSupported)
        // CURRENT modes, not just the supported set: a silent revert to
        // continuous auto-exposure is invisible in a capability list.
        out["\(prefix)ExposureMode"] = exposureModeString(device.exposureMode)
        out["\(prefix)FocusMode"] = focusModeString(device.focusMode)
        out["\(prefix)WhiteBalanceMode"] = "\(device.whiteBalanceMode.rawValue)"
        out["\(prefix)LensPosition"] = String(format: "%.4f", device.lensPosition)
        out["\(prefix)MinZoomFactor"] = String(format: "%.2f", device.minAvailableVideoZoomFactor)
        out["\(prefix)MaxZoomFactor"] = String(format: "%.2f", device.maxAvailableVideoZoomFactor)
    }

    // MARK: The clamp test (camera_probe)

    /// The night lock this probe asks the sensor for — the same shape the
    /// capture engine applies for the Milky Way / Perseid recipe.
    private nonisolated static let probeExposureSeconds = 1.0
    private nonisolated static let probeISO = 3200.0

    private nonisolated static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// Apply the real night lock — custom exposure at min(1 s, format max), the
    /// requested ISO clamped to the format, focus locked at infinity — and
    /// record BOTH what was asked for and what the format let us command. The
    /// difference between those two is a format clamp; the difference between
    /// the command and the read-back (see `readBackNightLock`) is a lock that
    /// did not take. A capability list can show neither.
    private nonisolated static func applyNightLockProbe(_ device: AVCaptureDevice,
                                                        into out: inout [String: String]) {
        out["nightLockRequestedExposureSeconds"] = String(format: "%.6f", probeExposureSeconds)
        out["nightLockRequestedISO"] = String(format: "%.1f", probeISO)
        guard device.isExposureModeSupported(.custom) else {
            out["nightLockApplied"] = "no"
            out["nightLockError"] = "custom exposure is NOT supported on this device/format — "
                + "1 s subs are impossible here"
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            out["nightLockApplied"] = "no"
            out["nightLockError"] = "lockForConfiguration failed: \(error.localizedDescription)"
            return
        }
        defer { device.unlockForConfiguration() }
        let format = device.activeFormat
        var duration = CMTime(seconds: probeExposureSeconds, preferredTimescale: 1_000_000_000)
        if duration > format.maxExposureDuration { duration = format.maxExposureDuration }
        if duration < format.minExposureDuration { duration = format.minExposureDuration }
        let iso = max(format.minISO, min(Float(probeISO), format.maxISO))
        let commandedSeconds = CMTimeGetSeconds(duration)
        out["nightLockCommandedExposureSeconds"] = String(format: "%.6f", commandedSeconds)
        out["nightLockCommandedISO"] = String(format: "%.1f", iso)
        out["nightLockClampedByFormat"] = yn(commandedSeconds < probeExposureSeconds - 1e-6
            || Double(iso) < probeISO - 0.5 || Double(iso) > probeISO + 0.5)
        device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
        if device.isLockingFocusWithCustomLensPositionSupported {
            device.setFocusModeLocked(lensPosition: 1.0, completionHandler: nil)
        } else if device.isFocusModeSupported(.locked) {
            device.focusMode = .locked
        }
        out["nightLockApplied"] = "yes"
    }

    /// What the sensor ACTUALLY settled at after the lock. Graded against the
    /// RAW request (1 s / ISO 3200), never against the already-clamped command —
    /// grading against the clamp would forgive exactly the failure being hunted.
    private nonisolated static func readBackNightLock(_ device: AVCaptureDevice,
                                                      into out: inout [String: String]) {
        guard out["nightLockApplied"] == "yes" else { return }
        let exposure = CMTimeGetSeconds(device.exposureDuration)
        let iso = Double(device.iso)
        out["nightLockActualExposureSeconds"] = String(format: "%.6f", exposure)
        out["nightLockActualISO"] = String(format: "%.1f", iso)
        out["nightLockActualExposureMode"] = exposureModeString(device.exposureMode)
        out["nightLockActualFocusMode"] = focusModeString(device.focusMode)
        out["nightLockActualLensPosition"] = String(format: "%.4f", device.lensPosition)
        let exposureOK = abs(exposure - probeExposureSeconds)
            <= max(0.02, probeExposureSeconds * 0.2)
        let isoOK = abs(iso - probeISO) <= max(50, probeISO * 0.2)
        out["nightLockHonoured"] = yn(exposureOK && isoOK)
        out["nightLockVerdict"] = exposureOK && isoOK
            ? "the sensor delivered the requested 1.000 s / ISO 3200 night lock"
            : "the sensor did NOT deliver the request — it settled at "
                + String(format: "%.4f s / ISO %.0f", exposure, iso)
                + ". If nightLockClampedByFormat is yes the active format could never "
                + "reach it; if no, the custom-exposure lock did not take."
        out["nightLockNote"] = "this probe leaves the device in custom exposure with focus "
            + "locked at infinity; a later probe's preSession* values will reflect that, and "
            + "CaptureEngine re-applies its own lock at session start either way"
    }

    private nonisolated static func exposureModeString(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked: return "locked(\(mode.rawValue))"
        case .autoExpose: return "autoExpose(\(mode.rawValue))"
        case .continuousAutoExposure: return "continuousAutoExposure(\(mode.rawValue))"
        case .custom: return "custom(\(mode.rawValue))"
        @unknown default: return "unknown(\(mode.rawValue))"
        }
    }

    private nonisolated static func focusModeString(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked: return "locked(\(mode.rawValue))"
        case .autoFocus: return "autoFocus(\(mode.rawValue))"
        case .continuousAutoFocus: return "continuousAutoFocus(\(mode.rawValue))"
        @unknown default: return "unknown(\(mode.rawValue))"
        }
    }

    private nonisolated static func authorizationString() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private nonisolated static func prioritizationString(
        _ value: AVCapturePhotoOutput.QualityPrioritization) -> String {
        switch value {
        case .speed: return "speed"
        case .balanced: return "balanced"
        case .quality: return "quality"
        @unknown default: return "unknown(\(value.rawValue))"
        }
    }

    private nonisolated static func fourCC(_ code: OSType) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let hex = "0x" + String(code, radix: 16)
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }),
              let text = String(bytes: bytes, encoding: .ascii) else { return hex }
        return "\(text)(\(hex))"
    }

    private nonisolated static func yn(_ value: Bool) -> String { value ? "yes" : "no" }

    #endif

    // MARK: - gimbal_probe

    private func runGimbalProbe(_ cmd: Command) async -> [String: Any] {
        let mount = MountService.shared
        mount.start()
        var report: [String: Any] = [:]

        // Give the accessory-state stream a chance to dock before reporting.
        let dockDeadline = Date().addingTimeInterval(cmd.timeoutSeconds ?? 12)
        while !isDocked(mount.connection), Date() < dockDeadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        report["mount"] = mountSnapshot()
        report["host"] = hostSnapshot()

        // Limits. The DockKit surface this build uses exposes no envelope or
        // speed query, so these are the MEASURED bench constants — labelled as
        // such, never dressed up as firmware-reported values.
        report["limits"] = [
            "source": "measured bench constants (GimbalConstants, Flow 2 Pro fw 5.50.80) — "
                    + "DockKit exposes no envelope/limit query in the API surface this "
                    + "build uses",
            "pitchMinDeg": GimbalConstants.pitchMinDeg,
            "pitchMaxDeg": GimbalConstants.pitchMaxDeg,
            "yawRange": "continuous; StarFlow budgets ±360° of net pan for cable wrap",
            "rollRange": "roll is inert to DockKit commands on the Flow 2 Pro",
            "maximumSpeedRadPerSec": GimbalConstants.slewRate,
            "maximumSpeedDegPerSec": round3(GimbalConstants.slewRate * 180.0 / .pi),
            "velocityFloorRadPerSec": GimbalConstants.velocityFloor,
            "velocityCommandLifetimeSeconds": 2.6,
            "encoderTickDeg": GimbalConstants.encoderTickDeg,
        ] as [String: Any]
        report["identity"] = [
            "hardwareModel": dockedName(mount.connection) ?? "not docked",
            "firmwareVersion": "not exposed by the DockKit API surface this build uses "
                             + "(bench reference: Flow 2 Pro fw 5.50.80)",
            "transport": MountService.isSimulated ? "SimulatedGimbal (in-process)" : "DockKit",
        ] as [String: Any]
        report["batteryPercent"] = jsonValue(mount.telemetry?.batteryPercent)
        report["batteryPercentNote"] = mount.telemetry?.batteryPercent == nil
            ? "no batteryStates sample yet" : "from DockKit batteryStates"

        // MEASURED motionStates sample rate over a 3 s window.
        let before = mount.encoderSampleCount
        let windowStart = Date()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let elapsed = Date().timeIntervalSince(windowStart)
        let samples = mount.encoderSampleCount - before
        report["motionStates"] = [
            "windowSeconds": round2(elapsed),
            "samples": samples,
            "measuredHz": elapsed > 0 ? round2(Double(samples) / elapsed) : 0,
            "benchReferenceHz": GimbalConstants.encoderRateHz,
        ] as [String: Any]

        guard isDocked(mount.connection) else {
            report["testMoves"] = ["skipped": "gimbal is not docked"]
            return report
        }
        guard mount.authority == .granted else {
            report["testMoves"] = ["skipped": "no motor authority — squeeze the trigger, "
                                            + "or run authority_experiment first"]
            return report
        }
        var moves: [[String: Any]] = []
        moves.append(await testMove(axis: .yaw, degrees: 2.0))
        moves.append(await testMove(axis: .yaw, degrees: -2.0))
        moves.append(await testMove(axis: .pitch, degrees: 2.0))
        moves.append(await testMove(axis: .pitch, degrees: -2.0))
        report["testMoves"] = moves
        report["mountAfterMoves"] = mountSnapshot()
        return report
    }

    private enum ProbeAxis: String { case yaw, pitch }

    /// One guarded framing move with realized-vs-commanded and settle time. It
    /// goes through the SAME `nudge` path a session uses, so what this measures
    /// is exactly what a session gets.
    private func testMove(axis: ProbeAxis, degrees: Double) async -> [String: Any] {
        let mount = MountService.shared
        await awaitFreshSamples(2)
        let beforePitch = mount.telemetry?.pitchDeg
        let beforeYaw = mount.telemetry?.yawDeg
        var out: [String: Any] = ["axis": axis.rawValue, "commandedDeg": degrees]
        let issuedAt = Date()
        do {
            switch axis {
            case .yaw: try await mount.nudge(deltaPitchDeg: 0, deltaYawDeg: degrees)
            case .pitch: try await mount.nudge(deltaPitchDeg: degrees, deltaYawDeg: 0)
            }
            out["accepted"] = true
        } catch {
            out["accepted"] = false
            out["error"] = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
            await mount.stopEverything()
            return out
        }
        let settleStart = Date()
        out["settled"] = await mount.waitSettled()
        out["settleSeconds"] = round2(Date().timeIntervalSince(settleStart))
        out["moveSeconds"] = round2(Date().timeIntervalSince(issuedAt))
        await awaitFreshSamples(2)
        switch axis {
        case .yaw:
            if let beforeYaw, let afterYaw = mount.telemetry?.yawDeg {
                let realized = CableWrapAccumulator.shortestDeltaDeg(from: beforeYaw, to: afterYaw)
                out["realizedDeg"] = round3(realized)
                out["errorDeg"] = round3(realized - degrees)
            } else {
                out["error"] = "no encoder telemetry to measure against"
            }
        case .pitch:
            if let beforePitch, let afterPitch = mount.telemetry?.pitchDeg {
                let realized = afterPitch - beforePitch
                out["realizedDeg"] = round3(realized)
                out["errorDeg"] = round3(realized - degrees)
            } else {
                out["error"] = "no encoder telemetry to measure against"
            }
        }
        await mount.stopEverything()
        return out
    }

    // MARK: - authority_experiment

    /// THE untested question: can motor authority be re-asserted programmatically,
    /// or does it genuinely require a physical trigger squeeze?
    ///
    /// A real experiment with a real chance of "nothing worked". Each candidate is
    /// tried in order and graded identically: authority before, the attempt (and
    /// any error it threw), authority after, and — crucially — a TINY raw velocity
    /// impulse that bypasses StarFlow's own authority guard, so we learn whether
    /// the MOTORS move even while `trackingButtonEnabled` reads false. Velocity is
    /// zeroed after every single step, and every test move is walked back so the
    /// experiment cannot drift the aim.
    private func runAuthorityExperiment(_ cmd: Command) async -> [String: Any] {
        let mount = MountService.shared
        mount.start()
        var report: [String: Any] = [:]

        let dockDeadline = Date().addingTimeInterval(cmd.timeoutSeconds ?? 12)
        while !isDocked(mount.connection), Date() < dockDeadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        report["initial"] = mountSnapshot()
        report["method"] = [
            "authoritySource": "DockAccessory.StateChange.trackingButtonEnabled, mirrored "
                             + "into MountService.authority",
            "testMove": "raw setAngularVelocity impulse (0.05 rad/s yaw for 0.4 s ≈ 1.15°) "
                      + "issued via MountService.debugRawImpulse, which DELIBERATELY "
                      + "bypasses the authority guard, then reversed and zeroed",
            "measurement": "shortest-arc encoder yaw delta from motionStates; a move counts "
                         + "as real above 3 encoder ticks (~0.021°)",
            "framingCaveat": "every test move is walked back, but candidate (b) issues a real "
                           + "2° setOrientation that is NOT reversed, and candidate (a) hands "
                           + "the gimbal to system tracking for 1.5 s. Compare initial.telemetry "
                           + "with final.telemetry for the net offset, and re-frame before "
                           + "capturing anything that matters.",
        ] as [String: Any]

        guard isDocked(mount.connection) else {
            report["error"] = "gimbal is not docked — dock the phone and re-run"
            report["candidates"] = [[String: Any]]()
            return report
        }

        // Baseline first: without it, a candidate that "works" cannot be told
        // apart from a gimbal that was already moving fine.
        report["baseline"] = [
            "authority": String(describing: mount.authority),
            "testMove": await rawTestMove(),
        ] as [String: Any]

        var candidates: [[String: Any]] = []
        candidates.append(await runCandidate(
            id: "a", name: "DockAccessoryManager.setSystemTrackingEnabled(true) then (false)",
            attempt: { await Self.candidateSystemTracking() }))
        candidates.append(await runCandidate(
            id: "b", name: "DockAccessory.setOrientation(+2° yaw)",
            attempt: { await Self.candidateSetOrientation() }))
        candidates.append(await runCandidate(
            id: "c", name: "DockAccessory.track(synthetic observation)",
            attempt: { Self.candidateTrackNotAttempted() }))
        candidates.append(await runCandidate(
            id: "d", name: "DockAccessory.selectSubject(at: frame center)",
            attempt: { await Self.candidateSelectSubject() }))
        report["candidates"] = candidates

        // Honest verdict, COMPUTED from the measurements — never asserted.
        let recovered = candidates.contains { candidate in
            (candidate["authorityBefore"] as? String) != "granted"
                && (candidate["authorityAfter"] as? String) == "granted"
        }
        let movedWithoutAuthority = candidates.contains { candidate in
            (candidate["authorityAfter"] as? String) != "granted"
                && ((candidate["testMove"] as? [String: Any])?["moved"] as? Bool) == true
        }
        // The control condition. Every "this candidate worked" claim is only
        // meaningful relative to these two facts, so they sit in the verdict
        // rather than buried in `baseline`.
        let baselineAuthority = (report["baseline"] as? [String: Any])?["authority"] as? String
        let baselineMoved = ((report["baseline"] as? [String: Any])?["testMove"]
            as? [String: Any])?["moved"] as? Bool ?? false
        // Was ANY candidate actually run against a denied state? If not, nothing
        // here can distinguish "the candidate worked" from "authority was
        // already on", and the report must say so in the verdict itself.
        let testedAgainstDenied = candidates.contains { candidate in
            (candidate["authorityBefore"] as? String) != "granted"
                && (candidate["attempted"] as? Bool) == true
        }
        var verdict: [String: Any] = [
            "authorityRecoveredByACandidate": recovered,
            "motorsMovedWithoutAuthority": movedWithoutAuthority,
            "baselineAuthority": jsonValue(baselineAuthority),
            "baselineMovedBeforeAnyCandidate": baselineMoved,
            "testedAgainstDeniedAuthority": testedAgainstDenied,
            // The experiment answers its question only when at least one
            // candidate ran while authority was denied. Anything else is a
            // dry run, however green it looks.
            "conclusive": testedAgainstDenied,
            "howToRead": "a candidate's testMove.moved is evidence about that candidate ONLY "
                + "if baselineMovedBeforeAnyCandidate is false; if the baseline already moved, "
                + "the motors were free the whole time and no candidate changed anything. "
                + "authorityBefore/authorityAfter is the only evidence about the authority "
                + "flag itself.",
        ]
        if !testedAgainstDenied {
            verdict["note"] = "INCONCLUSIVE: no candidate ever ran against a denied "
                + "authority state" + (mount.authority == .granted
                    ? " (authority was granted for this whole run)" : "")
                + ", so nothing here distinguishes 'the candidate worked' from 'authority "
                + "was already on'. Re-run with the tracking light OFF (undock and re-dock "
                + "without squeezing the trigger) for the answer that actually matters."
        } else if recovered && baselineMoved {
            verdict["note"] = "a candidate flipped trackingButtonEnabled to granted, but the "
                + "motors ALREADY moved in the baseline — so the flag changed while motion "
                + "was never blocked. Read authorityBefore/authorityAfter for which candidate, "
                + "and treat testMove as uninformative for this run."
        } else if recovered {
            verdict["note"] = "at least one candidate re-asserted authority — read the "
                + "per-candidate authorityBefore/authorityAfter pair to see which."
        } else if movedWithoutAuthority {
            verdict["note"] = "no candidate flipped trackingButtonEnabled, but the motors DID "
                + "execute a raw velocity impulse while authority read denied — on this "
                + "firmware the authority flag may be advisory for velocity control. "
                + (baselineMoved
                    ? "The BASELINE impulse already moved too, so this is a property of the "
                      + "firmware, not of any candidate."
                    : "The baseline impulse did NOT move, so a candidate changed something "
                      + "the authority flag does not report — read the per-candidate rows.")
        } else {
            verdict["note"] = "no candidate worked: authority stayed denied and the motors "
                + "did not move. On this firmware the trigger squeeze looks mandatory."
        }
        report["verdict"] = verdict
        report["final"] = mountSnapshot()
        return report
    }

    private func runCandidate(id: String, name: String,
                              attempt: () async -> String?) async -> [String: Any] {
        let mount = MountService.shared
        var out: [String: Any] = ["id": id, "name": name]
        out["authorityBefore"] = String(describing: mount.authority)
        let started = Date()
        let failure = await attempt()
        out["attemptSeconds"] = round2(Date().timeIntervalSince(started))
        if let failure {
            out["error"] = failure
            out["compiledOut"] = failure.hasPrefix("compiled out")
            out["attempted"] = !failure.hasPrefix("not attempted")
                && !failure.hasPrefix("compiled out")
        } else {
            out["error"] = NSNull()
            out["compiledOut"] = false
            out["attempted"] = true
        }
        // Let the accessory-state stream deliver any authority change.
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        out["authorityAfter"] = String(describing: mount.authority)
        out["connectionAfter"] = connectionString(mount.connection)
        out["testMove"] = await rawTestMove()
        await mount.stopEverything()
        return out
    }

    /// Tiny out-and-back raw impulse, measured on the encoder. Always ends
    /// stopped, and never runs while a real motion plan is in flight.
    ///
    /// A CONTROL runs first: the head is watched for the same duration with no
    /// command at all. Candidate (a) hands the gimbal to system tracking, which
    /// can leave it chasing a subject — without the control, that self-motion
    /// would be scored as "the impulse moved the motors". A move only counts
    /// when it clears both the encoder-noise floor AND the drift the control
    /// just measured.
    private func rawTestMove() async -> [String: Any] {
        let mount = MountService.shared
        let rate = 0.05          // rad/s — 25× the measured velocity floor
        let seconds = 0.4
        var out: [String: Any] = ["commandedDeg": round3(rate * seconds * 180.0 / .pi)]
        // --- control: same window, no command ---
        await awaitFreshSamples(2)
        let idleBefore = mount.telemetry?.yawDeg
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await awaitFreshSamples(3)
        let idleAfter = mount.telemetry?.yawDeg
        var idleDrift = 0.0
        if let idleBefore, let idleAfter {
            idleDrift = abs(CableWrapAccumulator.shortestDeltaDeg(from: idleBefore, to: idleAfter))
            out["idleDriftDeg"] = round3(idleDrift)
        } else {
            out["idleDriftDeg"] = NSNull()
        }
        // --- the impulse itself ---
        let noiseFloor = GimbalConstants.encoderTickDeg * 3
        let threshold = max(noiseFloor, idleDrift * 2)
        out["movedThresholdDeg"] = round3(threshold)
        await awaitFreshSamples(2)
        let before = mount.telemetry?.yawDeg
        let issued = await mount.debugRawImpulse(pitchRadPerSec: 0, yawRadPerSec: rate,
                                                 seconds: seconds)
        out["issued"] = issued
        await awaitFreshSamples(3)
        if let before, let after = mount.telemetry?.yawDeg {
            let moved = CableWrapAccumulator.shortestDeltaDeg(from: before, to: after)
            out["measuredDeg"] = round3(moved)
            // Three encoder ticks (~0.021°) is the smallest honest "it moved",
            // and the control's drift raises the bar when the head is restless.
            out["moved"] = issued && abs(moved) > threshold
            if !issued {
                out["note"] = "the impulse was REFUSED (a motion plan was in flight) — "
                    + "measuredDeg is whatever the head did on its own, not evidence "
                    + "about authority"
            } else if abs(moved) > noiseFloor && abs(moved) <= threshold {
                out["note"] = "motion was seen but did not clear the drift the control "
                    + "window measured — not attributable to the impulse"
            }
        } else {
            out["error"] = "no encoder telemetry to measure against"
            out["moved"] = false
        }
        // Put the frame back where it was, then stop.
        _ = await mount.debugRawImpulse(pitchRadPerSec: 0, yawRadPerSec: -rate, seconds: seconds)
        await mount.stopEverything()
        return out
    }

    /// Candidate (a) — the one manager API this app already drives in production.
    /// Returns nil on success, otherwise a human-readable error string.
    private static func candidateSystemTracking() async -> String? {
        #if canImport(DockKit) && !targetEnvironment(simulator)
        do {
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(true)
        } catch {
            return "setSystemTrackingEnabled(true) threw: \(String(describing: error))"
        }
        // Bounded window: system tracking makes the gimbal chase subjects, which
        // is exactly what a star session must never do.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        do {
            try await DockAccessoryManager.shared.setSystemTrackingEnabled(false)
        } catch {
            return "setSystemTrackingEnabled(false) threw: \(String(describing: error)) — "
                 + "SYSTEM TRACKING MAY STILL BE ON; undock to be safe"
        }
        return nil
        #else
        return "not attempted: DockKit is unavailable in this build (simulator)"
        #endif
    }

    /// Candidate (b) — see the escape-hatch note at the top of this file.
    private static func candidateSetOrientation() async -> String? {
        #if canImport(DockKit) && !targetEnvironment(simulator)
        #if STARFLOW_NO_DOCKKIT_EXPERIMENTS
        return "compiled out (STARFLOW_NO_DOCKKIT_EXPERIMENTS)"
        #else
        guard let accessory = MountService.shared.debugAccessory else {
            return "not attempted: no docked DockKit accessory"
        }
        do {
            // 2° about the yaw axis — deliberately above the ~1.5° dead-band the
            // bench measured, so a refusal means the API refused, not the band.
            let rotation = Rotation3D(angle: Angle2D(degrees: 2.0),
                                      axis: RotationAxis3D(x: 0, y: 1, z: 0))
            try await accessory.setOrientation(rotation)
            return nil
        } catch {
            return "setOrientation threw: \(String(describing: error))"
        }
        #endif
        #else
        return "not attempted: DockKit is unavailable in this build (simulator)"
        #endif
    }

    /// Candidate (c) — honestly NOT attempted, with the reason stated in full.
    /// Fabricating camera intrinsics to satisfy `track()` would produce a result
    /// nobody could trust, which is worse than a missing data point.
    private static func candidateTrackNotAttempted() -> String? {
        "not attempted: DockAccessory.track() needs a CameraObservation plus a "
        + "CameraInformation built from a LIVE AVCaptureSession (camera intrinsics and "
        + "reference dimensions). This experiment deliberately runs with the camera torn "
        + "down, and inventing intrinsics would make any result untrustworthy. Run "
        + "camera_probe for the capability set first if this candidate becomes worth "
        + "wiring to a real session."
    }

    /// Candidate (d) — see the escape-hatch note at the top of this file.
    private static func candidateSelectSubject() async -> String? {
        #if canImport(DockKit) && !targetEnvironment(simulator)
        #if STARFLOW_NO_DOCKKIT_EXPERIMENTS
        return "compiled out (STARFLOW_NO_DOCKKIT_EXPERIMENTS)"
        #else
        guard let accessory = MountService.shared.debugAccessory else {
            return "not attempted: no docked DockKit accessory"
        }
        do {
            try await accessory.selectSubject(at: CGPoint(x: 0.5, y: 0.5))
            return nil
        } catch {
            return "selectSubject threw: \(String(describing: error))"
        }
        #endif
        #else
        return "not attempted: DockKit is unavailable in this build (simulator)"
        #endif
    }

    // MARK: - endurance

    /// Long-run stability: hold a real session for N minutes, sampling the whole
    /// machine every 30 s into `endurance.csv`, and summarize at the end. This is
    /// the action that answers "will it survive until dawn?".
    private func runEndurance(_ cmd: Command) async -> [String: Any] {
        let engine = SessionEngine.shared
        let modeId = cmd.modeId ?? "milkyway"
        guard let shot = ShotModeRegistry.all.first(where: { $0.id == modeId }) else {
            return ["error": "unknown modeId \(modeId)",
                    "known": ShotModeRegistry.all.map(\.id)]
        }
        let minutes = min(240.0, max(1.0, cmd.minutes ?? 30.0))
        let interval: TimeInterval = 30
        applyFrameEvidenceSettings(cmd)

        let csvURL = dir.appendingPathComponent("endurance.csv")
        let header = "elapsedSeconds,phase,subsAccepted,subsRejected,subsSkippedClouds,"
            + "subsLostToClouds,integrationSeconds,thermalState,batteryPercent,freeDiskMB,"
            + "memoryFootprintMB,framesPerMinuteCumulative,framesPerMinuteInterval,"
            + "mountConnection,mountAuthority,gimbalBatteryPercent,starCountLast,"
            + "starCountPeak,skyCondition,interruption\n"
        var csv = header
        try? csv.write(to: csvURL, atomically: true, encoding: .utf8)

        let started = Date()
        presentedShot = shot
        engine.start(shot: shot)

        var samples = 0
        var peakMemoryMB = 0.0
        var maxThermal = ProcessInfo.processInfo.thermalState
        var batteryStart: Int?
        var batteryEnd: Int?
        var diskStartMB: Int64?
        var diskEndMB: Int64?
        var lastAccepted = 0
        var authorityLosses = 0
        var samplesUndocked = 0
        var lastAuthority = MountService.shared.authority
        var endedEarly: String?

        func appendSample(at elapsed: TimeInterval, intervalSeconds: TimeInterval) {
            let stats = engine.stats
            let mount = MountService.shared
            let thermal = ProcessInfo.processInfo.thermalState
            if thermal.rawValue > maxThermal.rawValue { maxThermal = thermal }
            let battery = SessionHooks.systemBatteryPercent()
            if batteryStart == nil { batteryStart = battery }
            if let battery { batteryEnd = battery }
            let freeMB = SessionHooks.systemFreeDiskBytes().map { $0 / 1_048_576 }
            if diskStartMB == nil { diskStartMB = freeMB }
            if let freeMB { diskEndMB = freeMB }
            let memory = Self.memoryFootprintMB()
            peakMemoryMB = max(peakMemoryMB, memory ?? 0)
            let minutesElapsed = max(elapsed / 60.0, 1.0 / 60.0)
            let cumulativeFPM = Double(stats.subsAccepted) / minutesElapsed
            let deltaAccepted = stats.subsAccepted - lastAccepted
            lastAccepted = stats.subsAccepted
            let intervalFPM = intervalSeconds > 0
                ? Double(deltaAccepted) / (intervalSeconds / 60.0) : 0
            if mount.authority != lastAuthority {
                if mount.authority != .granted { authorityLosses += 1 }
                lastAuthority = mount.authority
            }
            if !isDocked(mount.connection) { samplesUndocked += 1 }

            let row = [
                String(format: "%.0f", elapsed),
                engine.phase.rawValue,
                "\(stats.subsAccepted)", "\(stats.subsRejected)",
                "\(stats.subsSkippedClouds)", "\(stats.subsLostToClouds)",
                String(format: "%.1f", stats.integrationSeconds),
                Self.thermalString(thermal),
                battery.map { String($0) } ?? "",
                freeMB.map { String($0) } ?? "",
                memory.map { String(format: "%.1f", $0) } ?? "",
                String(format: "%.2f", cumulativeFPM),
                String(format: "%.2f", intervalFPM),
                connectionString(mount.connection),
                String(describing: mount.authority),
                mount.telemetry?.batteryPercent.map { String($0) } ?? "",
                "\(stats.lastStarCount)", "\(stats.peakStarCount)",
                engine.skyCondition.rawValue,
                (engine.interruption.map { String(describing: $0) } ?? "none")
                    .replacingOccurrences(of: ",", with: ";"),
            ].joined(separator: ",")
            csv += row + "\n"
            try? csv.write(to: csvURL, atomically: true, encoding: .utf8)
            samples += 1
        }

        appendSample(at: 0, intervalSeconds: 0)
        let deadline = started.addingTimeInterval(minutes * 60)
        var nextSample = started.addingTimeInterval(interval)
        var lastSampleAt = started
        while Date() < deadline {
            if engine.phase == .complete || !engine.isRunning {
                endedEarly = "session reached \(engine.phase.rawValue) after "
                    + String(format: "%.0f s", Date().timeIntervalSince(started))
                    + " — \(engine.statusDetail)"
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard Date() >= nextSample else { continue }
            let now = Date()
            appendSample(at: now.timeIntervalSince(started),
                         intervalSeconds: now.timeIntervalSince(lastSampleAt))
            lastSampleAt = now
            nextSample = now.addingTimeInterval(interval)
            writeJSON([
                "id": cmd.id, "state": "running", "action": "endurance",
                "elapsed": String(format: "%.0f", now.timeIntervalSince(started)),
                "plannedSeconds": String(format: "%.0f", minutes * 60),
                "samples": "\(samples)",
                "phase": engine.phase.rawValue,
                "subsAccepted": "\(engine.stats.subsAccepted)",
                "statusDetail": engine.statusDetail,
            ].merging(frameEvidenceFields(), uniquingKeysWith: { a, _ in a }),
                      to: "progress.json")
        }
        let finalElapsed = Date().timeIntervalSince(started)
        appendSample(at: finalElapsed, intervalSeconds: Date().timeIntervalSince(lastSampleAt))

        let statsAtEnd = engine.stats
        if engine.isRunning { engine.abort() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let img = engine.latestPreview { writePNG(img, to: "preview.png") }

        var report: [String: Any] = [
            "modeId": shot.id,
            "plannedMinutes": minutes,
            "actualMinutes": round2(finalElapsed / 60.0),
            "samples": samples,
            "sampleIntervalSeconds": interval,
            "csvPath": "autotest/endurance.csv",
            "csvColumns": header.trimmingCharacters(in: .whitespacesAndNewlines),
            "endedEarly": jsonValue(endedEarly),
            "finalPhase": engine.phase.rawValue,
            "statusDetail": engine.statusDetail,
        ]
        var summary: [String: Any] = [
            "subsAccepted": statsAtEnd.subsAccepted,
            "subsRejected": statsAtEnd.subsRejected,
            "subsSkippedClouds": statsAtEnd.subsSkippedClouds,
            "integrationSeconds": round2(statsAtEnd.integrationSeconds),
            "framesPerMinute": finalElapsed > 0
                ? round2(Double(statsAtEnd.subsAccepted) / (finalElapsed / 60.0)) : 0,
            "nudges": statsAtEnd.nudges,
            "driftCorrections": statsAtEnd.driftCorrections,
            "flapsRecovered": statsAtEnd.flapsRecovered,
            "peakStarCount": statsAtEnd.peakStarCount,
            "peakMemoryFootprintMB": round2(peakMemoryMB),
            "maxThermalState": Self.thermalString(maxThermal),
            "batteryStartPercent": jsonValue(batteryStart),
            "batteryEndPercent": jsonValue(batteryEnd),
            "freeDiskStartMB": jsonValue(diskStartMB.map { Int($0) }),
            "freeDiskEndMB": jsonValue(diskEndMB.map { Int($0) }),
            "authorityLosses": authorityLosses,
            "samplesWithMountUndocked": samplesUndocked,
            "skyCondition": engine.skyCondition.rawValue,
        ]
        if let start = batteryStart, let end = batteryEnd {
            summary["batteryDropPercent"] = start - end
        }
        if let start = diskStartMB, let end = diskEndMB {
            summary["diskConsumedMB"] = Int(start - end)
        }
        report["summary"] = summary
        report["focusSweep"] = focusSweepReport(engine.focusSweepStatus)
        report["frames"] = frameArtifacts()
        report["mount"] = mountSnapshot()
        report["host"] = hostSnapshot()
        presentedShot = nil
        return report
    }

    // MARK: - field_failures

    /// Scripted resilience run: start a real session, then deliberately break
    /// things on a schedule and prove the session survived each one — with the
    /// motors MEASURED stopped at every break.
    private func runFieldFailures(_ cmd: Command) async -> [String: Any] {
        let engine = SessionEngine.shared
        let modeId = cmd.modeId ?? "milkyway"
        guard let shot = ShotModeRegistry.all.first(where: { $0.id == modeId }) else {
            return ["error": "unknown modeId \(modeId)",
                    "known": ShotModeRegistry.all.map(\.id)]
        }
        let timeout = cmd.timeoutSeconds ?? 180
        applyFrameEvidenceSettings(cmd)

        var report: [String: Any] = ["modeId": shot.id]
        var events: [[String: Any]] = []

        presentedShot = shot
        engine.start(shot: shot)

        // Wait until the session is actually capturing — breaking a session that
        // never left Connect proves nothing.
        let captureDeadline = Date().addingTimeInterval(timeout)
        while engine.phase != .capture, engine.phase != .complete, Date() < captureDeadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        report["reachedCapture"] = engine.phase == .capture
        guard engine.phase == .capture else {
            report["error"] = "session never reached Capture within \(Int(timeout)) s "
                + "(phase \(engine.phase.rawValue): \(engine.statusDetail)) — dock the "
                + "gimbal and grant authority, then re-run"
            report["events"] = events
            if engine.isRunning { engine.abort() }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            report["finalPhase"] = engine.phase.rawValue
            report["mount"] = mountSnapshot()
            presentedShot = nil
            return report
        }
        // Let a few real frames land so "before" means something.
        try? await Task.sleep(nanoseconds: 12_000_000_000)

        // --- Event 1: simulated backgrounding ---
        var backgrounding: [String: Any] = [
            "event": "backgrounding",
            "how": "SessionEngine.handleBackgrounded() → handleForegrounded() → resume()",
            "statsBefore": statsSnapshot(engine),
        ]
        await engine.handleBackgrounded()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        backgrounding["interruptionWhileBackgrounded"] =
            engine.interruption.map { String(describing: $0) } ?? "none"
        backgrounding["statusWhileBackgrounded"] = engine.statusDetail
        backgrounding["zeroVelocityWhileBackgrounded"] = await confirmStopped()
        await engine.handleForegrounded()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        backgrounding["awaitingResume"] = engine.awaitingResume
        engine.resume()
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        backgrounding["statsAfter"] = statsSnapshot(engine)
        backgrounding["phaseAfter"] = engine.phase.rawValue
        backgrounding["capturedMoreFramesAfter"] = capturedMore(backgrounding, engine)
        backgrounding["survived"] = engine.isRunning && engine.phase != .complete
        events.append(backgrounding)

        // --- Event 2: mount flap ---
        let connectionBefore = connectionString(MountService.shared.connection)
        var flap: [String: Any] = [
            "event": "mountFlap",
            "how": "MountService.debugSimulateUndock() → debugSimulateRedock()",
            "statsBefore": statsSnapshot(engine),
            "connectionBefore": connectionBefore,
        ]
        let flapsBefore = engine.stats.flapsRecovered
        MountService.shared.debugSimulateUndock()
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let connectionDuring = connectionString(MountService.shared.connection)
        flap["connectionDuring"] = connectionDuring
        flap["hooksEffective"] = connectionDuring != connectionBefore
        flap["interruptionWhileUndocked"] =
            engine.interruption.map { String(describing: $0) } ?? "none"
        flap["zeroVelocityWhileUndocked"] = await confirmStopped()
        MountService.shared.debugSimulateRedock()
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        flap["connectionAfter"] = connectionString(MountService.shared.connection)
        flap["flapsRecoveredDelta"] = engine.stats.flapsRecovered - flapsBefore
        flap["pointingInvalidated"] = engine.pointingInvalidated
        flap["statsAfter"] = statsSnapshot(engine)
        flap["capturedMoreFramesAfter"] = capturedMore(flap, engine)
        flap["survived"] = engine.isRunning && engine.phase != .complete
        if !MountService.isSimulated {
            flap["note"] = "debugSimulateUndock/Redock compile to NO-OPS on hardware builds — "
                + "`hooksEffective: false` here is expected, not a failure. On the real "
                + "Flow 2 Pro, physically undock and re-dock the phone during this ~19 s "
                + "window and read connectionDuring / flapsRecoveredDelta to grade the "
                + "real flap."
        }
        events.append(flap)

        // --- Wrap up ---
        report["events"] = events
        report["survivedEverything"] = events.allSatisfy { ($0["survived"] as? Bool) == true }
        report["statsFinal"] = statsSnapshot(engine)
        report["focusSweep"] = focusSweepReport(engine.focusSweepStatus)
        report["frames"] = frameArtifacts()
        if engine.isRunning { engine.abort() }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if let img = engine.latestPreview { writePNG(img, to: "preview.png") }
        report["finalPhase"] = engine.phase.rawValue
        report["statusDetail"] = engine.statusDetail
        report["zeroVelocityAfterAbort"] = await confirmStopped()
        report["mount"] = mountSnapshot()
        report["host"] = hostSnapshot()
        presentedShot = nil
        return report
    }

    /// True when the session accepted at least one more frame after an event
    /// than it had before it — the honest "it kept working" test.
    private func capturedMore(_ event: [String: Any], _ engine: SessionEngine) -> Bool {
        guard let before = (event["statsBefore"] as? [String: Any])?["subsAccepted"] as? Int
        else { return false }
        return engine.stats.subsAccepted > before
    }

    private func statsSnapshot(_ engine: SessionEngine) -> [String: Any] {
        let stats = engine.stats
        return [
            "phase": engine.phase.rawValue,
            "isRunning": engine.isRunning,
            "subsAccepted": stats.subsAccepted,
            "subsRejected": stats.subsRejected,
            "subsSkippedClouds": stats.subsSkippedClouds,
            "integrationSeconds": round2(stats.integrationSeconds),
            "nudges": stats.nudges,
            "flapsRecovered": stats.flapsRecovered,
            "starCountLast": stats.lastStarCount,
            "framesLogged": FrameTruthLog.shared.rowsWritten,
            "interruption": engine.interruption.map { String(describing: $0) } ?? "none",
        ]
    }

    // MARK: - Per-frame evidence summary

    /// What the frame ledger has written so far, plus the newest row's camera
    /// truth. This is the harness-visible half of the per-frame evidence — the
    /// full detail lives in `frames.csv` and `frames/index.json` next to these
    /// reports, so one `afc` pull of `Documents/autotest/` takes everything.
    ///
    /// `lastFrameHonoursRequest` is the alarm that matters in the field: "NO"
    /// means the sensor did not deliver the requested exposure/ISO for the last
    /// logged frame — auto-exposure crept back in, or the active format clamped
    /// the request (`lastFrameExposureClamped` says which), and the stack is not
    /// what the recipe asked for. It reads "n/a" — never "yes" — whenever the
    /// row carries no sensor read-back to judge, so a simulator run can never
    /// look like a passing hardware run.
    private func frameEvidenceFields() -> [String: String] {
        let log = FrameTruthLog.shared
        var fields: [String: String] = [
            "framesLogged": "\(log.rowsWritten)",
            "frameDumps": "\(log.dumpsWritten)",
            "frameDumpEveryN": "\(log.dumpEveryN)",
            "framesCSV": FrameEvidence.csvURL.lastPathComponent,
            "framesDirectory": "frames/",
        ]
        guard let truth = log.lastRow else { return fields }
        fields["lastFrameIndex"] = "\(truth.frameIndex)"
        fields["lastFrameSimulated"] = truth.simulated ? "1" : "0"
        fields["lastFrameSensorMeasured"] = truth.sensorMeasured ? "1" : "0"
        fields["lastFrameRequestedExposure"] = String(format: "%.4f",
                                                      truth.requestedExposureSeconds)
        fields["lastFrameActualExposure"] = String(format: "%.4f", truth.actualExposureSeconds)
        fields["lastFrameRequestedISO"] = String(format: "%.0f", truth.requestedISO)
        fields["lastFrameActualISO"] = String(format: "%.0f", truth.actualISO)
        // A verdict is only ever printed for a row a real sensor vouched for.
        // A simulated or echoed row reports "n/a", never "yes" — a green light
        // on synthetic numbers is the one thing this report must never show.
        if truth.simulated {
            fields["lastFrameHonoursRequest"] = "n/a (SIMULATED frame — no sensor involved)"
        } else if !truth.sensorMeasured {
            fields["lastFrameHonoursRequest"] = "n/a (no camera read-back for this frame — "
                + "the actual* values echo the request and prove nothing)"
        } else {
            fields["lastFrameHonoursRequest"] = truth.honoursRequest ? "yes" : "NO"
        }
        fields["lastFrameTargetExposure"] = String(format: "%.4f", truth.targetExposureSeconds)
        fields["lastFrameExposureClamped"] = truth.exposureClamped ? "YES" : "no"
        fields["lastFrameFocusLocked"] = truth.sensorMeasured
            ? (truth.focusLocked ? "yes" : "NO") : "n/a"
        fields["lastFrameExposureMode"] = "\(truth.exposureModeRaw)"
        fields["lastFrameFocusMode"] = "\(truth.focusModeRaw)"
        fields["lastFrameLensPosition"] = String(format: "%.3f", truth.lensPosition)
        fields["lastFrameFormat"] = truth.formatSummary
        fields["lastFrameRawDelivered"] = truth.rawDelivered ? "yes" : "no"
        fields["lastFrameZSL"] = truth.zslEnabled ? "on" : "off"
        fields["lastFrameResponsive"] = truth.responsiveEnabled ? "on" : "off"
        fields["lastFrameShotToShot"] = truth.shotToShotSeconds
            .map { String(format: "%.3f", $0) } ?? "n/a"
        fields["lastFrameExifExposure"] = truth.exifExposureSeconds
            .map { String(format: "%.4f", $0) } ?? "n/a"
        fields["lastFrameExifISO"] = truth.exifISO.map { String(format: "%.0f", $0) } ?? "n/a"
        fields["lastFrameStars"] = truth.starCount.map { "\($0)" } ?? "n/a"
        fields["lastFrameAccepted"] = truth.stackAccepted.map { $0 ? "yes" : "no" } ?? "n/a"
        fields["lastFrameRejectionReason"] = truth.rejectionReason ?? "none"
        return fields
    }

    /// Where the dumped frames landed, as paths relative to the app's Documents
    /// directory. The per-file list (with each file's FrameTruth) is written by
    /// the ledger itself into `frames/index.json`.
    private func frameArtifacts() -> [String: Any] {
        let log = FrameTruthLog.shared
        return [
            "logged": log.rowsWritten,
            "dumped": log.dumpsWritten,
            "dumpEveryN": log.dumpEveryN,
            "cap": FrameEvidence.maxDumpedFiles,
            "csvPath": "autotest/frames.csv",
            "indexPath": "autotest/frames/index.json",
            "firstFramePath": "autotest/frames/" + FrameEvidence.firstFrameName,
            "directory": "autotest/frames/",
            "note": "index.json enumerates every dumped file with the camera truth for "
                  + "that exact frame; frames.csv has one row per delivered frame",
        ]
    }

    // MARK: - Snapshots

    private func mountSnapshot() -> [String: Any] {
        let mount = MountService.shared
        // Tri-state, deliberately: `authority == .unknown` means DockKit has told
        // us NOTHING about the trigger yet. Collapsing that to `false` would
        // report "the trigger is not squeezed" on no evidence at all.
        let trackingButton: NSObject = mount.authority == .unknown
            ? NSNull() : NSNumber(value: mount.authority == .granted)
        var out: [String: Any] = [
            "connection": connectionString(mount.connection),
            "connectionDetail": String(describing: mount.connection),
            "authority": String(describing: mount.authority),
            "trackingButtonEnabled": trackingButton,
            "docked": isDocked(mount.connection),
            "accessoryName": jsonValue(dockedName(mount.connection)),
            "netPanDeg": round2(mount.netPanDeg),
            "cableWrapWarning": mount.cableWrapWarning,
            "isSimulated": MountService.isSimulated,
            "encoderSampleCount": mount.encoderSampleCount,
        ]
        if let telemetry = mount.telemetry {
            out["telemetry"] = [
                "pitchDeg": round3(telemetry.pitchDeg),
                "yawDeg": round3(telemetry.yawDeg),
                "speedDegPerSec": round3(telemetry.speedDegPerSec),
                "batteryPercent": jsonValue(telemetry.batteryPercent),
            ] as [String: Any]
        } else {
            out["telemetry"] = NSNull()
        }
        return out
    }

    private func hostSnapshot() -> [String: Any] {
        [
            "deviceModel": Self.deviceModelIdentifier(),
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "thermalState": Self.thermalString(ProcessInfo.processInfo.thermalState),
            "batteryPercent": jsonValue(SessionHooks.systemBatteryPercent()),
            "freeDiskMB": jsonValue(SessionHooks.systemFreeDiskBytes()
                .map { Int($0 / 1_048_576) }),
            "memoryFootprintMB": jsonValue(Self.memoryFootprintMB().map { round2($0) }),
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
        ]
    }

    // MARK: - Small helpers

    private func isDocked(_ connection: MountConnection) -> Bool {
        if case .docked = connection { return true }
        return false
    }

    private func dockedName(_ connection: MountConnection) -> String? {
        if case .docked(let name) = connection { return name }
        return nil
    }

    private func connectionString(_ connection: MountConnection) -> String {
        switch connection {
        case .searching: return "searching"
        case .docked: return "docked"
        case .flapping: return "flapping"
        case .undocked: return "undocked"
        }
    }

    /// Block until `count` fresh encoder samples have landed (or we give up), so
    /// a before/after angle comparison is made against genuinely new data.
    private func awaitFreshSamples(_ count: Int, timeout: TimeInterval = 3.0) async {
        let mount = MountService.shared
        let start = mount.encoderSampleCount
        let deadline = Date().addingTimeInterval(timeout)
        while mount.encoderSampleCount - start < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// JSON-safe optional: a present value, or `NSNull`. Deliberately explicit —
    /// `someOptional as Any? ?? NSNull()` double-wraps and silently emits the
    /// wrapped `nil` instead of a JSON null.
    private func jsonValue<T>(_ value: T?) -> Any {
        guard let value else { return NSNull() }
        return value
    }

    private func round2(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 100).rounded() / 100
    }

    private func round3(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1000).rounded() / 1000
    }

    private nonisolated static func thermalString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Real memory footprint — the number iOS jetsams on — via `task_info`.
    private nonisolated static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576.0
    }

    private nonisolated static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let characters = Mirror(reflecting: info.machine).children
            .compactMap { child -> Character? in
                guard let value = child.value as? Int8, value != 0 else { return nil }
                return Character(UnicodeScalar(UInt8(bitPattern: value)))
            }
        return characters.isEmpty ? "unknown" : String(characters)
    }

    // MARK: - Output helpers

    private func writeJSON(_ dict: [String: String], to name: String) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    /// Structured (nested) report writer. Values `JSONSerialization` would
    /// reject are sanitized first, and if serialization still fails a minimal
    /// error report is written instead — this file must ALWAYS appear.
    private func writeReport(_ dict: [String: Any], to name: String) {
        let url = dir.appendingPathComponent(name)
        let sanitized = Self.sanitize(dict)
        if JSONSerialization.isValidJSONObject(sanitized),
           let data = try? JSONSerialization.data(withJSONObject: sanitized,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            return
        }
        let fallback: [String: String] = [
            "id": (dict["id"] as? String) ?? "unknown",
            "action": (dict["action"] as? String) ?? "unknown",
            "state": "done",
            "error": "the report could not be serialized to JSON — the action itself ran; "
                   + "see progress.json for the last live state",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fallback,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Recursively replace values `JSONSerialization` would reject (non-finite
    /// doubles, unexpected types) with something it accepts, so a report can
    /// never be lost to a serialization throw.
    private nonisolated static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { sanitize($0) }
        case let array as [Any]:
            return array.map { sanitize($0) }
        case let number as Double:
            return number.isFinite ? number : NSNull()
        case let number as Float:
            return number.isFinite ? Double(number) : NSNull()
        case let number as Int64:
            return NSNumber(value: number)
        case is Int, is Bool, is String, is NSNull, is NSNumber:
            return value
        default:
            return String(describing: value)
        }
    }

    private func writePNG(_ image: CGImage, to name: String) {
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
