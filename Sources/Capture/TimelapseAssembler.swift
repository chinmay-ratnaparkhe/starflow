import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO

// MARK: - Errors

public enum TimelapseError: LocalizedError {
    case noFrames
    case writerSetup(String)
    case pixelBufferUnavailable
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFrames:
            return "No frames to assemble — the timelapse captured nothing."
        case .writerSetup(let detail):
            return "Could not set up the video writer (\(detail))."
        case .pixelBufferUnavailable:
            return "Could not allocate a video frame buffer."
        case .encodeFailed(let detail):
            return "Video encoding failed (\(detail))."
        }
    }
}

// MARK: - TimelapseAssembler

/// Assembles captured stills into an H.264/HEVC .mp4 (see docs/DESIGN.md — Modes:
/// MotionTimelapse: 240 one-second exposures over two hours become a ten-second
/// clip at 24 fps).
///
/// Input is plain CGImages (in memory, or as image files streamed one at a time
/// from disk), so there is no capture-hardware dependency and the whole path —
/// AVAssetWriter included — runs on the simulator. Mixed-size frames are
/// aspect-fit onto the first frame's (even-rounded) canvas with black bars,
/// never distorted; both codecs require even pixel dimensions.
public final class TimelapseAssembler {

    /// Output codec. H.264 plays everywhere and is the simulator-proven default;
    /// HEVC halves the file size on device hardware with a dedicated encoder.
    public enum Codec: String, Sendable {
        case h264
        case hevc

        var avType: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc: return .hevc
            }
        }
    }

    public init() {}

    // MARK: - Pure parts (unit-tested without touching AVAssetWriter)

    /// Encoder frame rates the assembler will accept.
    public static let fpsRange: ClosedRange<Int> = 1...120

    /// Clamp a requested fps into the encodable range.
    public static func clampedFPS(_ fps: Int) -> Int {
        min(max(fps, fpsRange.lowerBound), fpsRange.upperBound)
    }

    /// H.264/HEVC want even dimensions; round down, never below 2.
    public static func evenCanvas(width: Int, height: Int) -> (width: Int, height: Int) {
        (width: max(2, width & ~1), height: max(2, height & ~1))
    }

    /// Read one frame image from disk without ImageIO holding a decode cache
    /// (frames are visited exactly once during assembly).
    public static func loadFrame(at url: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    // MARK: - Entry points

    /// Convenience: encodes into a uniquely named .mp4 in the temporary directory.
    public func assemble(frames: [CGImage], fps: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("starflow-timelapse-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        return try await assemble(frames: frames, fps: fps, outputURL: url)
    }

    /// Encode in-memory `frames` at `fps` (clamped to 1…120) into an .mp4 at
    /// `outputURL`, replacing any existing file there.
    @discardableResult
    public func assemble(frames: [CGImage], fps: Int, outputURL: URL,
                         codec: Codec = .h264) async throws -> URL {
        guard let first = frames.first else { throw TimelapseError.noFrames }
        return try await encode(reference: first, frameCount: frames.count,
                                frame: { frames[$0] }, fps: fps,
                                outputURL: outputURL, codec: codec, progress: nil)
    }

    /// Encode frames stored as image files (JPEG/PNG/HEIC) at `fps` into an
    /// .mp4 at `outputURL`. Frames are loaded ONE at a time, so a 900-frame
    /// 1080p-class timelapse never holds more than a single decoded frame in
    /// memory. An unreadable file is skipped (the remaining frames still make
    /// a clip); if nothing on the list can be read, the assembly fails loudly.
    /// `progress` is called after every frame slot with (framesVisited, total).
    @discardableResult
    public func assemble(frameURLs: [URL], fps: Int, outputURL: URL,
                         codec: Codec = .h264,
                         progress: ((Int, Int) -> Void)? = nil) async throws -> URL {
        guard !frameURLs.isEmpty else { throw TimelapseError.noFrames }
        // The first READABLE frame sizes the canvas — a single corrupt file at
        // index 0 must not doom the other frames.
        var reference: CGImage?
        for url in frameURLs {
            if let image = Self.loadFrame(at: url) { reference = image; break }
        }
        guard let reference else {
            throw TimelapseError.encodeFailed("no readable frames on disk")
        }
        return try await encode(reference: reference, frameCount: frameURLs.count,
                                frame: { Self.loadFrame(at: frameURLs[$0]) }, fps: fps,
                                outputURL: outputURL, codec: codec, progress: progress)
    }

    // MARK: - Shared encoder core

    /// `frame(i)` supplies the image for slot `i`, or nil to skip that slot
    /// (unreadable file). Presentation times count APPENDED frames so a skip
    /// never leaves a stutter-hole in the clip.
    private func encode(reference: CGImage, frameCount: Int,
                        frame: (Int) -> CGImage?,
                        fps: Int, outputURL: URL, codec: Codec,
                        progress: ((Int, Int) -> Void)?) async throws -> URL {
        let rate = CMTimeScale(Self.clampedFPS(fps))
        let canvas = Self.evenCanvas(width: reference.width, height: reference.height)
        let width = canvas.width
        let height = canvas.height

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw TimelapseError.writerSetup(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: codec.avType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else {
            throw TimelapseError.writerSetup("cannot add video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw TimelapseError.writerSetup(writer.error?.localizedDescription ?? "startWriting refused")
        }
        writer.startSession(atSourceTime: .zero)

        // Any failure inside the loop (pixel-buffer allocation, append refusal,
        // task cancellation while waiting on the input) must cancel the writer —
        // cancelWriting() also removes the partial output file, so an aborted
        // assembly never strands a half-written .mp4 in the timelapse library.
        var appended = 0
        do {
            for index in 0..<frameCount {
                guard let image = frame(index) else {
                    progress?(index + 1, frameCount)
                    continue
                }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                let buffer = try makePixelBuffer(from: image, width: width, height: height,
                                                 pool: adaptor.pixelBufferPool)
                let time = CMTime(value: CMTimeValue(appended), timescale: rate)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw TimelapseError.encodeFailed(
                        writer.error?.localizedDescription ?? "append refused at frame \(index)")
                }
                appended += 1
                progress?(index + 1, frameCount)
            }
            guard appended > 0 else { throw TimelapseError.noFrames }
        } catch {
            input.markAsFinished()
            writer.cancelWriting()
            throw error
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw TimelapseError.encodeFailed(
                writer.error?.localizedDescription ?? "finishWriting ended in status \(writer.status.rawValue)")
        }
        return outputURL
    }

    // MARK: - CGImage → pixel buffer bridge

    private func makePixelBuffer(from image: CGImage, width: Int, height: Int,
                                 pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var maybeBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer)
        }
        if maybeBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA, attrs as CFDictionary, &maybeBuffer)
        }
        guard let buffer = maybeBuffer else { throw TimelapseError.pixelBufferUnavailable }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(data: base,
                                  width: CVPixelBufferGetWidth(buffer),
                                  height: CVPixelBufferGetHeight(buffer),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw TimelapseError.pixelBufferUnavailable
        }

        // Black canvas, then aspect-fit the frame (pad with bars, never distort).
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / CGFloat(image.width),
                        CGFloat(height) / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (CGFloat(width) - drawWidth) / 2,
                                   y: (CGFloat(height) - drawHeight) / 2,
                                   width: drawWidth, height: drawHeight))
        return buffer
    }
}
