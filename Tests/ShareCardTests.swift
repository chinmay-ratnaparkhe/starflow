import XCTest
import CoreGraphics
@testable import StarFlow

/// Share-card pure math (feature 9): aspect fitting, export pixel sizes, and
/// stat formatting. The honesty contract is the heart of these tests — the
/// card renders ONLY what the `SessionRecord` holds: no sky verdict, no
/// calibration line, no city unless the session really measured/stored them.
final class ShareCardTests: XCTestCase {

    // MARK: - Fixtures

    private func makeRecord(integrationSeconds: Double = 754,
                            subsAccepted: Int = 300,
                            skyCondition: SkyCondition? = nil,
                            calibrationStars: Int? = nil,
                            locationCity: String? = nil) -> SessionRecord {
        SessionRecord(id: UUID(),
                      date: Date(timeIntervalSince1970: 1_790_000_000),
                      shotID: "milkyway",
                      shotName: "Milky Way Stack",
                      integrationSeconds: integrationSeconds,
                      subsAccepted: subsAccepted,
                      subsRejected: 12,
                      nudges: 7,
                      flapsRecovered: 1,
                      targetSubCount: 300,
                      skyCondition: skyCondition,
                      calibrationStars: calibrationStars,
                      locationCity: locationCity)
    }

    // MARK: - Export formats

    func testExportPixelSizesAreExact() {
        XCTAssertEqual(ShareCardFormat.story.pixelSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ShareCardFormat.square.pixelSize, CGSize(width: 2048, height: 2048))
    }

    func testDesignScaleIsRelativeTo1080Wide() {
        XCTAssertEqual(ShareCardFormat.story.designScale, 1.0, accuracy: 1e-9)
        XCTAssertEqual(ShareCardFormat.square.designScale, 2048.0 / 1080.0, accuracy: 1e-9)
    }

    // MARK: - Aspect fitting

    func testAspectFitLandscapeLimitedByWidth() {
        let fitted = ShareCardLayout.aspectFit(image: CGSize(width: 4000, height: 3000),
                                               in: CGSize(width: 936, height: 960))
        XCTAssertEqual(fitted.width, 936, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 702, accuracy: 0.001)
    }

    func testAspectFitPortraitLimitedByHeight() {
        let fitted = ShareCardLayout.aspectFit(image: CGSize(width: 3000, height: 4000),
                                               in: CGSize(width: 936, height: 960))
        XCTAssertEqual(fitted.height, 960, accuracy: 0.001)
        XCTAssertEqual(fitted.width, 720, accuracy: 0.001)
    }

    func testAspectFitPreservesRatioWhenUpscalingSmallThumbnails() {
        // The logbook stores a ≤256 px thumbnail — it upscales to fill the
        // card frame, ratio preserved exactly.
        let fitted = ShareCardLayout.aspectFit(image: CGSize(width: 256, height: 192),
                                               in: CGSize(width: 936, height: 960))
        XCTAssertEqual(fitted.width / fitted.height, 256.0 / 192.0, accuracy: 1e-9)
        XCTAssertEqual(fitted.width, 936, accuracy: 0.001)
    }

    func testAspectFitDegenerateInputReturnsZero() {
        XCTAssertEqual(ShareCardLayout.aspectFit(image: .zero,
                                                 in: CGSize(width: 100, height: 100)), .zero)
        XCTAssertEqual(ShareCardLayout.aspectFit(image: CGSize(width: 10, height: 10),
                                                 in: .zero), .zero)
    }

    func testImageBoundsFitInsideCardContentArea() {
        for format in ShareCardFormat.allCases {
            let card = format.pixelSize
            let bounds = ShareCardLayout.imageBounds(cardSize: card)
            let scale = format.designScale
            let expectedWidth = card.width - 2 * ShareCardLayout.horizontalPadding * scale
            XCTAssertEqual(bounds.width, expectedWidth, accuracy: 0.001, "\(format)")
            XCTAssertLessThan(bounds.height, card.height, "\(format)")
            XCTAssertGreaterThan(bounds.height, 0, "\(format)")
        }
    }

