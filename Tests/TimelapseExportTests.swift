import XCTest
import CoreGraphics
@testable import StarFlow

/// Feature 8 — timelapse video export. Pure parts first (frame-retention
/// cap/downscale math, assembler input validation), then a disk round-trip for
/// the frame store and one tiny real H.264 assembly (the whole encoder path is
/// simulator-safe by design).
final class TimelapseExportTests: XCTestCase {

    // MARK: - Helpers

    private func makeImage(width: Int, height: Int, gray: CGFloat = 0.4) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func scratchDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("starflow-tests-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    // MARK: - TimelapseFramePolicy: downscale math

    func testScaledSizeNeverUpscales() {
        let small = TimelapseFramePolicy.scaledSize(width: 1280, height: 720)
        XCTAssertEqual(small.width, 1280)
        XCTAssertEqual(small.height, 720)
        let tiny = TimelapseFramePolicy.scaledSize(width: 256, height: 256)
        XCTAssertEqual(tiny.width, 256)
        XCTAssertEqual(tiny.height, 256)
    }

    func testScaledSizeAtExactCeilingUnchanged() {
        let s = TimelapseFramePolicy.scaledSize(width: 1920, height: 1080)
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
    }

    func testScaledSizeLandscapeDownscale() {
        // 4032×3024 (12 MP main sensor, 4:3) → longest side pinned to 1920.
        let s = TimelapseFramePolicy.scaledSize(width: 4032, height: 3024)
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1440)
    }

    func testScaledSizePortraitDownscale() {
        let s = TimelapseFramePolicy.scaledSize(width: 3024, height: 4032)
        XCTAssertEqual(s.width, 1440)
        XCTAssertEqual(s.height, 1920)
    }

    func testScaledSizePreservesAspectForWidescreen() {
        let s = TimelapseFramePolicy.scaledSize(width: 3840, height: 2160)
        XCTAssertEqual(s.width, 1920)
        XCTAssertEqual(s.height, 1080)
    }

    func testScaledSizeDegenerateInputCollapses() {
        let zeroW = TimelapseFramePolicy.scaledSize(width: 0, height: 100)
        XCTAssertEqual(zeroW.width, 0)
        XCTAssertEqual(zeroW.height, 0)
        let negative = TimelapseFramePolicy.scaledSize(width: -10, height: 10)
        XCTAssertEqual(negative.width, 0)
        XCTAssertEqual(negative.height, 0)
    }

    // MARK: - TimelapseFramePolicy: retention cap + storage floor

    func testRetainedFrameCountCapsAtMax() {
        XCTAssertEqual(TimelapseFramePolicy.retainedFrameCount(planned: 240), 240)
        XCTAssertEqual(TimelapseFramePolicy.retainedFrameCount(planned: 900), 900)
        XCTAssertEqual(TimelapseFramePolicy.retainedFrameCount(planned: 2000),
                       TimelapseFramePolicy.maxFrames)
        XCTAssertEqual(TimelapseFramePolicy.retainedFrameCount(planned: 0), 0)
        XCTAssertEqual(TimelapseFramePolicy.retainedFrameCount(planned: -5), 0)
    }

    func testShouldRetainStopsAtFrameCap() {
        XCTAssertTrue(TimelapseFramePolicy.shouldRetain(
            retainedCount: 0, freeDiskBytes: 64_000_000_000))
        XCTAssertTrue(TimelapseFramePolicy.shouldRetain(
            retainedCount: TimelapseFramePolicy.maxFrames - 1,
            freeDiskBytes: 64_000_000_000))
        XCTAssertFalse(TimelapseFramePolicy.shouldRetain(
            retainedCount: TimelapseFramePolicy.maxFrames,
            freeDiskBytes: 64_000_000_000))
    }

    func testShouldRetainStopsBelowStorageFloor() {
        XCTAssertFalse(TimelapseFramePolicy.shouldRetain(
            retainedCount: 10,
            freeDiskBytes: TimelapseFramePolicy.retentionFloorBytes - 1))
        XCTAssertTrue(TimelapseFramePolicy.shouldRetain(
            retainedCount: 10,
            freeDiskBytes: TimelapseFramePolicy.retentionFloorBytes))
    }

