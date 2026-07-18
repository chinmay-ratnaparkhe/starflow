import Foundation
import CoreGraphics

// MARK: - Capture intelligence (pure math, no AVFoundation, no I/O)
//
// Three deterministic helpers for the Capture module, all unit-tested in
// Tests/ExposurePlannerTests.swift:
//  - ExposurePlanner: adapts a mode's base recipe to the user's sky quality.
//  - FocusMetric + RollingSharpness: variance-of-Laplacian star-focus telemetry.
//  - StorageBudget: bytes-per-frame estimates and the session storage pre-flight.

// MARK: - ExposurePlanner

/// Chooses ISO/exposure for a shot from the mode's base recipe + the user's sky quality.
///
/// Ground rules (bench + field truths):
///  - 1 s is the hard third-party exposure cap. The planner never trades shutter time,
///    only gain — "more light" always means more subs, never a longer frame.
///  - City (Bortle 8–9): skyglow already pushes the histogram right, so expose-right
///    at LOW gain — keep the full shutter and cut ISO (never above 800) so the glow
///    doesn't clip and stars stay separable from the orange wash.
///  - Dark site (Bortle 1–2): sky-noise-limited recipes ride at ISO 3200+ so faint
///    signal swamps read noise; stacking averages the extra shot noise back down.
///  - Target-lit shots (Moon, city lights — base ISO ≤ 200) don't care about sky
///    quality: their subject provides the photons. They pass through unchanged.
public enum ExposurePlanner {

    public struct Plan: Equatable, Sendable {
        public var exposureSeconds: Double
        public var iso: Double
        /// One-line rationale for the session UI ("why these numbers").
        public var note: String
        public init(exposureSeconds: Double, iso: Double, note: String) {
            self.exposureSeconds = exposureSeconds; self.iso = iso; self.note = note
        }
    }

    /// ISO clamps. The camera clamps again to the active format's range at lock time;
    /// these keep the plan inside the range that actually makes astro sense.
    public static let isoFloor: Double = 100
    public static let isoCeiling: Double = 6400
    /// Expose-right ceiling under city skyglow.
    public static let cityISOCeiling: Double = 800
    /// Base ISO at/below which a recipe is target-lit (Moon, skyline) — quality-blind.
    public static let brightTargetISOThreshold: Double = 200
    /// Base ISO at/above which a recipe counts as sky-noise-limited and picks up the
    /// dark-site floor below.
    public static let dimSkyBaseISO: Double = 1600
    /// Dark sites run dim-sky recipes at ISO 3200+ (read noise must not dominate).
    public static let darkSiteISOFloor: Double = 3200

    /// Pure planning: base recipe + sky quality → exposure/ISO + rationale.
    public static func plan(base: CaptureRecipe, quality: SkyQuality) -> Plan {
        let exposure = min(base.exposureSeconds, 1.0)   // hard third-party cap
        if base.iso <= brightTargetISOThreshold {
            return Plan(exposureSeconds: exposure, iso: base.iso,
                        note: "Target-lit shot — sky brightness doesn't change the recipe.")
        }
        var iso = base.iso * isoScale(for: quality)
        if quality == .dark, base.iso >= dimSkyBaseISO {
            iso = max(iso, darkSiteISOFloor)
        }
        if quality == .city {
            iso = min(iso, cityISOCeiling)
        }
        iso = min(max(iso, isoFloor), isoCeiling)
        return Plan(exposureSeconds: exposure, iso: iso, note: note(for: quality))
    }

    /// Convenience: the base recipe with the planned exposure/ISO swapped in
    /// (sub count, tracking, and cadence are untouched).
    public static func adjustedRecipe(base: CaptureRecipe, quality: SkyQuality) -> CaptureRecipe {
        let p = plan(base: base, quality: quality)
        return CaptureRecipe(exposureSeconds: p.exposureSeconds, iso: p.iso,
                             targetSubCount: base.targetSubCount,
                             nudgeTracking: base.nudgeTracking,
                             intervalSeconds: base.intervalSeconds)
    }

    // MARK: Mid-session refinement (MEASURED sky background)

