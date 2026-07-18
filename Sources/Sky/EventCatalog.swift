import Foundation

// MARK: - Rarity tier

/// How often an event of this kind comes around. Drives the badge and the score base.
public enum RarityTier: Int, Comparable, Sendable {
    case annual = 0       // meteor-shower peaks, supermoons, new-moon core nights
    case multiYear = 1    // lunar eclipses, distant/partial solar eclipses
    case decade = 2       // total solar eclipses

    public static func < (lhs: RarityTier, rhs: RarityTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .annual: return "Annual"
        case .multiYear: return "Multi-year"
        case .decade: return "Once a decade"
        }
    }
}

// MARK: - Event types

/// Local visibility of an event, computed from the ephemeris for the user's coordinates.
public struct EventVisibility: Equatable, Sendable {
    /// Whether the event is usefully observable from the query location.
    public var visible: Bool
    /// Altitude (deg) of the relevant body at the best/mid time: shower radiant at
    /// ~2 am, the Moon at mid-eclipse, the Sun at mid-eclipse, the galactic core at
    /// its darkness-window peak.
    public var altitudeDeg: Double
    /// Best local moment to look (approximate — local *solar* time, not the civil clock).
    public var bestTime: Date?
    /// Honest one-phrase visibility summary ("radiant 52° up at 2 am").
    public var note: String

    public init(visible: Bool, altitudeDeg: Double, bestTime: Date?, note: String) {
        self.visible = visible
        self.altitudeDeg = altitudeDeg
        self.bestTime = bestTime
        self.note = note
    }
}

/// One upcoming sky event with its locally computed visibility and moon interference.
public struct SkyEvent: Identifiable, Sendable {

    public enum Kind: String, Equatable, Sendable {
        case meteorShower
        case lunarEclipse
        case solarEclipse
        case supermoon
        case milkyWayNewMoon
    }

    public let id: String
    public let kind: Kind
    public let name: String
    /// Peak/mid instant (UT). For meteor showers this is 12:00 UT on the peak date —
    /// the observing night is the evening of that date into the next morning.
    public let date: Date
    public let tier: RarityTier
    /// Facts line: parent body + ZHR, eclipse type + region summary, and so on.
    public let detail: String
    public let zhr: Int?
    public let radiant: EquatorialCoord?
    public let visibility: EventVisibility
    /// Moon illuminated fraction at the best viewing time (moonInfo).
    public let moonFraction: Double
    public let moonUpAtBest: Bool
    /// Shot mode this event maps to ("meteors", "lunar", "milkyway"), when one exists.
    public let matchingShotModeID: String?
    /// Viewing advice for the detail sheet — honest, no promises.
    public let advice: String

    /// Whether moonlight actually hurts this event (it never hurts the Moon itself,
    /// and a solar eclipse happens at new moon by definition).
    public var moonSensitive: Bool {
        kind == .meteorShower || kind == .milkyWayNewMoon
    }

    public init(id: String, kind: Kind, name: String, date: Date, tier: RarityTier,
                detail: String, zhr: Int?, radiant: EquatorialCoord?,
                visibility: EventVisibility, moonFraction: Double, moonUpAtBest: Bool,
                matchingShotModeID: String?, advice: String) {
        self.id = id; self.kind = kind; self.name = name; self.date = date
        self.tier = tier; self.detail = detail; self.zhr = zhr; self.radiant = radiant
        self.visibility = visibility; self.moonFraction = moonFraction
        self.moonUpAtBest = moonUpAtBest; self.matchingShotModeID = matchingShotModeID
        self.advice = advice
    }
}

// MARK: - EventCatalog

/// Offline event calendar. Pure math + embedded clean-room facts, fully deterministic:
/// - Annual meteor showers (12 majors): peak dates 2026–2028 explicit, recurring
///   month/day otherwise. Dates, ZHRs, radiants and parent bodies are public
///   astronomical facts.
/// - Lunar and solar eclipses 2026–2030 with approximate mid-eclipse instants and a
///   region summary.
/// - Supermoons: computed, not stored — full-moon instants from the phase search with
///   a truncated Meeus distance series, flagged when the Moon is within ~361,000 km.
/// - New-moon Milky Way nights: computed from SkyEngine's core-season logic.
///
/// No network, no third-party data. Local visibility (radiant/eclipse altitude) comes
/// from SkyEngine; moon interference from moonInfo.
public struct EventCatalog {

