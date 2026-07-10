import XCTest
@testable import StarFlow

/// SkyEngine vs known ephemeris values. All epochs are fixed
/// `Date(timeIntervalSince1970:)` UTC instants — no Calendar, no time zones.
final class SkyEngineTests: XCTestCase {

    private let engine = SkyEngine()

    // Fixed epochs (UTC)
    private let meeusExample   = Date(timeIntervalSince1970: 545_011_200)    // 1987-04-10 00:00:00
    private let solsticeNoon   = Date(timeIntervalSince1970: 1_782_043_200)  // 2026-06-21 12:00:00
    private let solsticeMidnight = Date(timeIntervalSince1970: 1_782_000_000) // 2026-06-21 00:00:00
    private let fullMoon2026   = Date(timeIntervalSince1970: 1_772_539_200)  // 2026-03-03 12:00:00 (total lunar eclipse day)
    private let newMoon2026    = Date(timeIntervalSince1970: 1_771_329_600)  // 2026-02-17 12:00:00 (annular solar eclipse day)
    private let winterNight    = Date(timeIntervalSince1970: 1_768_003_200)  // 2026-01-10 00:00:00
    private let summerNight    = Date(timeIntervalSince1970: 1_783_641_600)  // 2026-07-10 00:00:00

    private let london = GeoLocation(latitude: 51.5074, longitude: -0.1278)
    private let denver = GeoLocation(latitude: 40.0, longitude: -105.0)

    /// Polaris, J2000: RA 2h31m49s, Dec +89°15.8′.
    private let polaris = EquatorialCoord(raHours: 2.5303, decDeg: 89.264)

    // MARK: GMST

    /// Meeus "Astronomical Algorithms" example 12.a:
    /// 1987 April 10, 0h UT → GMST 13h10m46.3668s = 13.1795463 h.
    func testGMSTMatchesMeeusExample() {
        let gmst = engine.greenwichMeanSiderealTime(date: meeusExample)
        XCTAssertEqual(gmst, 13.1795, accuracy: 0.01)
    }

    func testGMSTStaysInRange() {
        for offsetDays in [0.0, 100.0, 1000.0, 10_000.0, -5000.0] {
            let gmst = engine.greenwichMeanSiderealTime(
                date: meeusExample.addingTimeInterval(offsetDays * 86400))
            XCTAssertGreaterThanOrEqual(gmst, 0.0)
            XCTAssertLessThan(gmst, 24.0)
        }
    }

    // MARK: Sun

    /// London on the June solstice: sun well up at local noon, well down at local midnight.
    func testSunAltitudeSignDayAndNight() {
        XCTAssertGreaterThan(engine.sunAltitude(at: london, date: solsticeNoon), 30.0)
        XCTAssertLessThan(engine.sunAltitude(at: london, date: solsticeMidnight), -5.0)
    }

    // MARK: Moon

    /// 2026-03-03 hosts a total lunar eclipse (full moon by definition);
    /// 2026-02-17 hosts an annular solar eclipse (new moon by definition).
    func testMoonIlluminationAtKnownFullAndNewMoons() {
        let full = engine.moonInfo(at: denver, date: fullMoon2026)
        XCTAssertEqual(full.illuminatedFraction, 1.0, accuracy: 0.1)
        XCTAssertEqual(full.phaseName, "Full Moon")

        let new = engine.moonInfo(at: denver, date: newMoon2026)
        XCTAssertEqual(new.illuminatedFraction, 0.0, accuracy: 0.1)
        XCTAssertEqual(new.phaseName, "New Moon")
    }

    func testMoonIlluminationStaysNormalized() {
        for dayOffset in stride(from: 0.0, through: 30.0, by: 1.0) {
            let info = engine.moonInfo(at: denver, date: winterNight.addingTimeInterval(dayOffset * 86400))
            XCTAssertGreaterThanOrEqual(info.illuminatedFraction, 0.0)
            XCTAssertLessThanOrEqual(info.illuminatedFraction, 1.0)
        }
    }

    // MARK: Alt/Az

    /// Polaris altitude ≈ observer latitude (within its 0.74° radius around the pole),
    /// azimuth ≈ due north — checks both the trig and the 0=N/90=E convention.
    func testPolarisAltitudeApproximatesLatitude() {
        for date in [summerNight, winterNight] {
            let pos = engine.altAz(of: polaris, at: denver, date: date)
            XCTAssertEqual(pos.altitudeDeg, denver.latitude, accuracy: 1.5)
            let northError = min(pos.azimuthDeg, 360.0 - pos.azimuthDeg)
            XCTAssertLessThan(northError, 3.0, "Polaris azimuth should hug north, got \(pos.azimuthDeg)")
        }
    }

    // MARK: Milky Way core season

    /// Mid-north latitude: core season peaks in summer; in early January the core only
    /// clears 10° during daylight, so it is not visible tonight.
    func testCoreVisibilitySummerVsWinter() {
        XCTAssertTrue(engine.coreVisibleTonight(at: denver, from: summerNight))
        XCTAssertFalse(engine.coreVisibleTonight(at: denver, from: winterNight))
    }

    func testSkyContextCarriesCoreVerdict() {
        let summer = engine.skyContext(at: denver, date: summerNight)
        XCTAssertTrue(summer.coreVisibleTonight)
        let winter = engine.skyContext(at: denver, date: winterNight)
        XCTAssertFalse(winter.coreVisibleTonight)
    }

    // MARK: Darkness window

    /// London on the June solstice: the sun never dips below −18° — no astronomical
    /// darkness at all (honest verdict the Tonight screen must surface).
    func testNoDarknessWindowLondonMidsummer() {
        XCTAssertNil(engine.darknessWindow(at: london, from: solsticeMidnight))
    }

    /// Denver, July 10: astronomical darkness ≈ 04:30–09:41 UT (22:30–03:41 local).
    func testDarknessWindowDenverJuly() {
        guard let window = engine.darknessWindow(at: denver, from: summerNight) else {
            return XCTFail("Expected a darkness window at lat 40 in July")
        }
        XCTAssertGreaterThan(window.start, summerNight)
        XCTAssertGreaterThan(window.end, window.start)
        let hours = window.end.timeIntervalSince(window.start) / 3600.0
        XCTAssertGreaterThan(hours, 3.0)
        XCTAssertLessThan(hours, 8.0)
        // Sun must actually be dark inside the window.
        let mid = window.start.addingTimeInterval(window.end.timeIntervalSince(window.start) / 2)
        XCTAssertLessThan(engine.sunAltitude(at: denver, date: mid), -18.0)
    }

    // MARK: Composed context

    func testSkyContextIsSelfConsistent() {
        let ctx = engine.skyContext(at: denver, date: summerNight)
        XCTAssertEqual(ctx.sunAltitudeDeg, engine.sunAltitude(at: denver, date: summerNight),
                       accuracy: 1e-9)
        XCTAssertEqual(ctx.isAstronomicalDark, ctx.sunAltitudeDeg < -18.0)
        XCTAssertGreaterThanOrEqual(ctx.lstHours, 0.0)
        XCTAssertLessThan(ctx.lstHours, 24.0)
        let core = engine.milkyWayCorePosition(at: denver, date: summerNight)
        XCTAssertEqual(ctx.milkyWayCore.altitudeDeg, core.altitudeDeg, accuracy: 1e-9)
        XCTAssertEqual(ctx.milkyWayCore.azimuthDeg, core.azimuthDeg, accuracy: 1e-9)
    }
}
