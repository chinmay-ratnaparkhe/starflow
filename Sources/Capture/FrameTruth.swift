import Foundation
import CoreGraphics
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - FrameEvidence (where the per-frame truth lands)

/// The on-disk evidence tree the USB harness pulls:
///
///   Documents/autotest/frames.csv          one row per DELIVERED frame
///   Documents/autotest/frames/first.jpg    the very first frame, always
///   Documents/autotest/frames/f<n>.jpg     every Nth frame + the first 3
///   Documents/autotest/frames/index.json   the dumped files with their FrameTruth
///
/// Same directory `AutoTestRunner` already reads/writes, so one `afc` pull of
/// `Documents/autotest/` collects the whole night's proof.
public enum FrameEvidence {

    public static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("autotest", isDirectory: true)
    }
    public static var csvURL: URL { directory.appendingPathComponent("frames.csv") }
    public static var framesDirectory: URL {
        directory.appendingPathComponent("frames", isDirectory: true)
    }
    public static var indexURL: URL { framesDirectory.appendingPathComponent("index.json") }
    public static var firstFrameName: String { "first.jpg" }
    public static func dumpName(frameIndex: Int) -> String { "f\(frameIndex).jpg" }

    // MARK: Dump policy (pure, unit-tested — no actor, no I/O)

    /// Every Nth frame is dumped as a JPEG (configurable per run).
    public static let defaultDumpEveryN = 10
    /// …and the first this many frames are ALWAYS dumped, whatever N is.
    public static let alwaysDumpFirstFrames = 3
    /// Hard cap on dumped files (oldest pruned). `first.jpg` is exempt: the very
    /// first frame of the night is always kept.
    public static let maxDumpedFiles = 40
    /// Longest side of a dumped JPEG.
    public static let dumpMaxSide = 1400
    /// JPEG quality for dumps.
    public static let dumpQuality = 0.8

    /// A frame is dumped when it is one of the first `alwaysDumpFirstFrames`,
    /// or lands on the configured cadence. `everyN <= 0` disables the cadence
    /// (the first frames are still kept — evidence of the very first exposure
    /// is never optional).
    public static func shouldDump(frameIndex: Int, everyN: Int) -> Bool {
        guard frameIndex >= 0 else { return false }
        if frameIndex < alwaysDumpFirstFrames { return true }
        guard everyN > 0 else { return false }
        return frameIndex % everyN == 0
    }

    /// Clamp a requested dump cadence into something sane (0 = dumping off
    /// beyond the mandatory first frames).
    public static func sanitizedDumpEveryN(_ raw: Int) -> Int {
        guard raw > 0 else { return 0 }
        return min(raw, 10_000)
    }
}

// MARK: - CapturePhotoFacts

/// The facts only the photo itself can tell us — read off `AVCapturePhoto` in the
/// capture delegate and carried back to the engine with the pixels. Every field is
/// defaulted so the simulator path can pass an empty value.
public struct CapturePhotoFacts: Sendable, Equatable {
    /// True when a Bayer RAW plane actually arrived for this capture.
    public var rawDelivered: Bool
    /// EXIF `ExposureTime` / `ISOSpeedRatings` from the delivered photo — the
    /// camera's own account of the frame, independent of what we asked for.
    public var exifExposureSeconds: Double?
    public var exifISO: Double?
    public var photoWidth: Int
    public var photoHeight: Int

    public init(rawDelivered: Bool = false,
                exifExposureSeconds: Double? = nil,
                exifISO: Double? = nil,
                photoWidth: Int = 0,
                photoHeight: Int = 0) {
        self.rawDelivered = rawDelivered
        self.exifExposureSeconds = exifExposureSeconds
        self.exifISO = exifISO
        self.photoWidth = photoWidth
        self.photoHeight = photoHeight
    }
}

// MARK: - FrameTruth

/// What the camera ACTUALLY did for one delivered frame — not what we asked for.
///
/// The requested/actual pairs are the whole point: a 1 s / ISO 3200 recipe that
/// silently lands as an 8 ms / ISO 500 auto-exposure frame looks identical in
/// every other telemetry surface. This struct is captured per frame on device
/// (from the live `AVCaptureDevice` plus the photo's own EXIF) and synthesized —
/// clearly marked `simulated` — in the simulator, then written as one CSV row.
///
/// The trailing fields (`sessionFrameIndex` … `residualPx`) are ANNOTATIONS the
/// session engine adds after the stacker has judged the same frame, so a single
/// row carries both the camera truth and the stack verdict.
public struct FrameTruth: Sendable, Equatable {