    private let engine = SkyEngine()

    public init() {}

    // MARK: Query

    /// All catalog events with peaks inside `[from, from + days]`, sorted by date,
    /// each carrying visibility and moon interference computed for `location`.
    public func events(from: Date, days: Int, location: GeoLocation) -> [SkyEvent] {
        let clampedDays = min(max(days, 1), 400)
        let end = from.addingTimeInterval(Double(clampedDays) * 86_400.0)
        var result: [SkyEvent] = []
        result += showerEvents(from: from, to: end, location: location)
        result += eclipseEvents(from: from, to: end, location: location)
        result += supermoonEvents(from: from, to: end, location: location)
        result += milkyWayNewMoonEvents(from: from, to: end, location: location)
        return result.sorted { $0.date < $1.date }
    }

    // MARK: Meteor showers

    struct ShowerSpec {
        let id: String
        let name: String
        let activeRange: String
        let defaultPeak: (month: Int, day: Int)
        let peakByYear: [Int: (month: Int, day: Int)]
        let zhr: Int
        let radiant: EquatorialCoord
        let parent: String
    }

    /// The 12 major annual showers. ZHR is the idealized dark-sky zenith rate — real
    /// counts are always lower, and the shot-mode copy says so.
    static let showers: [ShowerSpec] = [
        ShowerSpec(id: "quadrantids", name: "Quadrantids", activeRange: "Dec 28 – Jan 12",
                   defaultPeak: (1, 3), peakByYear: [2026: (1, 3), 2027: (1, 3), 2028: (1, 4)],
                   zhr: 110, radiant: EquatorialCoord(raHours: 15.3, decDeg: 49.5),
                   parent: "asteroid 2003 EH1"),
        ShowerSpec(id: "lyrids", name: "Lyrids", activeRange: "Apr 14 – 30",
                   defaultPeak: (4, 22), peakByYear: [2026: (4, 22), 2027: (4, 22), 2028: (4, 22)],
                   zhr: 18, radiant: EquatorialCoord(raHours: 18.1, decDeg: 34.0),
                   parent: "comet C/1861 G1 (Thatcher)"),
        ShowerSpec(id: "etaaquariids", name: "Eta Aquariids", activeRange: "Apr 19 – May 28",
                   defaultPeak: (5, 5), peakByYear: [2026: (5, 5), 2027: (5, 6), 2028: (5, 5)],
                   zhr: 50, radiant: EquatorialCoord(raHours: 22.5, decDeg: -1.0),
                   parent: "comet 1P/Halley"),
        ShowerSpec(id: "deltaaquariids", name: "Southern Delta Aquariids", activeRange: "Jul 12 – Aug 23",
                   defaultPeak: (7, 30), peakByYear: [:],
                   zhr: 25, radiant: EquatorialCoord(raHours: 22.7, decDeg: -16.0),
                   parent: "comet 96P/Machholz"),
        ShowerSpec(id: "perseids", name: "Perseids", activeRange: "Jul 17 – Aug 24",
                   defaultPeak: (8, 12), peakByYear: [2026: (8, 12), 2027: (8, 13), 2028: (8, 12)],
                   zhr: 100, radiant: EquatorialCoord(raHours: 3.1, decDeg: 58.0),
                   parent: "comet 109P/Swift–Tuttle"),
        ShowerSpec(id: "draconids", name: "Draconids", activeRange: "Oct 6 – 10",
                   defaultPeak: (10, 8), peakByYear: [:],
                   zhr: 10, radiant: EquatorialCoord(raHours: 17.5, decDeg: 54.0),
                   parent: "comet 21P/Giacobini–Zinner"),
        ShowerSpec(id: "orionids", name: "Orionids", activeRange: "Oct 2 – Nov 7",
                   defaultPeak: (10, 21), peakByYear: [:],
                   zhr: 20, radiant: EquatorialCoord(raHours: 6.3, decDeg: 16.0),
                   parent: "comet 1P/Halley"),
        ShowerSpec(id: "southerntaurids", name: "Southern Taurids", activeRange: "Sep 10 – Nov 20",
                   defaultPeak: (11, 5), peakByYear: [:],
                   zhr: 5, radiant: EquatorialCoord(raHours: 3.5, decDeg: 13.0),
                   parent: "comet 2P/Encke"),
        ShowerSpec(id: "northerntaurids", name: "Northern Taurids", activeRange: "Oct 20 – Dec 10",
                   defaultPeak: (11, 12), peakByYear: [:],
                   zhr: 5, radiant: EquatorialCoord(raHours: 3.9, decDeg: 22.0),
                   parent: "comet 2P/Encke"),
        ShowerSpec(id: "leonids", name: "Leonids", activeRange: "Nov 6 – 30",
                   defaultPeak: (11, 17), peakByYear: [2026: (11, 17), 2027: (11, 18), 2028: (11, 17)],
                   zhr: 15, radiant: EquatorialCoord(raHours: 10.1, decDeg: 22.0),
                   parent: "comet 55P/Tempel–Tuttle"),
        ShowerSpec(id: "geminids", name: "Geminids", activeRange: "Dec 4 – 17",
                   defaultPeak: (12, 13), peakByYear: [2026: (12, 13), 2027: (12, 14), 2028: (12, 13)],
                   zhr: 150, radiant: EquatorialCoord(raHours: 7.5, decDeg: 32.0),
                   parent: "asteroid 3200 Phaethon"),
        ShowerSpec(id: "ursids", name: "Ursids", activeRange: "Dec 17 – 26",
                   defaultPeak: (12, 22), peakByYear: [:],
                   zhr: 10, radiant: EquatorialCoord(raHours: 14.5, decDeg: 76.0),
                   parent: "comet 8P/Tuttle"),
    ]

