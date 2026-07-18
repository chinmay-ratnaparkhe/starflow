import XCTest
@testable import StarFlow

/// Offline event calendar + rarity scoring + reminder scheduling. All epochs are
/// fixed UTC instants; the scorer and planner take an injected UTC calendar so
/// nothing here depends on the simulator's time zone.
final class EventCatalogTests: XCTestCase {

    private let catalog = EventCatalog()
    private let denver = GeoLocation(latitude: 40.0, longitude: -105.0)
    private let london = GeoLocation(latitude: 51.5074, longitude: -0.1278)

    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func utcDate(_ y: Int, _ m: Int, _ d: Int,
                         _ h: Int = 0, _ min: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Perseids 2026 — peak date + new-moon high score

    /// The Perseids 2026 peak (night of Aug 12–13) lands on a new moon — Aug 12,
    /// 2026 hosts a total solar eclipse, which pins the moon phase exactly.
    func testPerseids2026PeakDateAndNewMoonScoreHigh() {
        let events = catalog.events(from: utcDate(2026, 7, 20), days: 40, location: denver)
        guard let perseids = events.first(where: { $0.id == "shower.perseids.2026" }) else {
            return XCTFail("Perseids 2026 missing from a mid-July query")
        }
        let comps = utc.dateComponents([.year, .month, .day], from: perseids.date)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 8)
        XCTAssertTrue([12, 13].contains(comps.day ?? 0),
                      "Perseids peak the night of Aug 12–13, got day \(comps.day ?? 0)")
        XCTAssertEqual(perseids.kind, .meteorShower)
        XCTAssertEqual(perseids.tier, .annual)
        XCTAssertEqual(perseids.zhr, 100)
        XCTAssertEqual(perseids.matchingShotModeID, "meteors")

        // New moon at the peak → near-zero interference from moonInfo.
        XCTAssertLessThan(perseids.moonFraction, 0.15)
        // Radiant (Dec +58°) rides high from latitude 40 N at 2 am.
        XCTAssertTrue(perseids.visibility.visible)
        XCTAssertGreaterThan(perseids.visibility.altitudeDeg, 30)

        let rarity = RarityScorer.score(for: perseids, calendar: utc)
        XCTAssertGreaterThanOrEqual(rarity.score, RarityScorer.notifyThreshold,
                                    "new-moon Perseids with a high radiant must clear the alert bar")
        XCTAssertTrue(rarity.reason.contains("Perseids"))
        XCTAssertTrue(rarity.reason.lowercased().contains("new moon"))
    }

    // MARK: Geminids — moon-interference math

    func testGeminidsMoonInterferenceMath() {
        // Same shower geometry, only the moon changes.
        let dark = RarityScorer.scoreValue(tier: .annual, visible: true, altitudeDeg: 60,
                                           moonFraction: 0.02, moonUp: false, moonSensitive: true)
        let washed = RarityScorer.scoreValue(tier: .annual, visible: true, altitudeDeg: 60,
                                             moonFraction: 0.97, moonUp: true, moonSensitive: true)
        let brightButSet = RarityScorer.scoreValue(tier: .annual, visible: true, altitudeDeg: 60,
                                                   moonFraction: 0.97, moonUp: false,
                                                   moonSensitive: true)
        XCTAssertGreaterThan(dark, washed)
        // A bright moon below the horizon at prime time hurts far less than one up.
        XCTAssertGreaterThan(brightButSet, washed)
        // A full-moon-washed annual shower must NOT trigger an alert…
        XCTAssertLessThan(washed, RarityScorer.notifyThreshold)
        // …while the same shower under a dark sky must.
        XCTAssertGreaterThanOrEqual(dark, RarityScorer.notifyThreshold)

        // The moon never penalizes moon-insensitive events (eclipses ARE the moon).
        let eclipse = RarityScorer.scoreValue(tier: .multiYear, visible: true, altitudeDeg: 30,
                                              moonFraction: 1.0, moonUp: true, moonSensitive: false)
        let eclipseNoMoonInput = RarityScorer.scoreValue(tier: .multiYear, visible: true,
                                                         altitudeDeg: 30, moonFraction: 0.0,
                                                         moonUp: false, moonSensitive: false)
        XCTAssertEqual(eclipse, eclipseNoMoonInput, accuracy: 1e-12)

        // Catalog carries the Geminids with their facts, moon read from moonInfo.
        let events = catalog.events(from: utcDate(2026, 12, 1), days: 20, location: denver)
        guard let geminids = events.first(where: { $0.id == "shower.geminids.2026" }) else {
            return XCTFail("Geminids 2026 missing from a December query")
        }
        XCTAssertEqual(geminids.zhr, 150)
        XCTAssertTrue([13, 14].contains(utc.component(.day, from: geminids.date)))
        XCTAssertGreaterThanOrEqual(geminids.moonFraction, 0.0)
        XCTAssertLessThanOrEqual(geminids.moonFraction, 1.0)
    }