    func testShouldRetainWithUnknownFreeSpaceRetains() {
        // Unknown disk = retain; the pre-flight vetted the plan and the
        // engine's in-flight guardian still owns the hard floor.
        XCTAssertTrue(TimelapseFramePolicy.shouldRetain(retainedCount: 10,
                                                        freeDiskBytes: nil))
    }

    func testPlannedBytesIsCappedAndIncludesVideo() {
        let perFrame = TimelapseFramePolicy.estimatedBytesPerFrame
        let video = TimelapseFramePolicy.assembledVideoBytes
        XCTAssertEqual(TimelapseFramePolicy.plannedBytes(frameCount: 240),
                       240 * perFrame + video)
        // Beyond the cap the plan stops growing — retention stops there too.
        XCTAssertEqual(TimelapseFramePolicy.plannedBytes(frameCount: 2000),
                       TimelapseFramePolicy.plannedBytes(frameCount: 900))
        XCTAssertEqual(TimelapseFramePolicy.plannedBytes(frameCount: 0), video)
    }

    // MARK: - TimelapseFramePolicy: fps choice + clip length

    func testSanitizedFPSAllowsOnly24And30() {
        XCTAssertEqual(TimelapseFramePolicy.sanitizedFPS(24), 24)
        XCTAssertEqual(TimelapseFramePolicy.sanitizedFPS(30), 30)
        XCTAssertEqual(TimelapseFramePolicy.sanitizedFPS(0), TimelapseFramePolicy.defaultFPS)
        XCTAssertEqual(TimelapseFramePolicy.sanitizedFPS(60), TimelapseFramePolicy.defaultFPS)
        XCTAssertEqual(TimelapseFramePolicy.sanitizedFPS(-1), TimelapseFramePolicy.defaultFPS)
    }

    func testClipSeconds() {
        // The mode's promise: 240 frames at 24 fps = the ten-second clip.
        XCTAssertEqual(TimelapseFramePolicy.clipSeconds(frames: 240, fps: 24), 10,
                       accuracy: 1e-9)
        XCTAssertEqual(TimelapseFramePolicy.clipSeconds(frames: 240, fps: 30), 8,
                       accuracy: 1e-9)
        XCTAssertEqual(TimelapseFramePolicy.clipSeconds(frames: 0, fps: 24), 0,
                       accuracy: 1e-9)
        XCTAssertEqual(TimelapseFramePolicy.clipSeconds(frames: 240, fps: 0), 0,
                       accuracy: 1e-9)
    }

    // MARK: - TimelapseAssembler: pure parts

    func testClampedFPSBounds() {
        XCTAssertEqual(TimelapseAssembler.clampedFPS(0), 1)
        XCTAssertEqual(TimelapseAssembler.clampedFPS(-3), 1)
        XCTAssertEqual(TimelapseAssembler.clampedFPS(24), 24)
        XCTAssertEqual(TimelapseAssembler.clampedFPS(120), 120)
        XCTAssertEqual(TimelapseAssembler.clampedFPS(500), 120)
    }

    func testEvenCanvasRoundsDownNeverBelowTwo() {
        let odd = TimelapseAssembler.evenCanvas(width: 1919, height: 1079)
        XCTAssertEqual(odd.width, 1918)
        XCTAssertEqual(odd.height, 1078)
        let even = TimelapseAssembler.evenCanvas(width: 1920, height: 1080)
        XCTAssertEqual(even.width, 1920)
        XCTAssertEqual(even.height, 1080)
        let tiny = TimelapseAssembler.evenCanvas(width: 0, height: 1)
        XCTAssertEqual(tiny.width, 2)
        XCTAssertEqual(tiny.height, 2)
    }

    // MARK: - TimelapseAssembler: input validation