    private func showerEvents(from: Date, to end: Date, location: GeoLocation) -> [SkyEvent] {
        let firstYear = Self.utc.component(.year, from: from)
        let lastYear = Self.utc.component(.year, from: end)
        var events: [SkyEvent] = []
        for spec in Self.showers {
            for year in (firstYear - 1)...(lastYear + 1) {
                let peak = spec.peakByYear[year] ?? spec.defaultPeak
                let peakDate = Self.utcDate(year, peak.month, peak.day, 12, 0)
                guard peakDate >= from, peakDate <= end else { continue }
                events.append(showerEvent(spec: spec, year: year, peakDate: peakDate,
                                          location: location))
            }
        }
        return events
    }

    private func showerEvent(spec: ShowerSpec, year: Int, peakDate: Date,
                             location: GeoLocation) -> SkyEvent {
        // Best look ≈ 2 am local solar time the morning after the peak evening —
        // after midnight the observer's hemisphere turns to face the stream head-on.
        let best = Self.solarTimeDate(onNightOf: peakDate, hour: 26.0,
                                      longitude: location.longitude)
        let alt = engine.altAz(of: spec.radiant, at: location, date: best).altitudeDeg
        let visible = alt > 10.0
        let note: String
        if alt <= 0 {
            note = "radiant stays below your horizon — few meteors reach your sky"
        } else if visible {
            note = "radiant \(Int(alt.rounded()))° up at 2 am"
        } else {
            note = "radiant only \(Int(alt.rounded()))° up at 2 am — expect few meteors"
        }
        let moon = engine.moonInfo(at: location, date: best)
        return SkyEvent(
            id: "shower.\(spec.id).\(year)",
            kind: .meteorShower,
            name: spec.name,
            date: peakDate,
            tier: .annual,
            detail: "Parent body \(spec.parent) · up to ~\(spec.zhr)/hour under ideal dark "
                + "skies (real counts run lower) · active \(spec.activeRange)",
            zhr: spec.zhr,
            radiant: spec.radiant,
            visibility: EventVisibility(visible: visible, altitudeDeg: alt,
                                        bestTime: best, note: note),
            moonFraction: moon.illuminatedFraction,
            moonUpAtBest: moon.position.altitudeDeg > 0,
            matchingShotModeID: "meteors",
            advice: "Frame 30–45° away from the radiant and stay past midnight if you can "
                + "— rates roughly double. Most frames catch empty sky; that's normal, not "
                + "failure. Rates fall off hard a night either side of the peak.")
    }