    // MARK: Eclipse visibility — gated by location

    /// 2026-03-03 total lunar eclipse, mid ≈ 11:34 UT: pre-dawn with the Moon up in
    /// Denver, midday with the Moon set in London. Same event, opposite verdicts.
    func testLunarEclipseVisibilityGatedByLocation() {
        let from = utcDate(2026, 2, 20)
        let denverEvents = catalog.events(from: from, days: 20, location: denver)
        let londonEvents = catalog.events(from: from, days: 20, location: london)
        guard let fromDenver = denverEvents.first(where: { $0.id == "eclipse.lunar.2026-03-03" }),
              let fromLondon = londonEvents.first(where: { $0.id == "eclipse.lunar.2026-03-03" })
        else {
            return XCTFail("2026-03-03 total lunar eclipse missing")
        }
        XCTAssertTrue(fromDenver.visibility.visible)
        XCTAssertGreaterThan(fromDenver.visibility.altitudeDeg, 0)
        XCTAssertFalse(fromLondon.visibility.visible)
        XCTAssertLessThan(fromLondon.visibility.altitudeDeg, 0)

        // The gate flows into the score: visible clears the alert bar, invisible never.
        let denverScore = RarityScorer.score(for: fromDenver, calendar: utc).score
        let londonScore = RarityScorer.score(for: fromLondon, calendar: utc).score
        XCTAssertGreaterThan(denverScore, londonScore)
        XCTAssertGreaterThanOrEqual(denverScore, RarityScorer.notifyThreshold)
        XCTAssertLessThan(londonScore, RarityScorer.notifyThreshold)
    }

    // MARK: Scorer monotonicity

