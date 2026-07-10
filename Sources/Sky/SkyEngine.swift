import Foundation

/// Pure-math ephemeris engine — USNO GMST + Meeus/Astronomical-Almanac low-precision series.
///
/// No network, no dependencies, fully deterministic. Accuracy: GMST ≈ 0.1 s, sun ≈ 0.01°,
/// moon ≈ 0.3° — far tighter than the gimbal's 0.15° open-loop impulse σ, and ample for
/// tonight-verdict logic, framing, and darkness-window planning.
///
/// Conventions (locked by `SkyComputing` in Models.swift):
/// - Sidereal time and RA in hours (0..24), all angles in degrees.
/// - Azimuth measured 0° = North, 90° = East.
public final class SkyEngine: SkyComputing {

    public init() {}

    // MARK: - Published constants

    /// Galactic center (Sgr A* region), J2000: RA 17h45.7m, Dec −29.01°.
    public static let galacticCore = EquatorialCoord(raHours: 17.0 + 45.7 / 60.0, decDeg: -29.01)

    /// Sun altitude at or below which astronomical darkness holds.
    public static let astronomicalDarkSunAltDeg: Double = -18.0

    /// Milky Way core altitude above which core shots are worth attempting.
    public static let coreUsefulAltDeg: Double = 10.0

    /// Tonight scans: 5-minute steps across the next 24 hours.
    static let scanStep: TimeInterval = 300
    static let scanCount = 288

    // MARK: - SkyComputing: sidereal time

    /// Greenwich Mean Sidereal Time in hours (0..24), USNO approximate formula:
    /// GMST = 18.697374558 + 24.06570982441908 · D, with D = days since J2000.0 (UT).
    public func greenwichMeanSiderealTime(date: Date) -> Double {
        let d = Self.julianDate(date) - 2451545.0
        return Self.wrap(18.697374558 + 24.06570982441908 * d, to: 24.0)
    }

    /// Local sidereal time in hours (0..24) for a longitude (+E).
    public func localSiderealTime(at location: GeoLocation, date: Date) -> Double {
        Self.wrap(greenwichMeanSiderealTime(date: date) + location.longitude / 15.0, to: 24.0)
    }

    // MARK: - SkyComputing: RA/Dec → Alt/Az

    /// Hour angle + spherical trig. Azimuth returned with 0 = N, 90 = E.
    public func altAz(of coord: EquatorialCoord, at location: GeoLocation, date: Date) -> HorizontalCoord {
        let lst = localSiderealTime(at: location, date: date)
        let ha = Self.rad(Self.wrap((lst - coord.raHours) * 15.0, to: 360.0))
        let phi = Self.rad(location.latitude)
        let dec = Self.rad(coord.decDeg)

        let sinAlt = sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(ha)
        let altDeg = Self.deg(asin(min(1.0, max(-1.0, sinAlt))))

        // atan2 form scaled by cos(dec) — no tan singularity at the celestial pole.
        // Raw result measures from South; rotate 180° to the 0 = N, 90 = E convention.
        let y = sin(ha) * cos(dec)
        let x = cos(ha) * sin(phi) * cos(dec) - sin(dec) * cos(phi)
        let azDeg = Self.wrap(Self.deg(atan2(y, x)) + 180.0, to: 360.0)

        return HorizontalCoord(altitudeDeg: altDeg, azimuthDeg: azDeg)
    }

    // MARK: - SkyComputing: sun

    /// Sun altitude in degrees (low-precision solar ecliptic → equatorial → alt/az).
    public func sunAltitude(at location: GeoLocation, date: Date) -> Double {
        let sun = Self.sunEcliptic(jd: Self.julianDate(date))
        let eq = Self.equatorial(eclipticLonDeg: sun.longitudeDeg, eclipticLatDeg: 0.0,
                                 obliquityDeg: sun.obliquityDeg)
        return altAz(of: eq, at: location, date: date).altitudeDeg
    }

    // MARK: - SkyComputing: moon