    // MARK: Eclipses 2026–2030

    struct EclipseSpec {
        let id: String          // "yyyy-MM-dd" of the mid-eclipse UT date
        let lunar: Bool
        let kindName: String
        let tier: RarityTier
        let mid: Date           // approximate mid-eclipse instant, UT
        let regions: String
    }

    /// Umbral lunar eclipses and central/partial solar eclipses 2026–2030.
    /// Mid times are approximate (±minutes) — plenty for altitude gating.
    static let eclipses: [EclipseSpec] = [
        EclipseSpec(id: "2026-02-17", lunar: false, kindName: "Annular solar eclipse",
                    tier: .multiYear, mid: utcDate(2026, 2, 17, 12, 12),
                    regions: "Antarctica, with partial phases from the far southern hemisphere"),
        EclipseSpec(id: "2026-03-03", lunar: true, kindName: "Total lunar eclipse",
                    tier: .multiYear, mid: utcDate(2026, 3, 3, 11, 34),
                    regions: "East Asia, Australia, the Pacific and the Americas"),
        EclipseSpec(id: "2026-08-12", lunar: false, kindName: "Total solar eclipse",
                    tier: .decade, mid: utcDate(2026, 8, 12, 17, 46),
                    regions: "the Arctic, Greenland, Iceland and northern Spain"),
        EclipseSpec(id: "2026-08-28", lunar: true, kindName: "Partial lunar eclipse",
                    tier: .multiYear, mid: utcDate(2026, 8, 28, 4, 13),
                    regions: "the Americas, Europe and Africa"),
        EclipseSpec(id: "2027-02-06", lunar: false, kindName: "Annular solar eclipse",
                    tier: .multiYear, mid: utcDate(2027, 2, 6, 16, 0),
                    regions: "southern South America and the South Atlantic"),
        EclipseSpec(id: "2027-08-02", lunar: false, kindName: "Total solar eclipse",
                    tier: .decade, mid: utcDate(2027, 8, 2, 10, 7),
                    regions: "southern Spain, North Africa, Egypt and the Arabian Peninsula"),
        EclipseSpec(id: "2028-01-12", lunar: true, kindName: "Partial lunar eclipse",
                    tier: .multiYear, mid: utcDate(2028, 1, 12, 4, 13),
                    regions: "the Americas and western Europe"),
        EclipseSpec(id: "2028-01-26", lunar: false, kindName: "Annular solar eclipse",
                    tier: .multiYear, mid: utcDate(2028, 1, 26, 15, 8),
                    regions: "Ecuador, Peru, Brazil and Iberia toward sunset"),
        EclipseSpec(id: "2028-07-06", lunar: true, kindName: "Partial lunar eclipse",
                    tier: .multiYear, mid: utcDate(2028, 7, 6, 18, 20),
                    regions: "Europe, Africa, Asia and Australia"),
        EclipseSpec(id: "2028-07-22", lunar: false, kindName: "Total solar eclipse",
                    tier: .decade, mid: utcDate(2028, 7, 22, 2, 56),
                    regions: "Australia (Kimberley to Sydney) and southern New Zealand"),
        EclipseSpec(id: "2028-12-31", lunar: true, kindName: "Total lunar eclipse",
                    tier: .multiYear, mid: utcDate(2028, 12, 31, 16, 52),
                    regions: "Europe, Africa, Asia and Australia"),
        EclipseSpec(id: "2029-01-14", lunar: false, kindName: "Partial solar eclipse",
                    tier: .multiYear, mid: utcDate(2029, 1, 14, 17, 13),
                    regions: "North and Central America"),
        EclipseSpec(id: "2029-06-26", lunar: true, kindName: "Total lunar eclipse",
                    tier: .multiYear, mid: utcDate(2029, 6, 26, 3, 22),
                    regions: "the Americas, Europe, Africa and the Middle East"),
        EclipseSpec(id: "2029-12-20", lunar: true, kindName: "Total lunar eclipse",
                    tier: .multiYear, mid: utcDate(2029, 12, 20, 22, 42),
                    regions: "the Americas, Europe, Africa and Asia"),
        EclipseSpec(id: "2030-06-01", lunar: false, kindName: "Annular solar eclipse",
                    tier: .multiYear, mid: utcDate(2030, 6, 1, 6, 28),
                    regions: "North Africa, the Mediterranean, Central Asia and Japan"),
        EclipseSpec(id: "2030-06-15", lunar: true, kindName: "Partial lunar eclipse",
                    tier: .multiYear, mid: utcDate(2030, 6, 15, 18, 33),
                    regions: "Europe, Africa, Asia and Australia"),
        EclipseSpec(id: "2030-11-25", lunar: false, kindName: "Total solar eclipse",
                    tier: .decade, mid: utcDate(2030, 11, 25, 6, 50),
                    regions: "southern Africa, the Indian Ocean and southeastern Australia"),
    ]