    // Camera truth (filled by CaptureEngine on delivery)
    public var frameIndex: Int
    public var timestamp: Date
    /// 1 in the CSV when these numbers came from the synthetic starfield, never
    /// from a sensor. Fake data can never masquerade as evidence.
    public var simulated: Bool
    /// True ONLY when `actualExposureSeconds` / `actualISO` / the mode columns
    /// were read back from a live `AVCaptureDevice` for this frame. False means
    /// the row was synthesized from what the app ASKED for (simulator frames, or
    /// a device frame the capture engine did not stage) — those numbers are not
    /// sensor evidence and `honoursRequest` is written empty for them, because a
    /// request compared against itself would always agree.
    public var sensorMeasured: Bool
    public var requestedExposureSeconds: Double
    public var actualExposureSeconds: Double
    public var requestedISO: Double
    public var actualISO: Double
    /// `AVCaptureDevice.ExposureMode` raw value (2 = custom, the night lock). -1 = unknown.
    public var exposureModeRaw: Int
    /// `AVCaptureDevice.FocusMode` raw value (0 = locked). -1 = unknown.
    public var focusModeRaw: Int
    /// 0…1 lens travel; 1.0 is the infinity end the engine locks. -1 = unknown.
    public var lensPosition: Double
    /// `AVCaptureDevice.WhiteBalanceMode` raw value. -1 = unknown.
    public var whiteBalanceModeRaw: Int
    /// `ProcessInfo.ThermalState` raw value — the closest honest thing to a
    /// device temperature iOS exposes to third-party apps.
    public var thermalStateRaw: Int
    /// Active format description summary: sensor dimensions + max exposure.
    public var formatWidth: Int
    public var formatHeight: Int
    public var formatMaxExposureSeconds: Double
    public var formatSummary: String
    public var rawDelivered: Bool
    public var zslEnabled: Bool
    public var responsiveEnabled: Bool
    /// Measured wall-clock gap since the previous delivered frame.
    public var shotToShotSeconds: Double?
    public var exifExposureSeconds: Double?
    public var exifISO: Double?
    /// Dimensions of the CGImage actually handed to the stacker.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Dump filename when this frame was written to `frames/`, else nil.
    public var dumpFile: String?

    // Session annotations (filled by SessionEngine after the stacker's verdict)
    public var sessionFrameIndex: Int?
    /// "capture" / "focusSweep" / "goto" / "foreground" / "" (unclaimed frame).
    public var sessionPhase: String
    public var starCount: Int?
    public var backgroundLevel: Double?
    public var stackAccepted: Bool?
    public var rejectionReason: String?
    public var matchedStars: Int?
    public var residualPx: Double?

