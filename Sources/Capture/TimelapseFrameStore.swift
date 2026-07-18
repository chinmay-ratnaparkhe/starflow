import Foundation
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - TimelapseFramePolicy (pure math, unit-tested)
//
// The bounds that keep timelapse frame retention honest about memory and disk:
// frames are downscaled to a 1080p-class ceiling, capped in count, estimated
// into the session's storage pre-flight, and abandoned gracefully (never
// fatally) when free space runs thin. No I/O here — `TimelapseFrameStore`
// below does the writing; the session engine does the narrating.

public enum TimelapseFramePolicy {

    /// Hard cap on retained frames per session. 900 frames is 37.5 s of clip at
    /// 24 fps — beyond that the working set (~1 GB of JPEGs) stops being honest
    /// about a phone's disk, and capture itself keeps running regardless.
    public static let maxFrames = 900

    /// 1080p-class ceiling: the longest image side after downscale.
    public static let maxDimension = 1920

    /// Storage estimate per retained frame: a 1080p-class night JPEG at 0.85
    /// quality measures in the hundreds of KB; 1.2 MB is the honest upper bound
    /// the pre-flight plans with.
    public static let estimatedBytesPerFrame: Int64 = 1_200_000

    /// Storage estimate for the assembled .mp4 itself (≤ 37.5 s of 1080p video).
    public static let assembledVideoBytes: Int64 = 60_000_000

    /// Stop retaining NEW frames below this much free disk — deliberately above
    /// the session engine's 1 GB hard stop, so the timelapse degrades (shorter
    /// clip) before the whole session does.
    public static let retentionFloorBytes: Int64 = 1_200_000_000

    /// User-selectable playback rates (mode detail sheet) and their default.
    public static let allowedFPS: [Int] = [24, 30]
    public static let defaultFPS = 24
    /// UserDefaults key backing the 24/30 fps choice.
    public static let fpsDefaultsKey = "timelapseFPS"

    /// Frames a plan will actually retain: the planned sub count under the cap.
    public static func retainedFrameCount(planned: Int) -> Int {
        max(0, min(planned, maxFrames))
    }

    /// True while one more frame may be retained. Unknown free space retains —
    /// the pre-flight already vetted the plan, and the engine's in-flight
    /// guardian still owns the hard floor.
    public static func shouldRetain(retainedCount: Int, freeDiskBytes: Int64?) -> Bool {
        guard retainedCount < maxFrames else { return false }
        if let free = freeDiskBytes, free < retentionFloorBytes { return false }
        return true
    }

    /// Aspect-preserving downscale to the 1080p-class ceiling. Never upscales;
    /// degenerate input collapses to (0, 0) so callers can refuse it.
    public static func scaledSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let longSide = max(width, height)
        guard longSide > maxDimension else { return (width, height) }
        let scale = Double(maxDimension) / Double(longSide)
        return (width: max(1, Int((Double(width) * scale).rounded())),
                height: max(1, Int((Double(height) * scale).rounded())))
    }

    /// Bytes the storage pre-flight should plan for a timelapse session's
    /// retained frames plus the assembled clip.
    public static func plannedBytes(frameCount: Int) -> Int64 {
        Int64(retainedFrameCount(planned: frameCount)) * estimatedBytesPerFrame
            + assembledVideoBytes
    }

    /// Clamp a stored fps choice to the allowed set (unset/garbage → default).
    public static func sanitizedFPS(_ raw: Int) -> Int {
        allowedFPS.contains(raw) ? raw : defaultFPS
    }

    /// Clip length a frame count plays back as.
    public static func clipSeconds(frames: Int, fps: Int) -> Double {
        guard fps > 0 else { return 0 }
        return Double(max(0, frames)) / Double(fps)
    }

    /// The user's 24/30 fps choice from Settings-backed storage.
    public static func userFPS(defaults: UserDefaults = .standard) -> Int {
        sanitizedFPS(defaults.integer(forKey: fpsDefaultsKey))
    }
}

// MARK: - TimelapseLibrary (where finished clips live)

/// `Documents/Timelapses/` — the assembled .mp4s, visible in the Files app
/// (UIFileSharingEnabled) and addressed by filename from `SessionRecord`.
public enum TimelapseLibrary {

    public static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Timelapses", isDirectory: true)
    }

    public static func url(forFilename name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    /// True when a record's clip file is actually still on disk — the honest
    /// gate before the UI offers a Play button.
    public static func videoExists(filename: String?) -> Bool {
        guard let filename, !filename.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: url(forFilename: filename).path)
    }
}

// MARK: - TimelapseFrameStore (bounded on-disk frame retention)

/// Retains per-sub frames for the timelapse export as downscaled JPEGs in a
/// session-scoped temp directory. Disk-backed on purpose: 900 × 1080p frames
/// held as CGImages would be several GB of RAM — file-backed retention keeps
/// the session's memory profile identical to every other mode. All I/O is
/// best-effort (a failed write drops one frame from the clip, never the
/// session) and ImageIO-only, so the whole path runs on the simulator.
public final class TimelapseFrameStore {

    public private(set) var frameURLs: [URL] = []
    public var count: Int { frameURLs.count }

    public let directory: URL
    private var directoryCreated = false

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("starflow-timelapse-frames-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    /// Downscale + persist one frame. Returns false (and retains nothing) on
    /// any failure or once the frame cap is reached.
    @discardableResult
    public func append(_ image: CGImage) -> Bool {
        guard count < TimelapseFramePolicy.maxFrames else { return false }
        guard let scaled = Self.downscaledForRetention(image) else { return false }
        if !directoryCreated {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            directoryCreated = true
        }
        let url = directory.appendingPathComponent(String(format: "frame-%06d.jpg", count))
        guard Self.writeJPEG(scaled, to: url) else { return false }
        frameURLs.append(url)
        return true
    }

    /// Delete every retained frame and the session directory (idempotent).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        frameURLs = []
        directoryCreated = false
    }

    // MARK: Internals (static, testable)

    /// Apply the policy downscale; pass-through when already inside the ceiling.
    static func downscaledForRetention(_ image: CGImage) -> CGImage? {
        let target = TimelapseFramePolicy.scaledSize(width: image.width, height: image.height)
        guard target.width > 0, target.height > 0 else { return nil }
        if target.width == image.width, target.height == image.height { return image }
        guard let ctx = CGContext(data: nil, width: target.width, height: target.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return ctx.makeImage()
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) -> Bool {
        #if canImport(UniformTypeIdentifiers)
        let jpegType = UTType.jpeg.identifier as CFString
        #else
        let jpegType = "public.jpeg" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, jpegType, 1, nil)
        else { return false }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination)
    }
}