    private func eclipseEvents(from: Date, to end: Date, location: GeoLocation) -> [SkyEvent] {
        Self.eclipses
            .filter { $0.mid >= from && $0.mid <= end }
            .map { spec in
                spec.lunar
                    ? lunarEclipseEvent(spec: spec, location: location)
                    : solarEclipseEvent(spec: spec, location: location)
            }
    }

    private func lunarEclipseEvent(spec: EclipseSpec, location: GeoLocation) -> SkyEvent {
        // A lunar eclipse is visible from the whole night side: the Moon above your
        // horizon at mid-eclipse IS the visibility test.
        let moon = engine.moonInfo(at: location, date: spec.mid)
        let alt = moon.position.altitudeDeg
        let visible = alt > 0
        let note = visible
            ? "Moon \(Int(alt.rounded()))° up at mid-eclipse from your location"
            : "the Moon is below your horizon at mid-eclipse — not visible from your location"
        return SkyEvent(
            id: "eclipse.lunar.\(spec.id)",
            kind: .lunarEclipse,
            name: spec.kindName,
            date: spec.mid,
            tier: spec.tier,
            detail: "Visible from \(spec.regions). Mid-eclipse time is approximate.",
            zhr: nil, radiant: nil,
            visibility: EventVisibility(visible: visible, altitudeDeg: alt,
                                        bestTime: spec.mid, note: note),
            moonFraction: moon.illuminatedFraction,
            moonUpAtBest: visible,
            matchingShotModeID: "lunar",
            advice: "No filter needed — an eclipsed Moon is dim and safe to shoot. Lunar "
                + "Detail's short stacked exposures handle the partial phases; totality "
                + "glows deep red and asks for nothing special beyond a steady mount.")
    }

    private func solarEclipseEvent(spec: EclipseSpec, location: GeoLocation) -> SkyEvent {
        // Sun-up is necessary but NOT sufficient: the shadow path decides what you see.
        // The copy says so instead of pretending we can compute the path.
        let sunAlt = engine.sunAltitude(at: location, date: spec.mid)
        let sunUp = sunAlt > 0
        let note = sunUp
            ? "the Sun is up for you at mid-eclipse, but the shadow track decides what "
                + "you see — verify the path before planning"
            : "happens while the Sun is below your horizon — not visible from your location"
        return SkyEvent(
            id: "eclipse.solar.\(spec.id)",
            kind: .solarEclipse,
            name: spec.kindName,
            date: spec.mid,
            tier: spec.tier,
            detail: "Path crosses \(spec.regions). Mid-eclipse time is approximate.",
            zhr: nil, radiant: nil,
            visibility: EventVisibility(visible: sunUp, altitudeDeg: sunAlt,
                                        bestTime: spec.mid, note: note),
            moonFraction: 0.0,      // new moon by definition
            moonUpAtBest: false,
            matchingShotModeID: nil,
            advice: "Never look at or aim the camera at the Sun without a certified solar "
                + "filter — it destroys eyes and sensors alike. StarFlow has no solar mode; "
                + "use proper eclipse glasses and enjoy this one live.")
    }