    /// Truncated lunar theory (Astronomical Almanac low-precision series) for position;
    /// illuminated fraction from sun–moon elongation; phase name from elongation octant.
    public func moonInfo(at location: GeoLocation, date: Date) -> MoonInfo {
        let jd = Self.julianDate(date)
        let moon = Self.moonEcliptic(jd: jd)
        let sun = Self.sunEcliptic(jd: jd)

        let eq = Self.equatorial(eclipticLonDeg: moon.lonDeg, eclipticLatDeg: moon.latDeg,
                                 obliquityDeg: sun.obliquityDeg)
        let position = altAz(of: eq, at: location, date: date)

        // Geocentric elongation ψ: cos ψ = cos β · cos(λm − λs).
        // Phase angle ≈ 180° − ψ, so illuminated fraction k = (1 − cos ψ) / 2.
        let cosPsi = cos(Self.rad(moon.latDeg)) * cos(Self.rad(moon.lonDeg - sun.longitudeDeg))
        let fraction = min(1.0, max(0.0, (1.0 - cosPsi) / 2.0))

        let elongationDeg = Self.wrap(moon.lonDeg - sun.longitudeDeg, to: 360.0)
        return MoonInfo(illuminatedFraction: fraction,
                        phaseName: Self.phaseName(elongationDeg: elongationDeg),
                        position: position)
    }

    // MARK: - SkyComputing: Milky Way core

    public func milkyWayCorePosition(at location: GeoLocation, date: Date) -> HorizontalCoord {
        altAz(of: Self.galacticCore, at: location, date: date)
    }

    /// True if, at any 5-minute step in the next 24 h, the galactic core sits above 10°
    /// while the sun is below −18° (astronomical darkness).
    public func coreVisibleTonight(at location: GeoLocation, from date: Date) -> Bool {
        for i in 0...Self.scanCount {
            let t = date.addingTimeInterval(Double(i) * Self.scanStep)
            guard sunAltitude(at: location, date: t) < Self.astronomicalDarkSunAltDeg else { continue }
            if milkyWayCorePosition(at: location, date: t).altitudeDeg > Self.coreUsefulAltDeg {
                return true
            }
        }
        return false
    }

    // MARK: - Darkness window

    /// First astronomical-darkness interval (sun < −18°) in the next 24 h, found by a
    /// 5-minute scan with linear interpolation at the threshold crossings (≈ sub-minute).
    /// `nil` when darkness never occurs (e.g. mid-summer above ~49° latitude).
    /// If it is already dark, the window starts at `date`; if darkness runs past the scan
    /// horizon, the window ends at `date + 24 h`.
    public func darknessWindow(at location: GeoLocation, from date: Date) -> (start: Date, end: Date)? {
        let threshold = Self.astronomicalDarkSunAltDeg
        var start: Date?
        var prevDate = date
        var prevAlt = sunAltitude(at: location, date: date)
        if prevAlt < threshold { start = date }

        for i in 1...Self.scanCount {
            let t = date.addingTimeInterval(Double(i) * Self.scanStep)
            let alt = sunAltitude(at: location, date: t)
            if start == nil, prevAlt >= threshold, alt < threshold {
                start = Self.interpolateCrossing(t0: prevDate, a0: prevAlt, t1: t, a1: alt,
                                                 threshold: threshold)
            } else if let s = start, prevAlt < threshold, alt >= threshold {
                let end = Self.interpolateCrossing(t0: prevDate, a0: prevAlt, t1: t, a1: alt,
                                                   threshold: threshold)
                return (start: s, end: end)
            }
            prevDate = t
            prevAlt = alt
        }
        if let s = start {
            return (start: s, end: date.addingTimeInterval(Double(Self.scanCount) * Self.scanStep))
        }
        return nil
    }

    // MARK: - SkyComputing: composed context

    public func skyContext(at location: GeoLocation, date: Date) -> SkyContext {
        let sunAlt = sunAltitude(at: location, date: date)
        return SkyContext(
            date: date,
            location: location,
            sunAltitudeDeg: sunAlt,
            isAstronomicalDark: sunAlt < Self.astronomicalDarkSunAltDeg,
            darknessWindow: darknessWindow(at: location, from: date),
            moon: moonInfo(at: location, date: date),
            milkyWayCore: milkyWayCorePosition(at: location, date: date),
            coreVisibleTonight: coreVisibleTonight(at: location, from: date),
            lstHours: localSiderealTime(at: location, date: date)
        )
    }

    // MARK: - Solar theory (low-precision, USNO/Meeus)

    struct SunEcliptic {
        let longitudeDeg: Double
        let obliquityDeg: Double
    }