    public init(frameIndex: Int,
                timestamp: Date,
                simulated: Bool = false,
                sensorMeasured: Bool = false,
                requestedExposureSeconds: Double = 0,
                actualExposureSeconds: Double = 0,
                requestedISO: Double = 0,
                actualISO: Double = 0,
                exposureModeRaw: Int = -1,
                focusModeRaw: Int = -1,
                lensPosition: Double = -1,
                whiteBalanceModeRaw: Int = -1,
                thermalStateRaw: Int = 0,
                formatWidth: Int = 0,
                formatHeight: Int = 0,
                formatMaxExposureSeconds: Double = 0,
                formatSummary: String = "",
                rawDelivered: Bool = false,
                zslEnabled: Bool = false,
                responsiveEnabled: Bool = false,
                shotToShotSeconds: Double? = nil,
                exifExposureSeconds: Double? = nil,
                exifISO: Double? = nil,
                pixelWidth: Int = 0,
                pixelHeight: Int = 0,
                dumpFile: String? = nil,
                sessionFrameIndex: Int? = nil,
                sessionPhase: String = "",
                starCount: Int? = nil,
                backgroundLevel: Double? = nil,
                stackAccepted: Bool? = nil,
                rejectionReason: String? = nil,
                matchedStars: Int? = nil,
                residualPx: Double? = nil) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.simulated = simulated
        self.sensorMeasured = sensorMeasured
        self.requestedExposureSeconds = requestedExposureSeconds
        self.actualExposureSeconds = actualExposureSeconds
        self.requestedISO = requestedISO
        self.actualISO = actualISO
        self.exposureModeRaw = exposureModeRaw
        self.focusModeRaw = focusModeRaw
        self.lensPosition = lensPosition
        self.whiteBalanceModeRaw = whiteBalanceModeRaw
        self.thermalStateRaw = thermalStateRaw
        self.formatWidth = formatWidth
        self.formatHeight = formatHeight
        self.formatMaxExposureSeconds = formatMaxExposureSeconds
        self.formatSummary = formatSummary
        self.rawDelivered = rawDelivered
        self.zslEnabled = zslEnabled
        self.responsiveEnabled = responsiveEnabled
        self.shotToShotSeconds = shotToShotSeconds
        self.exifExposureSeconds = exifExposureSeconds
        self.exifISO = exifISO
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dumpFile = dumpFile
        self.sessionFrameIndex = sessionFrameIndex
        self.sessionPhase = sessionPhase
        self.starCount = starCount
        self.backgroundLevel = backgroundLevel
        self.stackAccepted = stackAccepted
        self.rejectionReason = rejectionReason
        self.matchedStars = matchedStars
        self.residualPx = residualPx
    }

    /// The longest exposure the app could actually COMMAND for this frame: the
    /// recipe value, capped at the 1 s third-party limit and again at the active
    /// format's maximum when that is known. Reported so a `honoursRequest: 0`
    /// row can be read as "the lock failed" or "the format never allowed it"
    /// without guessing. 0 when the format max is unknown.
    public var targetExposureSeconds: Double {
        var target = min(requestedExposureSeconds, 1.0)
        if formatMaxExposureSeconds > 0 { target = min(target, formatMaxExposureSeconds) }
        return target
    }

    /// True when the ACTIVE FORMAT cannot reach the requested exposure at all —
    /// the frame was never going to be 1.000 s no matter how well the lock held.
    /// A distinct failure from a lost exposure lock, and reported separately.
    public var exposureClamped: Bool {
        guard requestedExposureSeconds > 0, formatMaxExposureSeconds > 0 else { return false }
        return min(requestedExposureSeconds, 1.0) > formatMaxExposureSeconds + 1e-9
    }

    /// True when the sensor DID deliver the REQUESTED exposure and ISO within a
    /// 20% tolerance. False is the alarm this whole log exists to raise: custom
    /// exposure silently lost and auto-exposure back in charge — or a format
    /// that clamped the request (which is equally not what the recipe asked
    /// for, so it is equally a `false`; `exposureClamped` says which it was).
    ///
    /// The comparison is against the RAW request, never a pre-clamped target: a
    /// value silently reduced before the comparison would forgive exactly the
    /// failure being hunted. When the photo's own EXIF is present it must agree
    /// too — if the live device read-back and the photo disagree, the read-back
    /// is not evidence and this fails closed.
    ///
    /// Simulated rows return `true` because they make no claim either way. Use
    /// `honoursRequestCSV`, not this property, for anything a person reads: it
    /// is EMPTY on every row without a sensor read-back, because a request
    /// compared against a copy of itself is not a passing grade, it is no
    /// evidence at all.
    public var honoursRequest: Bool {
        guard !simulated, requestedExposureSeconds > 0, requestedISO > 0 else { return true }
        let exposureTolerance = max(0.02, requestedExposureSeconds * 0.2)
        let isoTolerance = max(50, requestedISO * 0.2)
        guard abs(actualExposureSeconds - requestedExposureSeconds) <= exposureTolerance
        else { return false }
        if let exifExposureSeconds,
           abs(exifExposureSeconds - requestedExposureSeconds) > exposureTolerance {
            return false
        }
        guard abs(actualISO - requestedISO) <= isoTolerance else { return false }
        if let exifISO, abs(exifISO - requestedISO) > isoTolerance { return false }
        return true
    }

    /// `honoursRequest` as the CSV writes it: "1", "0", or EMPTY when the row
    /// carries no sensor evidence to judge (simulated, or synthesized outside
    /// the capture engine). An analyst filtering for `honoursRequest == 1`
    /// therefore counts only frames a real sensor actually vouched for.
    public var honoursRequestCSV: String {
        guard !simulated, sensorMeasured else { return "" }
        return honoursRequest ? "1" : "0"
    }

    /// True when the focus was locked at capture (`AVCaptureDevice.FocusMode.locked`).
    /// Meaningless on a row that is not sensor-measured, hence the guard.
    public var focusLocked: Bool { sensorMeasured && focusModeRaw == 0 }

    // MARK: CSV

    /// Column contract for a remote analyst:
    ///  - `simulated` 1 → nothing in this row came from a sensor.
    ///  - `sensorMeasured` 1 → the `actual*` and mode columns were read back
    ///    from the live camera for THIS frame. 0 → they are echoes of the
    ///    request and prove nothing.
    ///  - `honoursRequest` is 1/0 only on sensor-measured, non-simulated rows,
    ///    and EMPTY everywhere else — an empty cell is "no evidence", never
    ///    "passed".
    ///  - `targetExposureSeconds` / `exposureClamped` separate "the lock failed"
    ///    from "the active format could never deliver the request".
    public static let csvColumns: [String] = [
        "row", "frameIndex", "timestamp", "epoch", "simulated", "sensorMeasured",
        "requestedExposureSeconds", "actualExposureSeconds",
        "requestedISO", "actualISO", "honoursRequest",
        "targetExposureSeconds", "exposureClamped",
        "exposureMode", "focusMode", "lensPosition", "whiteBalanceMode", "thermalState",
        "formatWidth", "formatHeight", "formatMaxExposureSeconds", "formatSummary",
        "rawDelivered", "zslEnabled", "responsiveEnabled", "shotToShotSeconds",
        "exifExposureSeconds", "exifISO", "pixelWidth", "pixelHeight", "dumpFile",
        "sessionFrameIndex", "sessionPhase", "starCount", "backgroundLevel",
        "stackAccepted", "rejectionReason", "matchedStars", "residualPx",
    ]

    public static var csvHeader: String { csvColumns.joined(separator: ",") + "\n" }

    /// One CSV row. `row` is the 1-based line number within this session's file,
    /// so a pulled `frames.csv` proves for itself that no frame went unlogged.
    public func csvRow(row: Int, timestampText: String) -> String {
        let fields: [String] = [
            "\(row)",
            "\(frameIndex)",
            Self.quoted(timestampText),
            Self.num(timestamp.timeIntervalSince1970, 3),
            simulated ? "1" : "0",
            sensorMeasured ? "1" : "0",
            Self.num(requestedExposureSeconds, 6),
            Self.num(actualExposureSeconds, 6),
            Self.num(requestedISO, 1),
            Self.num(actualISO, 1),
            honoursRequestCSV,
            Self.num(targetExposureSeconds, 6),
            exposureClamped ? "1" : "0",
            "\(exposureModeRaw)",
            "\(focusModeRaw)",
            Self.num(lensPosition, 4),
            "\(whiteBalanceModeRaw)",
            "\(thermalStateRaw)",
            "\(formatWidth)",
            "\(formatHeight)",
            Self.num(formatMaxExposureSeconds, 6),
            Self.quoted(formatSummary),
            rawDelivered ? "1" : "0",
            zslEnabled ? "1" : "0",
            responsiveEnabled ? "1" : "0",
            Self.optionalNum(shotToShotSeconds, 4),
            Self.optionalNum(exifExposureSeconds, 6),
            Self.optionalNum(exifISO, 1),
            "\(pixelWidth)",
            "\(pixelHeight)",
            Self.quoted(dumpFile ?? ""),
            sessionFrameIndex.map { "\($0)" } ?? "",
            Self.quoted(sessionPhase),
            starCount.map { "\($0)" } ?? "",
            Self.optionalNum(backgroundLevel, 5),
            stackAccepted.map { $0 ? "1" : "0" } ?? "",
            Self.quoted(rejectionReason ?? ""),
            matchedStars.map { "\($0)" } ?? "",
            Self.optionalNum(residualPx, 3),
        ]
        return fields.joined(separator: ",") + "\n"
    }

    /// The same facts as JSON-ready values, for `frames/index.json`.
    public func indexFields(timestampText: String) -> [String: Any] {
        var dict: [String: Any] = [
            "frameIndex": frameIndex,
            "timestamp": timestampText,
            "epoch": timestamp.timeIntervalSince1970,
            "simulated": simulated,
            "sensorMeasured": sensorMeasured,
            "requestedExposureSeconds": requestedExposureSeconds,
            "actualExposureSeconds": actualExposureSeconds,
            "requestedISO": requestedISO,
            "actualISO": actualISO,
            // Mirrors the CSV exactly: a string, empty when there is no sensor
            // evidence to judge. Never a bare `true` on synthetic numbers.
            "honoursRequest": honoursRequestCSV,
            "targetExposureSeconds": targetExposureSeconds,
            "exposureClamped": exposureClamped,
            "focusLocked": focusLocked,
            "exposureMode": exposureModeRaw,
            "focusMode": focusModeRaw,
            "lensPosition": lensPosition,
            "whiteBalanceMode": whiteBalanceModeRaw,
            "thermalState": thermalStateRaw,
            "formatSummary": formatSummary,
            "formatWidth": formatWidth,
            "formatHeight": formatHeight,
            "formatMaxExposureSeconds": formatMaxExposureSeconds,
            "rawDelivered": rawDelivered,
            "zslEnabled": zslEnabled,
            "responsiveEnabled": responsiveEnabled,
            "pixelWidth": pixelWidth,
            "pixelHeight": pixelHeight,
            "sessionPhase": sessionPhase,
        ]
        if let dumpFile { dict["file"] = dumpFile }
        if let shotToShotSeconds { dict["shotToShotSeconds"] = shotToShotSeconds }
        if let exifExposureSeconds { dict["exifExposureSeconds"] = exifExposureSeconds }
        if let exifISO { dict["exifISO"] = exifISO }
        if let sessionFrameIndex { dict["sessionFrameIndex"] = sessionFrameIndex }
        if let starCount { dict["starCount"] = starCount }
        if let backgroundLevel { dict["backgroundLevel"] = backgroundLevel }
        if let stackAccepted { dict["stackAccepted"] = stackAccepted }
        if let rejectionReason { dict["rejectionReason"] = rejectionReason }
        if let matchedStars { dict["matchedStars"] = matchedStars }
        if let residualPx { dict["residualPx"] = residualPx }
        return dict
    }

    // MARK: Formatting helpers

    static func num(_ value: Double, _ places: Int) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.\(places)f", value)
    }

    static func optionalNum(_ value: Double?, _ places: Int) -> String {
        guard let value else { return "" }
        return num(value, places)
    }

    /// CSV-safe: always quoted, embedded quotes doubled, newlines flattened.
    static func quoted(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(flat)\""
    }
}