    /// Measured sky background (0…1, sigma-clipped mean from `SkyConditionMonitor`
    /// observations) at/above which the plan trades one stop of gain away.
    /// Deliberately below the monitor's 0.30 "overexposed" verdict so tuning
    /// happens while the session is still worth saving.
    public static let refineBackgroundHigh: Double = 0.20
    /// Measured background at/below which the sky is darker than any plan
    /// assumed and one stop of extra gain buys real depth.
    public static let refineBackgroundLow: Double = 0.02

    /// One mid-session ISO adjustment from the MEASURED sky background — the sky
    /// as the sensor actually sees it, not the user's Bortle guess. Pure and
    /// deterministic; the session engine enforces "at most once per session".
    ///
    /// Returns nil when the plan should stand: background in the healthy band,
    /// a target-lit recipe (its subject provides the photons), or an adjustment
    /// the ISO clamps would cancel anyway. Never touches the shutter — 1 s is
    /// the hard cap and "more light" still means more subs, never longer frames.
    public static func refine(measuredBackground: Double, current: Plan) -> Plan? {
        guard current.iso > brightTargetISOThreshold else { return nil }
        let iso: Double
        let reason: String
        if measuredBackground >= refineBackgroundHigh {
            iso = max(current.iso / 2, isoFloor)
            reason = "background near saturation"
        } else if measuredBackground <= refineBackgroundLow {
            iso = min(current.iso * 2, isoCeiling)
            reason = "sky darker than planned"
        } else {
            return nil
        }
        guard iso != current.iso else { return nil }
        return Plan(exposureSeconds: current.exposureSeconds, iso: iso,
                    note: "Sky measured — \(reason), tuning to ISO \(Int(iso)).")
    }

    private static func isoScale(for quality: SkyQuality) -> Double {
        switch quality {
        case .city: return 0.25
        case .suburb: return 0.5
        case .rural: return 1.0
        case .dark: return 2.0
        }
    }

    private static func note(for quality: SkyQuality) -> String {
        switch quality {
        case .city: return "City skyglow: exposing right at low gain so the glow doesn't clip."
        case .suburb: return "Suburban glow: gain halved to protect the highlights."
        case .rural: return "Rural sky: the mode's native recipe."
        case .dark: return "Dark site: high gain so faint sky signal swamps read noise."
        }
    }
}

// MARK: - FocusMetric (star-focus sharpness)

/// Variance-of-Laplacian sharpness: in-focus stars are near-delta spikes with huge
/// second derivatives; defocused stars are smooth blobs. The metric is relative —
/// track it across frames (see `RollingSharpness`) rather than reading it absolutely.
public enum FocusMetric {

    /// Preview width the CGImage convenience downsamples to. Small on purpose:
    /// ~12k pixels keeps the metric far under a millisecond of math.
    public static let defaultSampleWidth = 128

    /// Variance of the 4-neighbour Laplacian (4·v − up − down − left − right) over the
    /// interior of a row-major luminance buffer (values 0…1). Pure and deterministic.
    /// Returns 0 for degenerate input (mismatched buffer, dimensions < 3).
    public static func laplacianVariance(_ buffer: [Float], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, buffer.count == width * height else { return 0 }
        var sum = 0.0
        var sumSq = 0.0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let lap = 4 * Double(buffer[i])
                    - Double(buffer[i - 1]) - Double(buffer[i + 1])
                    - Double(buffer[i - width]) - Double(buffer[i + width])
                sum += lap
                sumSq += lap * lap
            }
        }
        let n = Double((width - 2) * (height - 2))
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    /// Sharpness of a captured frame: downscale to a small grayscale preview
    /// (aspect preserved) and take the Laplacian variance of that preview.
    public static func sharpness(of image: CGImage,
                                 sampleWidth: Int = defaultSampleWidth) -> Double? {
        guard image.width > 0, image.height > 0 else { return nil }
        let w = max(3, min(sampleWidth, image.width))
        let h = max(3, Int((Double(w) * Double(image.height) / Double(image.width)).rounded()))
        guard let gray = CPUStacker.grayscaleFloats(from: image, width: w, height: h) else {
            return nil
        }
        return laplacianVariance(gray, width: w, height: h)
    }
}