    func testScorerMonotonicity() {
        // Tier ↑ ⇒ score ↑, all else equal.
        let annual = RarityScorer.scoreValue(tier: .annual, visible: true, altitudeDeg: 40,
                                             moonFraction: 0.3, moonUp: true, moonSensitive: true)
        let multi = RarityScorer.scoreValue(tier: .multiYear, visible: true, altitudeDeg: 40,
                                            moonFraction: 0.3, moonUp: true, moonSensitive: true)
        let decade = RarityScorer.scoreValue(tier: .decade, visible: true, altitudeDeg: 40,
                                             moonFraction: 0.3, moonUp: true, moonSensitive: true)
        XCTAssertGreaterThan(multi, annual)
        XCTAssertGreaterThan(decade, multi)

        // Altitude ↑ ⇒ score non-decreasing while visible.
        var previous = -Double.infinity
        for alt in stride(from: 0.0, through: 90.0, by: 10.0) {
            let s = RarityScorer.scoreValue(tier: .annual, visible: true, altitudeDeg: alt,
                                            moonFraction: 0.0, moonUp: false, moonSensitive: true)
            XCTAssertGreaterThanOrEqual(s, previous)
            previous = s
        }

        // Moon fraction ↑ ⇒ score non-increasing, moon up or down.
        for moonUp in [true, false] {
            var prev = Double.infinity
            for f in stride(from: 0.0, through: 1.0, by: 0.1) {
                let s = RarityScorer.scoreValue(tier: .annual, visible: true, altitudeDeg: 50,
                                                moonFraction: f, moonUp: moonUp,
                                                moonSensitive: true)
                XCTAssertLessThanOrEqual(s, prev)
                prev = s
            }
        }

        // Visible always beats not-visible, and everything stays inside 0…100.
        for tier in [RarityTier.annual, .multiYear, .decade] {
            let up = RarityScorer.scoreValue(tier: tier, visible: true, altitudeDeg: 1,
                                             moonFraction: 0.5, moonUp: true, moonSensitive: true)
            let down = RarityScorer.scoreValue(tier: tier, visible: false, altitudeDeg: 1,
                                               moonFraction: 0.5, moonUp: true, moonSensitive: true)
            XCTAssertGreaterThan(up, down)
            for s in [up, down] {
                XCTAssertGreaterThanOrEqual(s, 0.0)
                XCTAssertLessThanOrEqual(s, 100.0)
            }
        }
    }

    // MARK: Moon-phase finder (drives supermoon + Milky Way new-moon events)

    /// 2026-03-03 hosts a total lunar eclipse — a full moon by definition — so the
    /// phase search must land within hours of it.
    func testFullMoonFinderBracketsKnownFullMoon() {
        let instants = EventCatalog.phaseInstants(targetElongationDeg: 180.0,
                                                  from: utcDate(2026, 2, 25),
                                                  to: utcDate(2026, 3, 10))
        XCTAssertEqual(instants.count, 1)
        let known = utcDate(2026, 3, 3, 11, 34)
        XCTAssertLessThan(abs(instants[0].timeIntervalSince(known)), 12 * 3600.0)
    }

    // MARK: Notification scheduling — idempotent, namespaced, gated

    final class MockCenter: EventNotifying, @unchecked Sendable {
        var pending: [String] = []
        var addCount = 0
        func requestAuthorization() async -> Bool { true }
        func pendingIdentifiers() async -> [String] { pending }
        func removePending(identifiers: [String]) async {
            pending.removeAll { identifiers.contains($0) }
        }
        func add(_ reminder: PlannedReminder) async {
            addCount += 1
            pending.append(reminder.id)
        }
    }

    /// Synthetic shower event: peaks `days` from now at 00:00 UT, best time the
    /// following 02:00 UT — dark-sky inputs score 50, over the 45 alert bar.
    private func syntheticShower(id: String, daysFromNow days: Double, now: Date,
                                 visible: Bool = true) -> SkyEvent {
        let date = now.addingTimeInterval(days * 86_400.0)
        return SkyEvent(
            id: id, kind: .meteorShower, name: "Testids", date: date, tier: .annual,
            detail: "test", zhr: 100, radiant: nil,
            visibility: EventVisibility(visible: visible,
                                        altitudeDeg: visible ? 60 : -5,
                                        bestTime: date.addingTimeInterval(26 * 3600.0),
                                        note: "radiant 60° up at 2 am"),
            moonFraction: 0.0, moonUpAtBest: false,
            matchingShotModeID: "meteors", advice: "test")
    }