    static func sunEcliptic(jd: Double) -> SunEcliptic {
        let d = jd - 2451545.0
        let g = rad(wrap(357.529 + 0.98560028 * d, to: 360.0))   // mean anomaly
        let q = wrap(280.459 + 0.98564736 * d, to: 360.0)        // mean longitude
        let lambda = wrap(q + 1.915 * sin(g) + 0.020 * sin(2.0 * g), to: 360.0)
        let obliquity = 23.439 - 0.00000036 * d
        return SunEcliptic(longitudeDeg: lambda, obliquityDeg: obliquity)
    }

    // MARK: - Lunar theory (truncated; error ≲ 0.3° in λ, 0.2° in β)

    struct MoonEcliptic {
        let lonDeg: Double
        let latDeg: Double
    }

    static func moonEcliptic(jd: Double) -> MoonEcliptic {
        let t = (jd - 2451545.0) / 36525.0
        func term(_ a: Double, _ b: Double) -> Double { sin(rad(a + b * t)) }

        var lon = 218.32 + 481267.881 * t
        lon += 6.29 * term(135.0, 477198.87)     // evection/anomaly principal term
        lon -= 1.27 * term(259.3, -413335.36)
        lon += 0.66 * term(235.7, 890534.22)
        lon += 0.21 * term(269.9, 954397.74)
        lon -= 0.19 * term(357.5, 35999.05)
        lon -= 0.11 * term(186.5, 966404.03)

        var lat = 5.13 * term(93.3, 483202.02)
        lat += 0.28 * term(228.2, 960400.89)
        lat -= 0.28 * term(318.3, 6003.15)
        lat -= 0.17 * term(217.6, -407332.21)

        return MoonEcliptic(lonDeg: wrap(lon, to: 360.0), latDeg: lat)
    }

    /// Phase name from sun→moon elongation in ecliptic longitude (0° = new, 180° = full).
    static func phaseName(elongationDeg: Double) -> String {
        switch wrap(elongationDeg, to: 360.0) {
        case ..<22.5:   return "New Moon"
        case ..<67.5:   return "Waxing Crescent"
        case ..<112.5:  return "First Quarter"
        case ..<157.5:  return "Waxing Gibbous"
        case ..<202.5:  return "Full Moon"
        case ..<247.5:  return "Waning Gibbous"
        case ..<292.5:  return "Last Quarter"
        case ..<337.5:  return "Waning Crescent"
        default:        return "New Moon"
        }
    }

    // MARK: - Coordinate transforms & helpers

    /// Ecliptic (λ, β) → equatorial, using atan2 forms free of tan singularities.
    static func equatorial(eclipticLonDeg: Double, eclipticLatDeg: Double,
                           obliquityDeg: Double) -> EquatorialCoord {
        let l = rad(eclipticLonDeg)
        let b = rad(eclipticLatDeg)
        let e = rad(obliquityDeg)
        let y = sin(l) * cos(e) * cos(b) - sin(b) * sin(e)
        let x = cos(l) * cos(b)
        let raHours = wrap(deg(atan2(y, x)) / 15.0, to: 24.0)
        let sinDec = sin(b) * cos(e) + cos(b) * sin(e) * sin(l)
        let decDeg = deg(asin(min(1.0, max(-1.0, sinDec))))
        return EquatorialCoord(raHours: raHours, decDeg: decDeg)
    }

    /// Julian Date (UT) from a `Date`. Unix epoch = JD 2440587.5.
    static func julianDate(_ date: Date) -> Double {
        2440587.5 + date.timeIntervalSince1970 / 86400.0
    }

    /// Linear interpolation of the instant a sampled quantity crosses `threshold`.
    static func interpolateCrossing(t0: Date, a0: Double, t1: Date, a1: Double,
                                    threshold: Double) -> Date {
        let span = t1.timeIntervalSince(t0)
        guard a1 != a0 else { return t0 }
        let fraction = (threshold - a0) / (a1 - a0)
        return t0.addingTimeInterval(fraction * span)
    }

    static func wrap(_ value: Double, to range: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: range)
        return r < 0 ? r + range : r
    }

    static func rad(_ degrees: Double) -> Double { degrees * .pi / 180.0 }
    static func deg(_ radians: Double) -> Double { radians * 180.0 / .pi }
}