/// Rolling window over per-frame sharpness samples. The interesting signal is the
/// newest frame falling well below the recent mean — focus creep, dew on the lens,
/// or a bumped focus ring.
public struct RollingSharpness: Sendable {
    public let window: Int
    private var samples: [Double] = []

    public init(window: Int = 10) {
        self.window = max(1, window)
    }

    public mutating func record(_ value: Double) {
        samples.append(value)
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    public mutating func reset() {
        samples.removeAll()
    }

    public var count: Int { samples.count }
    public var latest: Double? { samples.last }
    public var mean: Double? {
        samples.isEmpty ? nil : samples.reduce(0, +) / Double(samples.count)
    }

    /// True when the newest sample sits `fraction` (default 30%) below the rolling
    /// mean — the "did focus drift?" alarm. Needs ≥ 3 samples to have an opinion.
    public func isDegraded(by fraction: Double = 0.3) -> Bool {
        guard count >= 3, let latest, let mean, mean > 0 else { return false }
        return latest < mean * (1 - fraction)
    }
}

// MARK: - StorageBudget (session storage pre-flight)

/// Estimates what a capture plan will write and judges it against free disk space.
/// The verdict runs BEFORE the first frame (refuse/warn up front); the session
/// engine's in-flight guardian still watches the hard floor during capture.
public enum StorageBudget {

    public enum Verdict: Equatable, Sendable {
        case ok
        case warn      // fits, but with thin headroom — tell the user
        case refuse    // would run into the reserve mid-session — don't start
    }

    /// Per-frame file sizes for persisted subs (main camera, 1 s night subs):
    /// processed HEVC ≈ 4.5 MB, 12 MP Bayer RAW DNG ≈ 26 MB.
    public static let hevcBytesPerFrame: Int64 = 4_500_000
    public static let bayerRawBytesPerFrame: Int64 = 26_000_000
    /// Working footprint per sub when subs are NOT persisted (previews, logs).
    public static let transientBytesPerFrame: Int64 = 100_000
    /// Session-level overhead: final stack, share card, safety margin.
    public static let sessionOverheadBytes: Int64 = 250_000_000
    /// Never plan into the last GB — the in-flight guardian stops there anyway.
    public static let hardReserveBytes: Int64 = 1_000_000_000
    /// Warn when free space is under planned × this factor + the reserve.
    public static let warnHeadroomFactor: Double = 1.25

    /// Bytes each captured sub will cost on disk. "Keep RAW subs" (Settings) persists
    /// the Bayer RAW + processed pair; otherwise subs live only in the in-memory stack.
    public static func estimatedBytesPerFrame(recipe: CaptureRecipe, keepingSubs: Bool) -> Int64 {
        keepingSubs ? hevcBytesPerFrame + bayerRawBytesPerFrame : transientBytesPerFrame
    }

    /// Total bytes the session plan is expected to write.
    public static func plannedSessionBytes(recipe: CaptureRecipe, bytesPerFrame: Int64) -> Int64 {
        sessionOverheadBytes + Int64(max(0, recipe.targetSubCount)) * max(0, bytesPerFrame)
    }

    public static func plannedSessionBytes(recipe: CaptureRecipe, keepingSubs: Bool) -> Int64 {
        plannedSessionBytes(recipe: recipe,
                            bytesPerFrame: estimatedBytesPerFrame(recipe: recipe,
                                                                  keepingSubs: keepingSubs))
    }

    /// The pre-flight judgement. Unknown free space is `.ok` — we can't refuse on a
    /// guess, and the in-flight guardian still protects the floor.
    public static func verdict(freeBytes: Int64?, plannedBytes: Int64) -> Verdict {
        guard let free = freeBytes else { return .ok }
        if free < plannedBytes + hardReserveBytes { return .refuse }
        if Double(free) < Double(plannedBytes) * warnHeadroomFactor + Double(hardReserveBytes) {
            return .warn
        }
        return .ok
    }

    /// Free space on the volume that will hold session output.
    public static func systemFreeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Human-readable byte count for status copy ("needs about 18.2 GB").
    public static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