    func testReminderReschedulingIsIdempotent() async {
        let now = utcDate(2026, 8, 1)
        let events = [
            syntheticShower(id: "a", daysFromNow: 10, now: now),
            syntheticShower(id: "b", daysFromNow: 20, now: now, visible: false), // below threshold
            syntheticShower(id: "c", daysFromNow: 40, now: now),                 // beyond 30 days
        ]
        let center = MockCenter()
        let scheduler = EventReminderScheduler(center: center)

        await scheduler.reschedule(events: events, now: now, calendar: utc)
        XCTAssertEqual(center.pending, ["starflow.event.a"],
                       "only the high-scoring event inside the horizon schedules")
        XCTAssertEqual(center.addCount, 1)

        // Second run with identical input: nothing added, nothing removed.
        await scheduler.reschedule(events: events, now: now, calendar: utc)
        XCTAssertEqual(center.pending, ["starflow.event.a"])
        XCTAssertEqual(center.addCount, 1)

        // Dropping every event clears our stale reminder.
        await scheduler.reschedule(events: [], now: now, calendar: utc)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertEqual(center.addCount, 1)

        // Identifiers outside the starflow.event. namespace are never touched.
        center.pending = ["other.app.reminder"]
        await scheduler.reschedule(events: events, now: now, calendar: utc)
        XCTAssertTrue(center.pending.contains("other.app.reminder"))
        XCTAssertEqual(Set(center.pending), ["other.app.reminder", "starflow.event.a"])
    }

    /// Event-tonight edge: by the afternoon of the peak day the 12:00 UT peak stamp
    /// is already in the past, but the observing night — and the 18:00 reminder —
    /// are still ahead. The planner must keep it, and an idempotent resync must not
    /// strip the pending reminder as stale.
    func testPlannerKeepsTonightsEventAfterPeakInstantPasses() async {
        let now = utcDate(2026, 8, 12, 16)          // 16:00 UT on the peak day
        let event = SkyEvent(
            id: "tonight", kind: .meteorShower, name: "Testids",
            date: utcDate(2026, 8, 12, 12),         // peak stamp already passed
            tier: .annual, detail: "test", zhr: 100, radiant: nil,
            visibility: EventVisibility(visible: true, altitudeDeg: 60,
                                        bestTime: utcDate(2026, 8, 13, 2),
                                        note: "radiant 60° up at 2 am"),
            moonFraction: 0.0, moonUpAtBest: false,
            matchingShotModeID: "meteors", advice: "test")

        let planned = EventReminderPlanner.plan(events: [event], now: now, calendar: utc)
        XCTAssertEqual(planned.count, 1, "tonight's event must survive an afternoon plan")
        let comps = utc.dateComponents([.day, .hour], from: planned[0].fireDate)
        XCTAssertEqual(comps.day, 12)
        XCTAssertEqual(comps.hour, EventReminderPlanner.eveningHour)

        // The pending reminder scheduled days ago survives the afternoon resync.
        let center = MockCenter()
        center.pending = ["starflow.event.tonight"]
        let scheduler = EventReminderScheduler(center: center)
        await scheduler.reschedule(events: [event], now: now, calendar: utc)
        XCTAssertEqual(center.pending, ["starflow.event.tonight"])
        XCTAssertEqual(center.addCount, 0)
    }

    /// A solar eclipse is a daytime event: a pre-noon eclipse belongs to its own
    /// day, never the "previous evening" like night events do.
    func testSolarEclipseReasonNamesItsOwnDay() {
        let mid = utcDate(2029, 1, 14, 10)          // 10:00 UT, a Sunday
        func event(kind: SkyEvent.Kind) -> SkyEvent {
            SkyEvent(id: "e", kind: kind, name: "Eclipse", date: mid, tier: .multiYear,
                     detail: "test", zhr: nil, radiant: nil,
                     visibility: EventVisibility(visible: true, altitudeDeg: 30,
                                                 bestTime: mid, note: "well placed"),
                     moonFraction: 0.0, moonUpAtBest: false,
                     matchingShotModeID: nil, advice: "test")
        }
        let sameDay = utc.shortWeekdaySymbols[utc.component(.weekday, from: mid) - 1]
        let dayBefore = utc.shortWeekdaySymbols[
            utc.component(.weekday, from: mid.addingTimeInterval(-86_400)) - 1]

        let solar = RarityScorer.reason(for: event(kind: .solarEclipse), calendar: utc)
        XCTAssertTrue(solar.contains(sameDay), "daytime event names its own day: \(solar)")
        XCTAssertFalse(solar.contains(dayBefore))

        // Night events keep the previous-evening anchoring: a 10:00 UT lunar
        // mid-eclipse is pre-dawn viewing for the hemisphere that sees it.
        let lunar = RarityScorer.reason(for: event(kind: .lunarEclipse), calendar: utc)
        XCTAssertTrue(lunar.contains(dayBefore), "night event anchors to the evening before: \(lunar)")
    }