    // MARK: Supermoons (computed, not stored)

    /// Perigee threshold for the supermoon flag (~Espenak's 361,524 km, rounded).
    static let supermoonDistanceKm: Double = 361_000.0

    private func supermoonEvents(from: Date, to end: Date, location: GeoLocation) -> [SkyEvent] {
        Self.phaseInstants(targetElongationDeg: 180.0, from: from, to: end).compactMap { instant in
            let distance = Self.moonDistanceKm(jd: SkyEngine.julianDate(instant))
            guard distance <= Self.supermoonDistanceKm else { return nil }
            // Late evening (~22:00 local solar) on the night holding the full-moon instant.
            let evening = Self.solarTimeDate(onNightOf: instant, hour: 22.0,
                                             longitude: location.longitude)
            let moon = engine.moonInfo(at: location, date: evening)
            let alt = moon.position.altitudeDeg
            let visible = alt > 0
            let note = visible
                ? "full moon \(Int(alt.rounded()))° up in the late evening"
                : "the full moon rides low this evening — catch it near moonrise or later at night"
            return SkyEvent(
                id: "supermoon.\(Self.dayStamp(instant))",
                kind: .supermoon,
                name: "Supermoon",
                date: instant,
                tier: .annual,
                detail: "Perigee full moon, roughly \(Int((distance / 1000.0).rounded())) "
                    + "thousand km away — modestly larger and brighter than an average full moon.",
                zhr: nil, radiant: nil,
                visibility: EventVisibility(visible: visible, altitudeDeg: alt,
                                            bestTime: evening, note: note),
                moonFraction: moon.illuminatedFraction,
                moonUpAtBest: visible,
                matchingShotModeID: "lunar",
                advice: "The size difference is subtle to the eye — the drama is a full moon "
                    + "rising behind a foreground you care about. Lunar Detail works as on any "
                    + "bright-moon night; shoot near moonrise for the low, orange disk.")
        }
    }

    // MARK: New-moon Milky Way nights (computed from SkyEngine, not stored)

    private func milkyWayNewMoonEvents(from: Date, to end: Date,
                                       location: GeoLocation) -> [SkyEvent] {
        Self.phaseInstants(targetElongationDeg: 0.0, from: from, to: end).compactMap { instant in
            // The night around the new moon: start the scan at ~18:00 local solar.
            let nightStart = Self.solarTimeDate(onNightOf: instant, hour: 18.0,
                                                longitude: location.longitude)
            guard engine.coreVisibleTonight(at: location, from: nightStart) else { return nil }

            // Core's peak altitude inside the darkness window (15-minute samples).
            var bestAlt = -90.0
            var bestTime = nightStart
            if let window = engine.darknessWindow(at: location, from: nightStart) {
                var t = window.start
                while t <= window.end {
                    let alt = engine.milkyWayCorePosition(at: location, date: t).altitudeDeg
                    if alt > bestAlt {
                        bestAlt = alt
                        bestTime = t
                    }
                    t = t.addingTimeInterval(900)
                }
            }
            guard bestAlt > SkyEngine.coreUsefulAltDeg else { return nil }

            return SkyEvent(
                id: "milkyway.newmoon.\(Self.dayStamp(instant))",
                kind: .milkyWayNewMoon,
                name: "New-moon Milky Way night",
                date: instant,
                tier: .annual,
                detail: "New moon during core season — no moonlight in the way all night.",
                zhr: nil, radiant: nil,
                visibility: EventVisibility(visible: true, altitudeDeg: bestAlt,
                                            bestTime: bestTime,
                                            note: "core up to \(Int(bestAlt.rounded()))° in darkness"),
                moonFraction: 0.0,
                moonUpAtBest: false,
                matchingShotModeID: "milkyway",
                advice: "The darkest core window of the month. Get to the darkest site you "
                    + "can reach — this is the night the Milky Way Stack pays off.")
        }
    }