    func testAssembleEmptyFrameArrayThrowsNoFrames() async {
        do {
            _ = try await TimelapseAssembler().assemble(frames: [], fps: 24)
            XCTFail("Empty frame array must throw")
        } catch let error as TimelapseError {
            guard case .noFrames = error else {
                return XCTFail("Expected .noFrames, got \(error)")
            }
        } catch {
            XCTFail("Expected TimelapseError, got \(error)")
        }
    }

    func testAssembleEmptyURLListThrowsNoFrames() async {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("starflow-test-empty-\(UUID().uuidString).mp4")
        do {
            _ = try await TimelapseAssembler().assemble(frameURLs: [], fps: 24,
                                                        outputURL: output)
            XCTFail("Empty URL list must throw")
        } catch let error as TimelapseError {
            guard case .noFrames = error else {
                return XCTFail("Expected .noFrames, got \(error)")
            }
        } catch {
            XCTFail("Expected TimelapseError, got \(error)")
        }
    }

    func testAssembleWithOnlyUnreadableURLsThrows() async {
        let missing = [
            FileManager.default.temporaryDirectory
                .appendingPathComponent("starflow-test-missing-a-\(UUID().uuidString).jpg"),
            FileManager.default.temporaryDirectory
                .appendingPathComponent("starflow-test-missing-b-\(UUID().uuidString).jpg"),
        ]
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("starflow-test-unreadable-\(UUID().uuidString).mp4")
        do {
            _ = try await TimelapseAssembler().assemble(frameURLs: missing, fps: 24,
                                                        outputURL: output)
            XCTFail("A list with no readable frames must throw")
        } catch is TimelapseError {
            // expected — nothing on the list could be decoded
        } catch {
            XCTFail("Expected TimelapseError, got \(error)")
        }
    }

    // MARK: - TimelapseFrameStore: disk round-trip

    func testFrameStoreRoundTripAndClear() {
        let store = TimelapseFrameStore(directory: scratchDirectory("frame-store"))
        defer { store.clear() }
        XCTAssertEqual(store.count, 0)

        XCTAssertTrue(store.append(makeImage(width: 64, height: 48)))
        XCTAssertTrue(store.append(makeImage(width: 64, height: 48, gray: 0.7)))
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.frameURLs.count, 2)

        for url in store.frameURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        // Frames inside the 1080p ceiling come back at native size.
        let reloaded = TimelapseAssembler.loadFrame(at: store.frameURLs[0])
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(reloaded?.width, 64)
        XCTAssertEqual(reloaded?.height, 48)

        let directory = store.directory
        store.clear()
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testFrameStoreDownscalesOversizedFrames() {
        // 2400×1800 breaches the 1920 ceiling → stored frame is 1920×1440.
        let store = TimelapseFrameStore(directory: scratchDirectory("downscale"))
        defer { store.clear() }
        XCTAssertTrue(store.append(makeImage(width: 2400, height: 1800)))
        let reloaded = TimelapseAssembler.loadFrame(at: store.frameURLs[0])
        XCTAssertEqual(reloaded?.width, 1920)
        XCTAssertEqual(reloaded?.height, 1440)
    }

    // MARK: - End-to-end: tiny real assembly (AVAssetWriter, simulator-safe)

    func testAssembleTinyClipFromStoredFrames() async throws {
        let store = TimelapseFrameStore(directory: scratchDirectory("assembly"))
        defer { store.clear() }
        for i in 0..<4 {
            XCTAssertTrue(store.append(makeImage(width: 64, height: 48,
                                                 gray: 0.2 + CGFloat(i) * 0.1)))
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("starflow-test-clip-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }

        final class ProgressBox { var last: (done: Int, total: Int)? }
        let box = ProgressBox()
        let url = try await TimelapseAssembler().assemble(
            frameURLs: store.frameURLs, fps: 24, outputURL: output,
            progress: { done, total in box.last = (done, total) })

        XCTAssertEqual(url, output)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 0, "Assembled clip must be a real file")
        XCTAssertEqual(box.last?.done, 4)
        XCTAssertEqual(box.last?.total, 4)
    }
}
