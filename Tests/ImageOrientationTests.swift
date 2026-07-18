import XCTest
import CoreGraphics
@testable import StarFlow

/// Pure verification of the develop-phase orientation pipeline:
/// gravity → DeviceTilt, tilt → rotation-to-upright, and the individual-pixel
/// mapping of every quarter-turn rotation (buffer level and CGImage level).
final class ImageOrientationTests: XCTestCase {

    // MARK: - Gravity → tilt (device frame: +x right of screen, +y toward top)

    func testTiltFromGravity() {
        // Portrait upright: gravity points out of the bottom of the screen.
        XCTAssertEqual(DeviceTilt.from(gravityX: 0.02, gravityY: -0.98), .portrait)
        // Upside down.
        XCTAssertEqual(DeviceTilt.from(gravityX: -0.05, gravityY: 0.97), .portraitUpsideDown)
        // Home-indicator side on the RIGHT (device rotated counterclockwise).
        XCTAssertEqual(DeviceTilt.from(gravityX: -0.95, gravityY: 0.04), .landscapeLeft)
        // Home-indicator side on the LEFT (device rotated clockwise).
        XCTAssertEqual(DeviceTilt.from(gravityX: 0.96, gravityY: -0.03), .landscapeRight)
        // Tilted far back toward the zenith: the residual in-plane component decides.
        XCTAssertEqual(DeviceTilt.from(gravityX: -0.20, gravityY: 0.05), .landscapeLeft)
        // Degenerate dead-flat reading resolves to portrait (the locked UI orientation).
        XCTAssertEqual(DeviceTilt.from(gravityX: 0, gravityY: 0), .portrait)
    }

    // MARK: - Tilt → rotation (sensor-native landscape, EXIF conventions)

    func testRotationToUprightMapping() {
        XCTAssertEqual(ImageOrientation.rotationToUpright(for: .portrait), .cw90)
        XCTAssertEqual(ImageOrientation.rotationToUpright(for: .portraitUpsideDown), .cw270)
        XCTAssertEqual(ImageOrientation.rotationToUpright(for: .landscapeLeft), .none)
        XCTAssertEqual(ImageOrientation.rotationToUpright(for: .landscapeRight), .cw180)
    }

    // MARK: - Pure pixel mapping (3×2 grayscale, row 0 = top)
    //
    //   source        cw90        cw180          cw270
    //   10 20 30      40 10       60 50 40       30 60
    //   40 50 60      50 20       30 20 10       20 50
    //                 60 30                      10 40

    private let src: [UInt8] = [10, 20, 30,
                                40, 50, 60]

    func testRotatedPixels90() throws {
        let rot = try XCTUnwrap(ImageOrientation.rotatedPixels(
            src, width: 3, height: 2, bytesPerPixel: 1, rotation: .cw90))
        XCTAssertEqual(rot.width, 2)
        XCTAssertEqual(rot.height, 3)
        XCTAssertEqual(rot.pixels, [40, 10,
                                    50, 20,
                                    60, 30])
    }

    func testRotatedPixels180() throws {
        let rot = try XCTUnwrap(ImageOrientation.rotatedPixels(
            src, width: 3, height: 2, bytesPerPixel: 1, rotation: .cw180))
        XCTAssertEqual(rot.width, 3)
        XCTAssertEqual(rot.height, 2)
        XCTAssertEqual(rot.pixels, [60, 50, 40,
                                    30, 20, 10])
    }

    func testRotatedPixels270() throws {
        let rot = try XCTUnwrap(ImageOrientation.rotatedPixels(
            src, width: 3, height: 2, bytesPerPixel: 1, rotation: .cw270))
        XCTAssertEqual(rot.width, 2)
        XCTAssertEqual(rot.height, 3)
        XCTAssertEqual(rot.pixels, [30, 60,
                                    20, 50,
                                    10, 40])
    }

    func testRotatedPixelsNoneIsIdentity() throws {
        let rot = try XCTUnwrap(ImageOrientation.rotatedPixels(
            src, width: 3, height: 2, bytesPerPixel: 1, rotation: .none))
        XCTAssertEqual(rot.width, 3)
        XCTAssertEqual(rot.height, 2)
        XCTAssertEqual(rot.pixels, src)
    }

    func testRotatedPixelsRejectsMismatchedGeometry() {
        XCTAssertNil(ImageOrientation.rotatedPixels(
            src, width: 4, height: 2, bytesPerPixel: 1, rotation: .cw90))
        XCTAssertNil(ImageOrientation.rotatedPixels(
            [], width: 0, height: 0, bytesPerPixel: 1, rotation: .cw90))
    }

    /// Multi-byte pixels move as intact units (RGBA path).
    func testRotatedPixelsKeepsPixelBytesTogether() throws {
        // 2×1 image, 4 bytes per pixel: [A][B] → cw90 → column [A] over [B]? No:
        // cw90 of a 2×1 row is a 1×2 column with the LEFT pixel at the bottom.
        let a: [UInt8] = [1, 2, 3, 4]
        let b: [UInt8] = [5, 6, 7, 8]
        let rot = try XCTUnwrap(ImageOrientation.rotatedPixels(
            a + b, width: 2, height: 1, bytesPerPixel: 4, rotation: .cw90))
        XCTAssertEqual(rot.width, 1)
        XCTAssertEqual(rot.height, 2)
        XCTAssertEqual(rot.pixels, a + b)   // top = A (was left), bottom = B (was right)
    }

    /// Four clockwise quarter turns must reproduce the original raster exactly.
    func testFourQuarterTurnsRoundTrip() throws {
        var pixels = src
        var w = 3, h = 2
        for _ in 0..<4 {
            let rot = try XCTUnwrap(ImageOrientation.rotatedPixels(
                pixels, width: w, height: h, bytesPerPixel: 1, rotation: .cw90))
            pixels = rot.pixels
            w = rot.width
            h = rot.height
        }
        XCTAssertEqual(w, 3)
        XCTAssertEqual(h, 2)
        XCTAssertEqual(pixels, src)
    }

    // MARK: - CGImage round trip (grayscale, the stacker's output format)

    func testCGImageRotationMatchesPixelMapping() throws {
        let image = try XCTUnwrap(makeGrayImage(src, width: 3, height: 2))
        let rotated = try XCTUnwrap(ImageOrientation.rotated(image, by: .cw90))
        XCTAssertEqual(rotated.width, 2)
        XCTAssertEqual(rotated.height, 3)
        XCTAssertEqual(try XCTUnwrap(grayBytes(rotated)), [40, 10,
                                                           50, 20,
                                                           60, 30])
        // .none returns the identical image, untouched.
        let untouched = try XCTUnwrap(ImageOrientation.rotated(image, by: .none))
        XCTAssertTrue(untouched === image)
    }

    func testCGImageRotation180PreservesDimensions() throws {
        let image = try XCTUnwrap(makeGrayImage(src, width: 3, height: 2))
        let rotated = try XCTUnwrap(ImageOrientation.rotated(image, by: .cw180))
        XCTAssertEqual(rotated.width, 3)
        XCTAssertEqual(rotated.height, 2)
        XCTAssertEqual(try XCTUnwrap(grayBytes(rotated)), [60, 50, 40,
                                                           30, 20, 10])
    }

    // MARK: - Helpers

    private func makeGrayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        precondition(bytes.count == width * height)
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let out = data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                out[y * rowBytes + x] = bytes[y * width + x]
            }
        }
        return ctx.makeImage()
    }

    private func grayBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drew: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drew ? bytes : nil
    }
}
