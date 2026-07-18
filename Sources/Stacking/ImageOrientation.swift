import Foundation
import CoreGraphics
import CoreMotion

// MARK: - DeviceTilt
//
// Field lesson (Seattle session): the phone rides the Flow 2 Pro clamp LANDSCAPE
// while the app's UI is locked to portrait, so UIDevice.orientation /
// interface orientation are useless for telling how the sensor was actually held.
// Gravity is the ground truth: CoreMotion reports it in the device frame
// (portrait upright ⇒ (0, −1, 0)), which works even with the UI orientation locked.

/// How the phone was physically held, derived from the CoreMotion gravity vector.
/// Named after `UIDeviceOrientation` conventions:
///  - `landscapeLeft`  = rotated counterclockwise, home-indicator side on the RIGHT
///    (gravity.x ≈ −1). This is the back camera's sensor-native orientation.
///  - `landscapeRight` = rotated clockwise, home-indicator side on the LEFT
///    (gravity.x ≈ +1).
public enum DeviceTilt: String, Codable, Equatable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// Pure gravity → tilt mapping (device frame: +x right of screen, +y toward
    /// the top of the screen). The dominant in-screen-plane axis wins; a phone
    /// tilted far back toward the zenith still resolves from the residual x/y.
    /// Degenerate (0, 0) resolves to portrait — the UI's locked orientation.
    public static func from(gravityX: Double, gravityY: Double) -> DeviceTilt {
        if abs(gravityX) > abs(gravityY) {
            return gravityX < 0 ? .landscapeLeft : .landscapeRight
        }
        return gravityY > 0 ? .portraitUpsideDown : .portrait
    }
}

// MARK: - ImageRotation

/// Quarter-turn rotations, clockwise as seen by a viewer of the displayed image.
public enum ImageRotation: Int, Codable, Equatable, Sendable {
    case none = 0
    case cw90 = 90
    case cw180 = 180
    case cw270 = 270
}

// MARK: - ImageOrientation

/// Pure orientation math + CGImage rotation for the develop phase.
///
/// The back camera delivers sensor-native LANDSCAPE frames with no orientation
/// metadata applied (`AVCapturePhoto.cgImageRepresentation()` is the raw raster).
/// A frame is upright as-is only when the device was held in `landscapeLeft`
/// (home-indicator side right — EXIF 1). Every other hold needs a quarter-turn:
/// portrait is the classic EXIF 6 case (rotate 90° CW to display).
public enum ImageOrientation {

    /// Rotation that makes a sensor-native back-camera frame display upright for
    /// the way the phone was physically held during capture.
    public static func rotationToUpright(for tilt: DeviceTilt) -> ImageRotation {
        switch tilt {
        case .portrait:           return .cw90    // EXIF 6
        case .portraitUpsideDown: return .cw270   // EXIF 8
        case .landscapeLeft:      return .none    // EXIF 1 — sensor-native
        case .landscapeRight:     return .cw180   // EXIF 3
        }
    }

    /// Pure pixel permutation on a tightly packed row-major buffer (row 0 = top
    /// row of the displayed image). Unit-tested at the individual-pixel level.
    /// Returns nil when the buffer size does not match the stated geometry.
    public static func rotatedPixels(_ pixels: [UInt8], width: Int, height: Int,
                                     bytesPerPixel: Int, rotation: ImageRotation)
        -> (pixels: [UInt8], width: Int, height: Int)? {
        guard width > 0, height > 0, bytesPerPixel > 0,
              pixels.count == width * height * bytesPerPixel else { return nil }
        if rotation == .none { return (pixels, width, height) }
        let dw = rotation == .cw180 ? width : height
        let dh = rotation == .cw180 ? height : width
        var out = [UInt8](repeating: 0, count: pixels.count)
        for dy in 0..<dh {
            for dx in 0..<dw {
                let sx: Int
                let sy: Int
                switch rotation {
                case .cw90:          // dst(x, y) ← src(y, H−1−x)
                    sx = dy
                    sy = height - 1 - dx
                case .cw180:         // dst(x, y) ← src(W−1−x, H−1−y)
                    sx = width - 1 - dx
                    sy = height - 1 - dy
                case .cw270:         // dst(x, y) ← src(W−1−y, x)
                    sx = width - 1 - dy
                    sy = dx
                case .none:
                    sx = dx
                    sy = dy
                }
                let s = (sy * width + sx) * bytesPerPixel
                let d = (dy * dw + dx) * bytesPerPixel
                for b in 0..<bytesPerPixel { out[d + b] = pixels[s + b] }
            }
        }
        return (out, dw, dh)
    }