    func testStoryGivesThePhotoMoreVerticalShareThanSquare() {
        let story = ShareCardLayout.imageBounds(cardSize: ShareCardFormat.story.pixelSize)
        let square = ShareCardLayout.imageBounds(cardSize: ShareCardFormat.square.pixelSize)
        XCTAssertEqual(story.height / 1920, 0.50, accuracy: 1e-9)
        XCTAssertEqual(square.height / 2048, 0.42, accuracy: 1e-9)
    }

    // MARK: - Stats strip (only what the record holds)

    func testStripAlwaysCarriesIntegrationAndSubs() {
        let strip = ShareCardStats.strip(for: makeRecord())
        XCTAssertEqual(strip.count, 2)
        XCTAssertEqual(strip[0], ShareCardStats.Stat(value: "12m 34s", label: "integrated"))
        XCTAssertEqual(strip[1], ShareCardStats.Stat(value: "300", label: "subs stacked"))
    }

    func testStripIncludesSkyOnlyWhenMeasured() {
        let graded = ShareCardStats.strip(for: makeRecord(skyCondition: .clear))
        XCTAssertEqual(graded.count, 3)
        XCTAssertEqual(graded[2], ShareCardStats.Stat(value: "Clear", label: "sky"))

        // Ungraded (nil) and hollow (.unknown) records show NO sky stat.
        XCTAssertEqual(ShareCardStats.strip(for: makeRecord(skyCondition: nil)).count, 2)
        XCTAssertEqual(ShareCardStats.strip(for: makeRecord(skyCondition: .unknown)).count, 2)
    }

    func testStripSkyUsesSentenceCase() {
        let strip = ShareCardStats.strip(for: makeRecord(skyCondition: .overexposed))
        XCTAssertEqual(strip[2].value, "Too bright")
    }

    // MARK: - Calibration line (never invented)

    func testCalibrationLineRendersOnlyFromARealFit() {
        XCTAssertNil(ShareCardStats.calibrationLine(for: makeRecord(calibrationStars: nil)))
        XCTAssertNil(ShareCardStats.calibrationLine(for: makeRecord(calibrationStars: 0)))
        XCTAssertEqual(ShareCardStats.calibrationLine(for: makeRecord(calibrationStars: 12)),
                       "Calibrated against 12 stars")
        XCTAssertEqual(ShareCardStats.calibrationLine(for: makeRecord(calibrationStars: 1)),
                       "Calibrated against 1 star")
    }

    // MARK: - Date / location line

    func testDateLineAppendsCityOnlyWhenStoredAndToggledOn() {
        let noCity = makeRecord(locationCity: nil)
        let withCity = makeRecord(locationCity: "Cupertino")

        let base = ShareCardStats.dateLine(for: noCity, includeLocation: true)
        XCTAssertFalse(base.contains("·"))

        // City stored + toggle on → appended after the date.
        let shown = ShareCardStats.dateLine(for: withCity, includeLocation: true)
        XCTAssertTrue(shown.hasPrefix(base))
        XCTAssertTrue(shown.hasSuffix(" · Cupertino"))

        // Toggle off → identical to a record with no city at all.
        XCTAssertEqual(ShareCardStats.dateLine(for: withCity, includeLocation: false), base)
    }

    func testDateLineIgnoresEmptyCity() {
        let record = makeRecord(locationCity: "")
        XCTAssertFalse(ShareCardStats.dateLine(for: record, includeLocation: true).contains("·"))
    }

    // MARK: - Record round-trip (appended optional fields stay optional)

    func testRecordDecodesLegacyJSONWithoutNewFields() throws {
        // A record encoded before calibrationStars/locationCity/simulatedCapture
        // existed must decode with all three nil.
        let legacy = makeRecord()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "calibrationStars")
        json.removeValue(forKey: "locationCity")
        json.removeValue(forKey: "simulatedCapture")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: data)
        XCTAssertNil(decoded.calibrationStars)
        XCTAssertNil(decoded.locationCity)
        XCTAssertNil(decoded.simulatedCapture)
        XCTAssertEqual(decoded.subsAccepted, legacy.subsAccepted)
    }
}
