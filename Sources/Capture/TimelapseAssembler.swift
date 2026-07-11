import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

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

/// Assembles captured stills into an H.264 .mp4 (see docs/DESIGN.md — Modes:
/// MotionTimelapse: 240 one-second exposures over two hours become a ten-second
/// clip at 24 fps).
///
/// Input is plain CGImages, so there is no capture-hardware dependency and the
/// whole path — AVAssetWriter included — runs on the simulator. Mixed-size frames
/// are aspect-fit onto the first frame's (even-rounded) canvas with black bars,
/// never distorted; H.264 requires even pixel dimensions.
public final class TimelapseAssembler {

    public init() {}

    /// Convenience: encodes into a uniquely named .mp4 in the temporary directory.
    public func assemble(frames: [CGImage], fps: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("starflow-timelapse-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        return try await assemble(frames: frames, fps: fps, outputURL: url)
    }

    /// Encode `frames` at `fps` (clamped to 1…120) into an H.264 .mp4 at
    /// `outputURL`, replacing any existing file there.
    @discardableResult
    public func assemble(frames: [CGImage], fps: Int, outputURL: URL) async throws -> URL {
        guard let first = frames.first else { throw TimelapseError.noFrames }
        let rate = CMTimeScale(max(1, min(120, fps)))
        // H.264 wants even dimensions; round down, never below 2.
        let width = max(2, first.width & ~1)
        let height = max(2, first.height & ~1)

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            throw TimelapseError.writerSetup(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
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

        for (index, frame) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let buffer = try makePixelBuffer(from: frame, width: width, height: height,
                                             pool: adaptor.pixelBufferPool)
            let time = CMTime(value: CMTimeValue(index), timescale: rate)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                input.markAsFinished()
                writer.cancelWriting()
                throw TimelapseError.encodeFailed(
                    writer.error?.localizedDescription ?? "append refused at frame \(index)")
            }
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