    func testPlannerFiresEveningOfObservingNight() {
        let now = utcDate(2026, 8, 1)
        let event = syntheticShower(id: "a", daysFromNow: 10, now: now)
        let planned = EventReminderPlanner.plan(events: [event], now: now, calendar: utc)
        XCTAssertEqual(planned.count, 1)
        // Peak Aug 11 00:00 UT, best time Aug 12 02:00 UT → the observing night's
        // evening is Aug 11: fire 18:00 that day.
        let comps = utc.dateComponents([.month, .day, .hour, .minute], from: planned[0].fireDate)
        XCTAssertEqual(comps.month, 8)
        XCTAssertEqual(comps.day, 11)
        XCTAssertEqual(comps.hour, EventReminderPlanner.eveningHour)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(planned[0].title, "Testids tonight")
        XCTAssertTrue(planned[0].body.contains("radiant 60° up at 2 am"))
    }

    // MARK: Solar-eclipse reminders — the nudge must precede the eclipse

    private func syntheticSolarEclipse(mid: Date) -> SkyEvent {
        SkyEvent(id: "solar", kind: .solarEclipse, name: "Annular solar eclipse",
                 date: mid, tier: .multiYear, detail: "test", zhr: nil, radiant: nil,
                 visibility: EventVisibility(visible: true, altitudeDeg: 30,
                                             bestTime: mid, note: "the Sun is up for you"),
                 moonFraction: 0.0, moonUpAtBest: false,
                 matchingShotModeID: nil, advice: "test")
    }

    /// Afternoon eclipse: the 09:00 same-day nudge lands hours before mid-eclipse
    /// and honestly says "today".
    func testSolarEclipseReminderFiresMorningOfAfternoonEclipse() {
        let now = utcDate(2029, 1, 10)
        let mid = utcDate(2029, 1, 14, 17, 13)
        let planned = EventReminderPlanner.plan(events: [syntheticSolarEclipse(mid: mid)],
                                                now: now, calendar: utc)
        XCTAssertEqual(planned.count, 1)
        let comps = utc.dateComponents([.day, .hour], from: planned[0].fireDate)
        XCTAssertEqual(comps.day, 14)
        XCTAssertEqual(comps.hour, EventReminderPlanner.morningHour)
        XCTAssertLessThan(planned[0].fireDate, mid, "the nudge must precede the eclipse")
        XCTAssertEqual(planned[0].title, "Annular solar eclipse today")
    }

    /// Early-morning eclipse (mid before 09:00): a same-day 09:00 nudge would fire
    /// AFTER the show — fall back to 18:00 the evening before, titled honestly.
    func testSolarEclipseBeforeNineAmNudgesTheEveningBefore() {
        let now = utcDate(2030, 5, 25)
        let mid = utcDate(2030, 6, 1, 6, 28)
        let planned = EventReminderPlanner.plan(events: [syntheticSolarEclipse(mid: mid)],
                                                now: now, calendar: utc)
        XCTAssertEqual(planned.count, 1)
        let comps = utc.dateComponents([.month, .day, .hour], from: planned[0].fireDate)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 31)
        XCTAssertEqual(comps.hour, EventReminderPlanner.eveningHour)
        XCTAssertLessThan(planned[0].fireDate, mid)
        XCTAssertEqual(planned[0].title, "Annular solar eclipse tomorrow morning")
    }
}
