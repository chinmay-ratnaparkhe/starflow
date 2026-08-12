import XCTest
import CoreGraphics
import ImageIO
@testable import StarFlow

/// Task A — the camera truth log. The evidence the owner reads in the field is
/// only worth anything if it is COMPLETE (one row per delivered frame, no gaps),
/// SELF-DESCRIBING (every column filled or explicitly empty), and HONEST about
/// synthetic data. These tests pin all three, plus the bounded frame dumps.
///
/// Everything here runs on a temp directory — the real ledger lives in
/// `Documents/autotest/` and is off by default under XCTest.
@MainActor
final class FrameTruthTests: XCTestCase {

    // MARK: Helpers

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("frametruth-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeLog(root: URL, maxDumps: Int = FrameEvidence.maxDumpedFiles)
        -> (log: FrameTruthLog, writer: FrameTruthWriter, frames: URL, csv: URL) {
        let csv = root.appendingPathComponent("frames.csv")
        let frames = root.appendingPathComponent("frames", isDirectory: true)
        let writer = FrameTruthWriter(csvURL: csv,
                                      framesDirectory: frames,
                                      indexURL: frames.appendingPathComponent("index.json"),
                                      maxDumpedFiles: maxDumps)
        let log = FrameTruthLog(writer: writer)
        log.isEnabled = true          // XCTest disables the ledger by default
        return (log, writer, frames, csv)
    }

    private func frame(index: Int, at seconds: TimeInterval,
                       image: CGImage? = nil) -> SubFrame {
        SubFrame(index: index,
                 timestamp: Date(timeIntervalSince1970: 1_000_000 + seconds),
                 exposureSeconds: 1.0, iso: 3200,
                 pixelData: image ?? FrameTruthTests.grayImage(width: 8, height: 8))
    }

    private static func grayImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func rows(of csv: URL) -> [String] {
        let text = (try? String(contentsOf: csv, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: CSV shape

    func testCSVRowHasExactlyOneFieldPerColumn() {
        let truth = FrameTruth(frameIndex: 7, timestamp: Date(),
                               requestedExposureSeconds: 1.0, actualExposureSeconds: 0.998,
                               requestedISO: 3200, actualISO: 3196,
                               rejectionReason: "too few stars")
        let fields = truth.csvRow(row: 1, timestampText: "T").split(separator: ",",
                                                                   omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, FrameTruth.csvColumns.count,
                       "every column must get exactly one field, filled or empty")
        XCTAssertEqual(FrameTruth.csvHeader.split(separator: ",").count,
                       FrameTruth.csvColumns.count)
    }

    func testCSVQuotesReasonsContainingCommas() {
        var truth = FrameTruth(frameIndex: 0, timestamp: Date())
        truth.rejectionReason = "clouds, then \"haze\""
        let row = truth.csvRow(row: 1, timestampText: "T")
        XCTAssertTrue(row.contains("\"clouds, then \"\"haze\"\"\""),
                      "commas and quotes must be CSV-escaped, not corrupt the row")
    }

    func testHonoursRequestFlagsAnAutoExposureFrame() {
        // The failure this whole log exists to catch: a 1 s / ISO 3200 request
        // that the sensor silently answered with an 8 ms auto-exposure frame.
        let cheated = FrameTruth(frameIndex: 0, timestamp: Date(),
                                 requestedExposureSeconds: 1.0, actualExposureSeconds: 0.008,
                                 requestedISO: 3200, actualISO: 500)
        XCTAssertFalse(cheated.honoursRequest)
        let honest = FrameTruth(frameIndex: 0, timestamp: Date(),
                                requestedExposureSeconds: 1.0, actualExposureSeconds: 0.999,
                                requestedISO: 3200, actualISO: 3200)
        XCTAssertTrue(honest.honoursRequest)
        // Simulated rows are never flagged — they aren't sensor evidence.
        let sim = FrameTruth(frameIndex: 0, timestamp: Date(), simulated: true,
                             requestedExposureSeconds: 1.0, actualExposureSeconds: 0.008,
                             requestedISO: 3200, actualISO: 100)
        XCTAssertTrue(sim.honoursRequest)
    }

    func testHonoursRequestIsEmptyInCSVWithoutSensorEvidence() {
        // The failure mode this guards: a simulator run, or a row synthesized
        // from the request, reading as a PASS to a remote analyst who filters
        // on `honoursRequest == 1`. No sensor read-back → no verdict at all.
        let simulated = FrameTruth(frameIndex: 0, timestamp: Date(), simulated: true,
                                   sensorMeasured: false,
                                   requestedExposureSeconds: 1.0, actualExposureSeconds: 1.0,
                                   requestedISO: 3200, actualISO: 3200)
        XCTAssertEqual(simulated.honoursRequestCSV, "")
        let echoed = FrameTruth(frameIndex: 0, timestamp: Date(), simulated: false,
                                sensorMeasured: false,
                                requestedExposureSeconds: 1.0, actualExposureSeconds: 1.0,
                                requestedISO: 3200, actualISO: 3200)
        XCTAssertEqual(echoed.honoursRequestCSV, "",
                       "an echo of the request is not evidence, however well it agrees")
        let measured = FrameTruth(frameIndex: 0, timestamp: Date(), simulated: false,
                                  sensorMeasured: true,
                                  requestedExposureSeconds: 1.0, actualExposureSeconds: 0.999,
                                  requestedISO: 3200, actualISO: 3200)
        XCTAssertEqual(measured.honoursRequestCSV, "1")
    }

    func testEXIFDisagreementFailsClosed() {
        // The device read-back says the lock held; the photo's own EXIF says it
        // was an 8 ms frame. One of them is lying, so the row must not pass.
        let contradicted = FrameTruth(frameIndex: 0, timestamp: Date(), sensorMeasured: true,
                                      requestedExposureSeconds: 1.0,
                                      actualExposureSeconds: 1.0,
                                      requestedISO: 3200, actualISO: 3200,
                                      exifExposureSeconds: 0.008, exifISO: 500)
        XCTAssertFalse(contradicted.honoursRequest)
    }

    func testFormatClampIsFlaggedAndNotForgiven() {
        // A format that tops out at 0.5 s can never deliver the 1 s recipe. The
        // row must NOT read as honoured just because 0.5 s was the best on offer.
        let clamped = FrameTruth(frameIndex: 0, timestamp: Date(), sensorMeasured: true,
                                 requestedExposureSeconds: 1.0, actualExposureSeconds: 0.5,
                                 requestedISO: 3200, actualISO: 3200,
                                 formatMaxExposureSeconds: 0.5)
        XCTAssertTrue(clamped.exposureClamped)
        XCTAssertEqual(clamped.targetExposureSeconds, 0.5, accuracy: 1e-9)
        XCTAssertFalse(clamped.honoursRequest,
                       "the recipe asked for 1 s and did not get it — that is a NO")
        let unclamped = FrameTruth(frameIndex: 0, timestamp: Date(), sensorMeasured: true,
                                   requestedExposureSeconds: 1.0, actualExposureSeconds: 1.0,
                                   requestedISO: 3200, actualISO: 3200,
                                   formatMaxExposureSeconds: 1.0)
        XCTAssertFalse(unclamped.exposureClamped)
        XCTAssertTrue(unclamped.honoursRequest)
    }

    func testStageIfNeededNeverDuplicatesAFlushedFrame() {
        // On device the capture engine stages the real camera truth; the session
        // then calls stageIfNeeded for the SAME frame. If that row has already
        // been flushed out of the pending buffer, staging again would both
        // duplicate the frame and replace measured values with an echo.
        let root = makeTempRoot()
        let bundle = makeLog(root: root)
        bundle.log.beginSession()
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 3200,
                                   targetSubCount: 5, nudgeTracking: false)
        let f = frame(index: 0, at: 0)
        bundle.log.stage(FrameTruth(frameIndex: 0, timestamp: f.timestamp,
                                    sensorMeasured: true,
                                    requestedExposureSeconds: 1.0,
                                    actualExposureSeconds: 0.999,
                                    requestedISO: 3200, actualISO: 3200), image: nil)
        bundle.log.flushPending()                       // row is on disk now
        bundle.log.stageIfNeeded(frame: f, recipe: recipe, simulated: false)
        bundle.log.endSession()
        bundle.writer.drainForTesting()

        XCTAssertEqual(bundle.log.rowsWritten, 1, "one delivered frame, one row")
        XCTAssertEqual(rows(of: bundle.csv).count, 2, "header + exactly one row")
    }

    // MARK: Dump policy (pure)

    func testDumpPolicyKeepsFirstThreeThenEveryNth() {
        XCTAssertTrue(FrameEvidence.shouldDump(frameIndex: 0, everyN: 10))
        XCTAssertTrue(FrameEvidence.shouldDump(frameIndex: 1, everyN: 10))
        XCTAssertTrue(FrameEvidence.shouldDump(frameIndex: 2, everyN: 10))
        XCTAssertFalse(FrameEvidence.shouldDump(frameIndex: 3, everyN: 10))
        XCTAssertTrue(FrameEvidence.shouldDump(frameIndex: 10, everyN: 10))
        XCTAssertFalse(FrameEvidence.shouldDump(frameIndex: 11, everyN: 10))
        // N = 0 disables the cadence but never the mandatory first frames.
        XCTAssertTrue(FrameEvidence.shouldDump(frameIndex: 1, everyN: 0))
        XCTAssertFalse(FrameEvidence.shouldDump(frameIndex: 30, everyN: 0))
        XCTAssertEqual(FrameEvidence.sanitizedDumpEveryN(-5), 0)
        XCTAssertEqual(FrameEvidence.sanitizedDumpEveryN(7), 7)
    }

    // MARK: Ledger completeness

    func testEveryStagedFrameProducesExactlyOneRowInOrder() {
        let root = makeTempRoot()
        let bundle = makeLog(root: root)
        bundle.log.beginSession()
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 3200,
                                   targetSubCount: 20, nudgeTracking: true)
        for i in 0..<12 {
            let f = frame(index: i, at: Double(i))
            bundle.log.stageIfNeeded(frame: f, recipe: recipe, simulated: true)
            bundle.log.annotate(timestamp: f.timestamp, sessionFrameIndex: i,
                                phase: "capture", starCount: 40 + i,
                                accepted: i % 4 != 0,
                                rejectionReason: i % 4 == 0 ? "too few stars" : nil)
        }
        bundle.log.endSession()
        bundle.writer.drainForTesting()

        let lines = rows(of: bundle.csv)
        XCTAssertEqual(lines.count, 13, "header + one row per frame, no gaps")
        XCTAssertEqual(lines[0], FrameTruth.csvColumns.joined(separator: ","))
        // Row numbers are sequential and frame indices are in delivery order.
        for i in 0..<12 {
            let fields = lines[i + 1].split(separator: ",", omittingEmptySubsequences: false)
            XCTAssertEqual(fields[0], "\(i + 1)")
            XCTAssertEqual(fields[1], "\(i)")
            XCTAssertEqual(fields[4], "1", "synthetic rows must be marked simulated")
        }
        XCTAssertEqual(bundle.log.rowsWritten, 12)
    }

    /// The cadence column has to survive the ONLY sequence the capture loop ever
    /// uses: stage a frame, annotate it (which flushes the buffer), then stage
    /// the next. Measuring the gap against the pending buffer left this column
    /// empty on every row, hiding exactly the 1 s pacing the field run must
    /// prove.
    func testShotToShotGapIsMeasuredAcrossFlushes() throws {
        let root = makeTempRoot()
        let bundle = makeLog(root: root)
        bundle.log.beginSession()
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 3200,
                                   targetSubCount: 5, nudgeTracking: false)
        for i in 0..<4 {
            let f = frame(index: i, at: Double(i))
            bundle.log.stageIfNeeded(frame: f, recipe: recipe, simulated: true)
            // Annotating flushes the row, so nothing is buffered for the next one.
            bundle.log.annotate(timestamp: f.timestamp, sessionFrameIndex: i,
                                starCount: 30, accepted: true)
        }
        bundle.log.endSession()
        bundle.writer.drainForTesting()

        let index = try XCTUnwrap(FrameTruth.csvColumns.firstIndex(of: "shotToShotSeconds"))
        let lines = rows(of: bundle.csv)
        XCTAssertEqual(lines.count, 5)
        let firstFields = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(String(firstFields[index]), "",
                       "the first frame of a session has no predecessor to measure against")
        for row in 2...4 {
            let fields = lines[row].split(separator: ",", omittingEmptySubsequences: false)
            XCTAssertEqual(String(fields[index]), "1.0000",
                           "row \(row) must carry the measured 1 s gap, not an empty cell")
        }
    }

    func testAnnotationLandsOnItsOwnRowWhenCaptureRacesAhead() {
        let root = makeTempRoot()
        let bundle = makeLog(root: root)
        bundle.log.beginSession()
        // Three frames staged before ANY verdict arrives (capture outruns the
        // stacker), then the middle one is annotated.
        let frames = (0..<3).map { frame(index: $0, at: Double($0)) }
        for f in frames {
            bundle.log.stage(FrameTruth(frameIndex: f.index, timestamp: f.timestamp,
                                        simulated: true), image: nil)
        }
        bundle.log.annotate(timestamp: frames[1].timestamp, phase: "capture",
                            starCount: 77, accepted: true)
        bundle.log.flushPending()
        bundle.writer.drainForTesting()

        let lines = rows(of: bundle.csv)
        XCTAssertEqual(lines.count, 4)
        // Frame 0 flushed unannotated ahead of frame 1 (order preserved), and
        // the star count belongs to frame 1 alone.
        XCTAssertFalse(lines[1].contains("77"))
        XCTAssertTrue(lines[2].contains(",77,"))
        XCTAssertFalse(lines[3].contains("77"))
    }

    // MARK: Frame dumps

    func testFrameDumpsWriteFirstJPEGAndPruneToTheCap() throws {
        let root = makeTempRoot()
        let bundle = makeLog(root: root, maxDumps: 4)
        bundle.log.beginSession()
        bundle.log.dumpEveryN = 2     // set after beginSession: it refreshes from defaults
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 3200,
                                   targetSubCount: 40, nudgeTracking: false)
        // Sensor-shaped source (one image, reused) so the ≤ 1400 px downscale
        // is actually exercised.
        let sensor = try XCTUnwrap(FrameTruthTests.grayImage(width: 1600, height: 900))
        for i in 0..<20 {
            let f = frame(index: i, at: Double(i), image: sensor)
            bundle.log.stageIfNeeded(frame: f, recipe: recipe, simulated: true)
            bundle.log.annotate(timestamp: f.timestamp, sessionFrameIndex: i,
                                starCount: 12, accepted: true)
        }
        bundle.log.endSession()
        bundle.writer.drainForTesting()

        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: bundle.frames.path)) ?? []
        let jpegs = files.filter { $0.hasSuffix(".jpg") }
        // 4 capped dumps + first.jpg, which the cap never prunes.
        XCTAssertEqual(jpegs.count, 5, "dumps: \(jpegs.sorted())")
        XCTAssertTrue(jpegs.contains(FrameEvidence.firstFrameName),
                      "the very first frame is always kept")
        XCTAssertTrue(files.contains("index.json"))

        // Dumps are bounded in pixels too — longest side ≤ 1400.
        let firstURL = bundle.frames.appendingPathComponent(FrameEvidence.firstFrameName)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(firstURL as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(decoded.width, decoded.height), FrameEvidence.dumpMaxSide)

        // index.json lists exactly the surviving dumps, with their truth fields.
        let data = try XCTUnwrap(try? Data(contentsOf:
            bundle.frames.appendingPathComponent("index.json")))
        let object = try? JSONSerialization.jsonObject(with: data)
        let json = try XCTUnwrap(object as? [String: Any])
        let entries = try XCTUnwrap(json["frames"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 4)
        for entry in entries {
            let file = entry["file"] as? String ?? ""
            XCTAssertTrue(jpegs.contains(file), "index must not reference a pruned file")
            XCTAssertNotNil(entry["actualExposureSeconds"])
            XCTAssertEqual(entry["starCount"] as? Int, 12,
                           "index entries carry the FINAL annotated truth")
        }
    }

    func testDisabledLedgerWritesNothing() {
        let root = makeTempRoot()
        let bundle = makeLog(root: root)
        bundle.log.isEnabled = false
        bundle.log.beginSession()
        let recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 800,
                                   targetSubCount: 5, nudgeTracking: false)
        bundle.log.stageIfNeeded(frame: frame(index: 0, at: 0), recipe: recipe, simulated: true)
        bundle.log.endSession()
        bundle.writer.drainForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.csv.path))
        XCTAssertEqual(bundle.log.rowsWritten, 0)
    }
}
