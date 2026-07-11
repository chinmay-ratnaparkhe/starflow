import Foundation
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - SessionRecord

/// One finished (or gracefully ended) session, as it lands in the logbook.
/// Codable JSON on disk; the preview thumbnail lives beside it as a small PNG.
public struct SessionRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date                    // session start (falls back to save time)
    public var shotID: String
    public var shotName: String
    public var integrationSeconds: Double
    public var subsAccepted: Int
    public var subsRejected: Int
    public var nudges: Int
    public var flapsRecovered: Int
    public var targetSubCount: Int

    public init(id: UUID, date: Date, shotID: String, shotName: String,
                integrationSeconds: Double, subsAccepted: Int, subsRejected: Int,
                nudges: Int, flapsRecovered: Int, targetSubCount: Int) {
        self.id = id; self.date = date; self.shotID = shotID; self.shotName = shotName
        self.integrationSeconds = integrationSeconds
        self.subsAccepted = subsAccepted; self.subsRejected = subsRejected
        self.nudges = nudges; self.flapsRecovered = flapsRecovered
        self.targetSubCount = targetSubCount
    }

    /// True when the session stopped before reaching its planned sub count
    /// (guardian stop, user stop, battery floor — the diverted-flight case).
    public var endedEarly: Bool {
        subsAccepted + subsRejected < targetSubCount
    }
}

// MARK: - SessionStore

/// The logbook's persistence layer: Codable `SessionRecord`s in
/// `Documents/Sessions/` (`<uuid>.json` + optional `<uuid>.png` thumbnail).
/// Newest-first in `records`; all file I/O is best-effort and never throws
/// into the UI.
@MainActor
public final class SessionStore: ObservableObject {

    public static let shared = SessionStore()

    @Published public private(set) var records: [SessionRecord] = []

    private var thumbnailCache: [UUID: CGImage] = [:]

    public init() {
        reload()
    }

    // MARK: Directory

    /// `Documents/Sessions/` — created on demand.
    public static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions", isDirectory: true)
    }

    private static func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private static func thumbnailURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }

    // MARK: Load

    /// Re-read every record from disk (newest first). Unreadable files are skipped.
    public func reload() {
        let fm = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = (try? fm.contentsOfDirectory(at: Self.directory,
                                                includingPropertiesForKeys: nil)) ?? []
        var loaded: [SessionRecord] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(SessionRecord.self, from: data)
            else { continue }
            loaded.append(record)
        }
        records = loaded.sorted { $0.date > $1.date }
    }

    // MARK: Save

    /// Persist a record (and a small PNG thumbnail, when a preview exists) and
    /// slot it into `records` newest-first.
    public func save(_ record: SessionRecord, thumbnail: CGImage? = nil) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: Self.recordURL(record.id), options: .atomic)
        }

        if let thumbnail,
           let small = Self.makeThumbnail(from: thumbnail) {
            Self.writePNG(small, to: Self.thumbnailURL(record.id))
            thumbnailCache[record.id] = small
        }

        records.removeAll { $0.id == record.id }
        records.append(record)
        records.sort { $0.date > $1.date }
    }

    // MARK: Delete

    public func delete(_ record: SessionRecord) {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.recordURL(record.id))
        try? fm.removeItem(at: Self.thumbnailURL(record.id))
        thumbnailCache[record.id] = nil
        records.removeAll { $0.id == record.id }
    }

    // MARK: Thumbnails

    /// Cached PNG thumbnail for a record, if one was saved with it.
    public func thumbnail(for record: SessionRecord) -> CGImage? {
        if let cached = thumbnailCache[record.id] { return cached }
        guard let image = Self.readPNG(from: Self.thumbnailURL(record.id)) else { return nil }
        thumbnailCache[record.id] = image
        return image
    }

    /// Downscale a preview so the stored thumbnail stays tiny (≤ `maxDimension` px).
    public static func makeThumbnail(from image: CGImage, maxDimension: Int = 256) -> CGImage? {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }
        guard max(w, h) > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(max(w, h))
        let tw = max(1, Int(Double(w) * scale))
        let th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    // MARK: PNG round-trip (ImageIO — first party, simulator safe)

    private static func writePNG(_ image: CGImage, to url: URL) {
        #if canImport(UniformTypeIdentifiers)
        let pngType = UTType.png.identifier as CFString
        #else
        let pngType = "public.png" as CFString
        #endif
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, pngType, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func readPNG(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