    /// Rotate a CGImage by a quarter turn (lossless pixel permutation, no
    /// resampling). 8-bit grayscale stays grayscale; everything else (including
    /// the stacker's opaque RGB colour output) round-trips through RGBA8 —
    /// lossless for opaque pixels, since premultiplying by alpha 255 is identity.
    public static func rotated(_ image: CGImage, by rotation: ImageRotation) -> CGImage? {
        guard rotation != .none else { return image }
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return nil }

        let isGray = image.colorSpace?.model == .monochrome && image.bitsPerPixel == 8
        let bpp = isGray ? 1 : 4
        let space = isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = isGray
            ? CGImageAlphaInfo.none.rawValue
            : CGImageAlphaInfo.premultipliedLast.rawValue

        // Decode into a tightly packed buffer (memory row 0 = top of the image).
        var src = [UInt8](repeating: 0, count: w * h * bpp)
        let decoded: Bool = src.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * bpp,
                                      space: space, bitmapInfo: bitmapInfo) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard decoded,
              let rot = rotatedPixels(src, width: w, height: h,
                                      bytesPerPixel: bpp, rotation: rotation) else { return nil }

        // Re-encode (the destination context may pad rows — copy row by row).
        guard let ctx = CGContext(data: nil, width: rot.width, height: rot.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: bitmapInfo),
              let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let tight = rot.width * bpp
        rot.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for y in 0..<rot.height {
                memcpy(data.advanced(by: y * rowBytes), base.advanced(by: y * tight), tight)
            }
        }
        return ctx.makeImage()
    }
}

// MARK: - GravityTiltProvider

/// Samples the physical device tilt from CoreMotion gravity — the seam behind
/// `SessionHooks.captureTilt`. The session engine warms it up at session start
/// and takes the authoritative sample when the Capture phase begins (framing is
/// locked in the clamp by then); capture teardown stops the updates on every
/// exit path. No motion hardware (simulator) ⇒ portrait, matching the locked UI.
@MainActor
public final class GravityTiltProvider {

    public static let shared = GravityTiltProvider()

    private let motion = CMMotionManager()
    private var lastTilt: DeviceTilt = .portrait

    /// Minimum in-screen-plane gravity magnitude for a sample to be trusted.
    /// Aimed near the zenith, gravity is almost entirely along −z and the x/y
    /// residual is sensor noise — a degenerate sample must never overwrite a
    /// confident one (0.25 ≈ trust readings more than ~15° away from zenith).
    private static let minPlanarGravity = 0.25

    public init() {}

    /// Current best tilt estimate. Starts device-motion updates on first call
    /// (no user permission involved); until the first gravity sample arrives it
    /// returns the last known tilt (portrait by default). Samples taken while
    /// the phone points near the zenith are ignored in favour of the last
    /// confident reading (typically the session-start warm-up, taken while the
    /// phone was still being clamped and framed).
    public func sampleTilt() -> DeviceTilt {
        guard motion.isDeviceMotionAvailable else { return lastTilt }
        if !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 30.0
            motion.startDeviceMotionUpdates()
        }
        if let gravity = motion.deviceMotion?.gravity {
            let planar = (gravity.x * gravity.x + gravity.y * gravity.y).squareRoot()
            if planar >= Self.minPlanarGravity {
                lastTilt = DeviceTilt.from(gravityX: gravity.x, gravityY: gravity.y)
            }
        }
        return lastTilt
    }

    /// Stop motion updates (called from capture teardown on every exit path).
    public func stopUpdates() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }
}