// MARK: - FrameTruthWriter (all I/O, off the main actor)

/// Serial-queue file writer for the truth log. Every byte of I/O — CSV append,
/// JPEG encode, prune, index rewrite — happens here at utility QoS, so the
/// capture hot path only ever pays for a struct copy and a queue hop.
///
/// Ordering is guaranteed by the single serial queue: a frame's JPEG is on disk
/// before its index entry, and rows land in delivery order.
public final class FrameTruthWriter: @unchecked Sendable {

    /// Dumped-file bookkeeping (queue-confined).
    private struct DumpRecord {
        let name: String
        let frameIndex: Int
        var fields: [String: Any]
    }

    private let queue = DispatchQueue(label: "com.chinmay.starflow.frametruth", qos: .utility)
    private let csvURL: URL
    private let framesDirectory: URL
    private let indexURL: URL
    private let maxDumpedFiles: Int

    // Queue-confined state.
    private var handle: FileHandle?
    private var rows = 0
    private var records: [DumpRecord] = []

    /// Only touched on `queue`.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(csvURL: URL = FrameEvidence.csvURL,
                framesDirectory: URL = FrameEvidence.framesDirectory,
                indexURL: URL = FrameEvidence.indexURL,
                maxDumpedFiles: Int = FrameEvidence.maxDumpedFiles) {
        self.csvURL = csvURL
        self.framesDirectory = framesDirectory
        self.indexURL = indexURL
        self.maxDumpedFiles = max(1, maxDumpedFiles)
    }

    /// Fresh evidence for a new session: recreate `frames.csv` with its single
    /// header line and empty the dump directory. Calling it twice back-to-back
    /// (session start, then capture start) is harmless — nothing is written in
    /// between.
    func beginSession() {
        queue.async { [self] in
            try? handle?.close()
            handle = nil
            rows = 0
            records = []
            let fm = FileManager.default
            try? fm.createDirectory(at: csvURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.removeItem(at: framesDirectory)
            try? fm.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
            try? fm.removeItem(at: csvURL)
            _ = fm.createFile(atPath: csvURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: csvURL)
            write(FrameTruth.csvHeader)
            writeIndex()
        }
    }

    /// Append one finished row (camera truth + whatever the session annotated).
    func append(_ truth: FrameTruth) {
        queue.async { [self] in
            rows += 1
            let stamp = Self.timestampFormatter.string(from: truth.timestamp)
            write(truth.csvRow(row: rows, timestampText: stamp))
            // Keep the dump index in step with the final (annotated) row.
            if let name = truth.dumpFile,
               let slot = records.firstIndex(where: { $0.name == name }) {
                records[slot].fields = truth.indexFields(timestampText: stamp)
                writeIndex()
            }
        }
    }

    /// Encode + persist one frame dump, prune to the cap, refresh the index.
    /// `alsoFirst` additionally writes `frames/first.jpg`, which is exempt from
    /// the cap: the very first frame of the night is always kept.
    func dump(image: CGImage, truth: FrameTruth, name: String, alsoFirst: Bool) {
        queue.async { [self] in
            guard let scaled = Self.downscaled(image, maxSide: FrameEvidence.dumpMaxSide)
            else { return }
            try? FileManager.default.createDirectory(at: framesDirectory,
                                                    withIntermediateDirectories: true)
            let url = framesDirectory.appendingPathComponent(name)
            guard TimelapseFrameStore.writeJPEG(scaled, to: url,
                                                quality: FrameEvidence.dumpQuality) else { return }
            if alsoFirst {
                _ = TimelapseFrameStore.writeJPEG(
                    scaled, to: framesDirectory.appendingPathComponent(FrameEvidence.firstFrameName),
                    quality: FrameEvidence.dumpQuality)
            }
            let stamp = Self.timestampFormatter.string(from: truth.timestamp)
            records.removeAll { $0.name == name }
            records.append(DumpRecord(name: name, frameIndex: truth.frameIndex,
                                      fields: truth.indexFields(timestampText: stamp)))
            while records.count > maxDumpedFiles {
                let oldest = records.removeFirst()
                try? FileManager.default.removeItem(
                    at: framesDirectory.appendingPathComponent(oldest.name))
            }
            writeIndex()
        }
    }

    /// Block until every queued write has landed. Tests only — the app never
    /// waits on the writer.
    func drainForTesting() {
        queue.sync { }
    }

    /// Flush the file handle and rewrite the index (end of session).
    func finish() {
        queue.async { [self] in
            writeIndex()
            try? handle?.synchronize()
        }
    }

    // MARK: Queue-confined internals

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if handle == nil {
            let fm = FileManager.default
            if !fm.fileExists(atPath: csvURL.path) {
                try? fm.createDirectory(at: csvURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                _ = fm.createFile(atPath: csvURL.path,
                                  contents: FrameTruth.csvHeader.data(using: .utf8))
            }
            handle = try? FileHandle(forWritingTo: csvURL)
        }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            // fsync per row: the harness pulls this file mid-session and must
            // never read a torn tail.
            try handle.synchronize()
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func writeIndex() {
        let payload: [String: Any] = [
            "generatedAt": Self.timestampFormatter.string(from: Date()),
            "rows": rows,
            "maxDumpedFiles": maxDumpedFiles,
            "firstFrame": FrameEvidence.firstFrameName,
            "frames": records.map { $0.fields },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(at: framesDirectory,
                                                withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Aspect-preserving downscale for the dump (never upscales).
    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard image.width > 0, image.height > 0 else { return nil }
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

// MARK: - FrameTruthLog

/// The per-frame evidence ledger: one CSV row per delivered frame, plus bounded
/// JPEG frame dumps, written to `Documents/autotest/` for the USB harness.
///
/// Two producers, one row:
///  - `CaptureEngine` STAGES the camera truth the instant a frame is delivered.
///  - `SessionEngine` ANNOTATES the same row (matched by frame timestamp) with
///    the stacker's star count and accept/reject verdict, which flushes it.
/// A staged row that is never annotated (probe frames, or a session that raced
/// ahead) is flushed unannotated as soon as the buffer moves past it, so the
/// file has exactly one row per delivered frame and no gaps.
///
/// Cost on the main actor: a struct copy, an array append, and a queue hop.
/// Downscaling, JPEG encoding, pruning and every write happen on the writer's
/// utility-QoS serial queue.
@MainActor
public final class FrameTruthLog {

    public static let shared = FrameTruthLog()

    /// UserDefaults keys: dump cadence, and a hard on/off for the whole ledger.
    public static let dumpEveryNDefaultsKey = "frameDumpEveryN"
    public static let enabledDefaultsKey = "frameTruthLogging"

    /// Frames staged but not yet flushed. Bounded — the buffer only exists so a
    /// capture that races ahead of the stacker still gets its verdict.
    private static let pendingLimit = 12

    /// Dump cadence. 0 or negative disables dumping (the CSV keeps going).
    public var dumpEveryN: Int
    /// Master switch. Off inside unit tests by default so CI never pays for
    /// per-frame disk I/O; a test (or the harness) can turn it on explicitly.
    public var isEnabled: Bool

    /// Counters for the harness reports. Deliberately plain properties, not
    /// `@Published`: nothing observes them, and an `objectWillChange` per frame
    /// would be main-actor work the capture loop should never pay for.
    public private(set) var rowsWritten = 0
    public private(set) var dumpsWritten = 0
    /// The most recent row handed to the writer — the report's "last frame" view.
    public private(set) var lastRow: FrameTruth?

    private let writer: FrameTruthWriter
    private var pending: [FrameTruth] = []
    /// Monotonic counter used as the frame index for rows the capture engine
    /// did not stage (simulator frames, injected test hooks).
    private var stagedCount = 0
    /// Timestamp of the newest row ever staged this session. Frames arrive in
    /// delivery order, so anything at or before it is already logged — the guard
    /// that keeps `stageIfNeeded` from duplicating a row that has been flushed
    /// out of `pending`.
    private var lastStagedTimestamp: Date?

    public init(writer: FrameTruthWriter = FrameTruthWriter()) {
        self.writer = writer
        let stored = FrameEvidence.sanitizedDumpEveryN(
            UserDefaults.standard.integer(forKey: FrameTruthLog.dumpEveryNDefaultsKey))
        self.dumpEveryN = stored > 0 ? stored : FrameEvidence.defaultDumpEveryN
        if let override = UserDefaults.standard.object(forKey: FrameTruthLog.enabledDefaultsKey) as? Bool {
            self.isEnabled = override
        } else {
            self.isEnabled = !FrameTruthLog.isRunningUnitTests
        }
    }

    /// XCTest sets this environment variable; unit tests must not write a frame
    /// ledger for every synthetic frame they push through the engine.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    // MARK: Session lifecycle

    /// Start a fresh ledger (truncates `frames.csv`, empties `frames/`).
    /// Safe to call twice before the first frame — the session engine calls it
    /// when a session starts and the capture engine when the camera comes up.
    public func beginSession() {
        guard isEnabled else { return }
        pending = []
        stagedCount = 0
        lastStagedTimestamp = nil
        rowsWritten = 0
        dumpsWritten = 0
        lastRow = nil
        let stored = FrameEvidence.sanitizedDumpEveryN(
            UserDefaults.standard.integer(forKey: FrameTruthLog.dumpEveryNDefaultsKey))
        if stored > 0 { dumpEveryN = stored }
        writer.beginSession()
    }

    /// Flush every staged row and close the ledger for this session.
    public func endSession() {
        guard isEnabled else { return }
        flushPending()
        writer.finish()
    }

    // MARK: Staging + annotation

    /// Record what the camera actually did for one delivered frame. The dump
    /// decision is made here (so the JPEG encode starts immediately, off-actor);
    /// the CSV row waits for the session's verdict.
    public func stage(_ truth: FrameTruth, image: CGImage?) {
        guard isEnabled else { return }
        var truth = truth
        stagedCount += 1
        if let last = lastStagedTimestamp {
            lastStagedTimestamp = max(last, truth.timestamp)
        } else {
            lastStagedTimestamp = truth.timestamp
        }
        if let image, shouldDump(frameIndex: truth.frameIndex) {
            let name = FrameEvidence.dumpName(frameIndex: truth.frameIndex)
            truth.dumpFile = name
            dumpsWritten += 1
            writer.dump(image: image, truth: truth, name: name,
                        alsoFirst: dumpsWritten == 1)
        }
        pending.append(truth)
        while pending.count > FrameTruthLog.pendingLimit { flushFirst() }
    }

    /// Stage a synthesized row when nothing has staged this frame — the
    /// simulator path (no `CaptureEngine` in the loop) and injected test hooks.
    ///
    /// Every value here is an ECHO of what the app asked for, not a sensor
    /// read-back, so the row is stamped `sensorMeasured: false` and carries no
    /// invented format facts. On device the capture engine has already staged
    /// the real thing; this call then does nothing (matched by timestamp, or by
    /// the monotonic guard once that row has been flushed to disk), so a frame
    /// can never end up with two rows — one real, one synthesized.
    public func stageIfNeeded(frame: SubFrame, recipe: CaptureRecipe, simulated: Bool) {
        guard isEnabled else { return }
        guard !pending.contains(where: { $0.timestamp == frame.timestamp }) else { return }
        // Already staged AND flushed: staging again would duplicate the frame and
        // overwrite real camera truth with an echo of the request.
        if let lastStagedTimestamp, frame.timestamp <= lastStagedTimestamp { return }
        let image = frame.pixelData
        let truth = FrameTruth(
            frameIndex: stagedCount,
            timestamp: frame.timestamp,
            simulated: simulated,
            sensorMeasured: false,
            requestedExposureSeconds: recipe.exposureSeconds,
            actualExposureSeconds: frame.exposureSeconds,
            requestedISO: recipe.iso,
            actualISO: frame.iso,
            thermalStateRaw: ProcessInfo.processInfo.thermalState.rawValue,
            formatWidth: image?.width ?? 0,
            formatHeight: image?.height ?? 0,
            // No device was consulted — leave the format max UNKNOWN (0) rather
            // than asserting the 1 s cap this row cannot vouch for.
            formatMaxExposureSeconds: 0,
            formatSummary: simulated
                ? "SIMULATED starfield \(image?.width ?? 0)x\(image?.height ?? 0) "
                    + "(no sensor was involved)"
                : "no device format read — values echo the request, not the sensor",
            // Gap since the PREVIOUS staged frame. Measured against
            // `lastStagedTimestamp`, not `pending.last`: the capture loop
            // annotates (and therefore flushes) each frame before the next one
            // is staged, so `pending` is empty here in steady state and this
            // column would otherwise be blank on every simulator/probe row.
            shotToShotSeconds: lastStagedTimestamp.map {
                frame.timestamp.timeIntervalSince($0)
            },
            pixelWidth: image?.width ?? 0,
            pixelHeight: image?.height ?? 0)
        stage(truth, image: image)
    }

    /// Attach the stacker's verdict for the frame delivered at `timestamp`, then
    /// flush it (and anything staged before it, in order). A timestamp that is
    /// no longer buffered is ignored — that row is already on disk.
    public func annotate(timestamp: Date,
                         sessionFrameIndex: Int? = nil,
                         phase: String = "capture",
                         starCount: Int? = nil,
                         backgroundLevel: Double? = nil,
                         accepted: Bool? = nil,
                         rejectionReason: String? = nil,
                         matchedStars: Int? = nil,
                         residualPx: Double? = nil) {
        guard isEnabled else { return }
        guard let slot = pending.firstIndex(where: { $0.timestamp == timestamp }) else { return }
        pending[slot].sessionFrameIndex = sessionFrameIndex
        pending[slot].sessionPhase = phase
        pending[slot].starCount = starCount
        pending[slot].backgroundLevel = backgroundLevel
        pending[slot].stackAccepted = accepted
        pending[slot].rejectionReason = rejectionReason
        pending[slot].matchedStars = matchedStars
        pending[slot].residualPx = residualPx
        for _ in 0...slot { flushFirst() }
    }

    /// Write every staged row out as-is.
    public func flushPending() {
        guard isEnabled else { return }
        while !pending.isEmpty { flushFirst() }
    }

    // MARK: Internals

    /// A frame is dumped when it is one of the first
    /// `FrameEvidence.alwaysDumpFirstFrames`, or lands on the configured cadence.
    func shouldDump(frameIndex: Int) -> Bool {
        FrameEvidence.shouldDump(frameIndex: frameIndex, everyN: dumpEveryN)
    }

    private func flushFirst() {
        guard !pending.isEmpty else { return }
        let row = pending.removeFirst()
        rowsWritten += 1
        lastRow = row
        writer.append(row)
    }
}