    // MARK: Moon-phase search (shared by supermoon + new-moon events)

    /// Instants inside `[from, to]` where the sun→moon elongation crosses
    /// `targetElongationDeg` (0 = new moon, 180 = full moon). 6-hour scan
    /// (elongation advances ~3° per step) refined by bisection to sub-minute.
    static func phaseInstants(targetElongationDeg: Double, from: Date, to end: Date) -> [Date] {
        var results: [Date] = []
        let step: TimeInterval = 6 * 3600
        var t0 = from
        var d0 = signedElongationDelta(at: t0, target: targetElongationDeg)
        while t0 < end {
            let t1 = min(t0.addingTimeInterval(step), end)
            let d1 = signedElongationDelta(at: t1, target: targetElongationDeg)
            if d0 < 0, d1 >= 0 {
                results.append(refineCrossing(t0: t0, t1: t1, target: targetElongationDeg))
            }
            t0 = t1
            d0 = d1
        }
        return results
    }

    /// Signed distance (−180, 180] from the current elongation to the target angle.
    /// Crossings run negative → positive because elongation only increases.
    static func signedElongationDelta(at date: Date, target: Double) -> Double {
        let jd = SkyEngine.julianDate(date)
        let elongation = SkyEngine.wrap(
            SkyEngine.moonEcliptic(jd: jd).lonDeg - SkyEngine.sunEcliptic(jd: jd).longitudeDeg,
            to: 360.0)
        return SkyEngine.wrap(elongation - target + 180.0, to: 360.0) - 180.0
    }

    private static func refineCrossing(t0: Date, t1: Date, target: Double) -> Date {
        var lo = t0
        var hi = t1
        for _ in 0..<24 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            if signedElongationDelta(at: mid, target: target) < 0 {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
    }

    /// Truncated Meeus lunar-distance series (main cosine terms) — accurate to a few
    /// hundred km, ample against the ~361,000 km supermoon threshold.
    static func moonDistanceKm(jd: Double) -> Double {
        let t = (jd - 2451545.0) / 36525.0
        func angle(_ a: Double, _ b: Double) -> Double {
            SkyEngine.rad(SkyEngine.wrap(a + b * t, to: 360.0))
        }
        let d = angle(297.8502, 445267.1115)     // mean elongation
        let mp = angle(134.9634, 477198.8676)    // moon mean anomaly
        let m = angle(357.5291, 35999.0503)      // sun mean anomaly
        var km = 385000.56
        km -= 20905.36 * cos(mp)
        km -= 3699.11 * cos(2 * d - mp)
        km -= 2955.97 * cos(2 * d)
        km -= 569.93 * cos(2 * mp)
        km += 246.16 * cos(2 * d - 2 * mp)
        km -= 170.73 * cos(2 * d + mp)
        km += 48.89 * cos(m)
        return km
    }

    // MARK: Date helpers (pure, UTC / local-solar — no device time zone)

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }()

    static func utcDate(_ year: Int, _ month: Int, _ day: Int,
                        _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day,
                                      hour: hour, minute: minute)) ?? Date(timeIntervalSince1970: 0)
    }

    /// `hour` (may exceed 24 for "the following morning") in local *solar* time on the
    /// solar day containing `instant`. Solar time = UT + longitude/15 h; a deliberate
    /// time-zone-free approximation, honest to within about an hour anywhere on Earth.
    static func solarTimeDate(onNightOf instant: Date, hour: Double, longitude: Double) -> Date {
        let offset = longitude / 15.0 * 3600.0
        let localSolar = instant.timeIntervalSince1970 + offset
        let dayStart = (localSolar / 86_400.0).rounded(.down) * 86_400.0
        return Date(timeIntervalSince1970: dayStart + hour * 3600.0 - offset)
    }

    /// "2026-08-12" (UTC) — stable event-identifier fragment.
    static func dayStamp(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
