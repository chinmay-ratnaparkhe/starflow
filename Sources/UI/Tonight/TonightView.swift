import SwiftUI

/// The front door. One verdict headline, live sky strip, tonight's top three
/// shots ranked by feasibility, and a live gimbal status ribbon.
@MainActor
public struct TonightView: View {

    @ObservedObject private var appearance = Appearance.shared
    @ObservedObject private var sessions = SessionStore.shared
    @StateObject private var locationProvider = LocationProvider()
    @AppStorage("skyQuality") private var skyQualityRaw: Int = SkyQuality.suburb.rawValue

    @State private var context: SkyContext?
    @State private var coreWindow: (start: Date, end: Date)?
    @State private var connection: MountConnection = .searching
    @State private var authority: MountAuthority = .unknown
    @State private var activeShot: ShotModeItem?
    @State private var startedMount = false
    @State private var lastComputed: Date = .distantPast
    @State private var outlook: [OutlookNight] = []
    @State private var outlookDay: Date?
    @State private var outlookLocation: GeoLocation?
    @State private var upcoming: [ScoredSkyEvent] = []
    @State private var selectedEvent: ScoredSkyEvent?
    @State private var pendingShotModeID: String?

    private let sky: SkyComputing = SkyEngine()

    public init() {}

    private var skyQuality: SkyQuality { SkyQuality(rawValue: skyQualityRaw) ?? .suburb }

    // MARK: Body

    public var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                TonightStarField()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(night: night)
                        if let ctx = context {
                            verdictCard(ctx: ctx, night: night)
                            skyStrip(ctx: ctx)
                            if let measured = recentMeasuredSky {
                                measuredSkyChip(measured, night: night)
                            }
                            if !outlook.isEmpty {
                                SFSectionLabel("Next 7 nights")
                                OutlookStrip(nights: outlook)
                            }
                            SFSectionLabel("Tonight's shots")
                            shotList(ctx: ctx, night: night)
                            if !upcoming.isEmpty {
                                SFSectionLabel("Coming up")
                                upcomingList
                            }
                        } else {
                            LocationPromptCard(denied: locationProvider.denied) {
                                locationProvider.requestAccess()
                            }
                        }
                        SFSectionLabel("Gimbal")
                        GimbalStatusRibbon(connection: connection, authority: authority)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .refreshable { await refresh() }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { bootstrap() }
        .task { await tickLoop() }
        .onReceive(locationProvider.$location) { newLocation in
            recompute(location: newLocation)
        }
        .sheet(item: $activeShot) { shot in
            SessionView(shot: shot)
        }
        // Event detail sheet. Choosing its shot-mode link stashes the mode id and
        // dismisses; the follow-up session sheet presents from onDismiss so the two
        // sheets never fight over presentation.
        .sheet(item: $selectedEvent, onDismiss: {
            if let id = pendingShotModeID {
                pendingShotModeID = nil
                if let mode = ShotModeRegistry.mode(id: id) {
                    activeShot = mode
                }
            }
        }) { entry in
            EventDetailSheet(entry: entry) { modeID in
                pendingShotModeID = modeID
                selectedEvent = nil
            }
        }
    }

    // MARK: Sections

    private func header(night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
                .textCase(.uppercase)
                .font(Theme.label)
                .kerning(1.2)
                .foregroundStyle(Theme.secondaryText(night))
            Text("Tonight")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundStyle(Theme.primaryText(night))
        }
        .padding(.top, 6)
    }

    private func verdictCard(ctx: SkyContext, night: Bool) -> some View {
        let v = verdict(ctx: ctx, night: night)
        return SFCard(accent: v.tint) {
            VStack(alignment: .leading, spacing: 10) {
                Text("VERDICT")
                    .font(Theme.label)
                    .kerning(1.5)
                    .foregroundStyle(v.tint)
                Text(v.headline)
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                Text(v.subline)
                    .font(Theme.body)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func skyStrip(ctx: SkyContext) -> some View {
        SFCard {
            HStack(spacing: 0) {
                SFStatChip(symbol: "moon.fill",
                           value: TonightFormat.percent(ctx.moon.illuminatedFraction),
                           label: "Moon")
                SFStatChip(symbol: "sparkles",
                           value: ctx.milkyWayCore.altitudeDeg > 0
                               ? TonightFormat.degrees(ctx.milkyWayCore.altitudeDeg)
                               : "Below",
                           label: "Core alt")
                SFStatChip(symbol: "sunset.fill",
                           value: ctx.darknessWindow.map { TonightFormat.clock($0.start) } ?? "—",
                           label: "Dark from")
                SFStatChip(symbol: "clock",
                           value: TonightFormat.lst(ctx.lstHours),
                           label: "LST")
            }
        }
    }

    private func shotList(ctx: SkyContext, night: Bool) -> some View {
        VStack(spacing: 14) {
            ForEach(rankedShots(ctx: ctx)) { entry in
                shotCard(entry, night: night)
            }
        }
    }

    /// Next three catalog events (meteor showers, eclipses, supermoons, new-moon
    /// Milky Way nights) as tappable cards — nearest first, honestly scored.
    private var upcomingList: some View {
        VStack(spacing: 14) {
            ForEach(upcoming) { entry in
                EventCard(entry: entry) { selectedEvent = entry }
            }
        }
    }

    private func shotCard(_ entry: RankedShot, night: Bool) -> some View {
        let tint = FeasibilityPresentation.color(entry.feasibility, night: night)
        return SFCard(accent: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.item.symbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.item.name)
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Text(entry.item.tagline)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                    Spacer(minLength: 8)
                    FeasibilityBadge(feasibility: entry.feasibility)
                }
                if let note = FeasibilityPresentation.note(entry.feasibility) {
                    Text(note)
                        .font(Theme.caption)
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(entry.item.expectation)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    activeShot = entry.item
                } label: {
                    Text("Set up this shot")
                        .font(Theme.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .background(Capsule().fill(tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
                .accessibilityLabel("Set up \(entry.item.name)")
                .accessibilityHint("Starts a guided \(entry.item.name) session.")
            }
        }
    }

    // MARK: Measured sky (last session)

    /// The newest logbook record, when it is from the past 12 hours and carries
    /// a measured sky condition. Measured — from that session's actual frames —
    /// never a forecast. Deliberately only the NEWEST record: the chip says
    /// "Last session", so an older graded session must never speak for an
    /// ungraded newer one.
    private var recentMeasuredSky: SessionRecord? {
        guard let newest = sessions.records.first,
              let condition = newest.skyCondition, condition != .unknown,
              Date().timeIntervalSince(newest.date) < 12 * 3600
        else { return nil }
        return newest
    }

    /// Small capsule chip: "Last session sky: cloudy · 2 hours ago". Carries the
    /// SIMULATED badge on simulator builds, where session frames are synthetic.
    private func measuredSkyChip(_ record: SessionRecord, night: Bool) -> some View {
        let condition = record.skyCondition ?? .unknown
        let tint = skyConditionTint(condition, night: night)
        return HStack(spacing: 8) {
            Image(systemName: skyConditionSymbol(condition))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text("Last session sky: \(condition.displayName)")
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText(night))
            Text(record.date, format: .relative(presentation: .numeric))
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText(night))
            if MountService.isSimulated {
                SimulatedSourceBadge()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.30), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        // Mirror everything the sighted chip shows: condition, when it was
        // measured, and the simulated-source disclosure (the badge itself is
        // hidden from VoiceOver by `children: .ignore`).
        .accessibilityLabel(
            "Last session sky: \(condition.displayName), measured from your session's frames "
            + record.date.formatted(.relative(presentation: .numeric)) + "."
            + (MountService.isSimulated ? " Simulated data source." : ""))
    }

    private func skyConditionTint(_ condition: SkyCondition, night: Bool) -> Color {
        switch condition {
        case .clear: return Theme.positive(night)
        case .hazy: return Theme.warning(night)
        case .cloudy: return Theme.secondaryText(night)
        case .overexposed: return Theme.warning(night)
        case .unknown: return Theme.secondaryText(night)
        }
    }

    private func skyConditionSymbol(_ condition: SkyCondition) -> String {
        switch condition {
        case .clear: return "moon.stars.fill"
        case .hazy: return "cloud.fog.fill"
        case .cloudy: return "cloud.fill"
        case .overexposed: return "sun.max.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    // MARK: Verdict logic

    private func verdict(ctx: SkyContext, night: Bool) -> (headline: String, subline: String, tint: Color) {
        let moonPct = TonightFormat.percent(ctx.moon.illuminatedFraction)
        let moonUp = ctx.moon.position.altitudeDeg > 0
        let moonBright = ctx.moon.illuminatedFraction >= 0.6

        var parts: [String] = []
        if let window = ctx.darknessWindow {
            parts.append("Dark \(TonightFormat.clock(window.start))–\(TonightFormat.clock(window.end))")
        } else {
            parts.append("No full astronomical darkness")
        }
        parts.append("Moon \(moonPct)")
        if skyQuality == .city {
            parts.append("city sky limits faint detail")
        }
        let subline = parts.joined(separator: " · ")

        if ctx.darknessWindow == nil {
            return ("Twilight all night — aim at bright targets",
                    subline, Theme.warning(night))
        }
        if moonBright && moonUp {
            return ("Moon washes the sky — lunar night",
                    subline, Theme.warning(night))
        }
        if ctx.coreVisibleTonight, let window = coreWindow {
            return ("Milky Way core up \(TonightFormat.clock(window.start))–\(TonightFormat.clock(window.end))",
                    subline, Theme.accent(night))
        }
        if ctx.moon.illuminatedFraction < 0.35 {
            return ("Great night for star trails",
                    subline, Theme.positive(night))
        }
        return ("Fair night — stack deep, expect softer skies",
                subline, Theme.accent(night))
    }

    // MARK: Data plumbing

    private func bootstrap() {
        if !startedMount {
            startedMount = true
            MountService.shared.start()
        }
        locationProvider.requestAccess()
        readMount()
        recompute(location: locationProvider.location)
    }

    private func readMount() {
        connection = MountService.shared.connection
        authority = MountService.shared.authority
    }

    /// Re-read the mount ribbon every few seconds; recompute the sky each minute.
    private func tickLoop() async {
        while !Task.isCancelled {
            readMount()
            if Date().timeIntervalSince(lastComputed) > 60 {
                recompute(location: locationProvider.location)
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func refresh() async {
        locationProvider.requestAccess()
        readMount()
        recompute(location: locationProvider.location)
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func recompute(location: GeoLocation?) {
        guard let location else {
            context = nil
            coreWindow = nil
            outlook = []
            outlookDay = nil
            outlookLocation = nil
            upcoming = []
            return
        }
        let ctx = sky.skyContext(at: location, date: Date())
        context = ctx
        coreWindow = coreVisibilityWindow(location: location, context: ctx)
        lastComputed = Date()
        recomputeOutlookIfNeeded(location: location)
    }

    /// The week-ahead strip and the event calendar only shift once a day (or when
    /// the fix moves), so skip their ephemeris scans on the minute tick.
    private func recomputeOutlookIfNeeded(location: GeoLocation) {
        let today = Calendar.current.startOfDay(for: Date())
        guard outlook.isEmpty || outlookDay != today || outlookLocation != location else { return }
        outlook = OutlookNight.nextSeven(sky: sky, location: location, from: Date())
        outlookDay = today
        outlookLocation = location

        // Offline event calendar: next 60 days, next 3 shown as cards. Query with a
        // 24 h lookback so an event whose peak stamp (12:00 UT for showers) already
        // passed today still covers tonight's observing night — both for the card
        // and for the reminder scheduler, whose idempotent resync would otherwise
        // remove tonight's pending 18:00 nudge as stale. The full list feeds the
        // scheduler; the cards drop events more than ~4 h past their best moment.
        let now = Date()
        let events = EventCatalog().events(from: now.addingTimeInterval(-86_400),
                                           days: 61, location: location)
        upcoming = events
            .filter { ($0.visibility.bestTime ?? $0.date) > now.addingTimeInterval(-4 * 3600) }
            .prefix(3)
            .map { ScoredSkyEvent(event: $0, rarity: RarityScorer.score(for: $0)) }
        Task { await EventReminderService.shared.sync(events: events) }
    }

    /// Samples the core's altitude across tonight's darkness window (15-min steps)
    /// to find when it sits usefully above the horizon (>10°).
    private func coreVisibilityWindow(location: GeoLocation, context ctx: SkyContext) -> (start: Date, end: Date)? {
        guard ctx.coreVisibleTonight else { return nil }
        let searchStart: Date
        let searchEnd: Date
        if let window = ctx.darknessWindow {
            searchStart = window.start
            searchEnd = window.end
        } else {
            searchStart = ctx.date
            searchEnd = ctx.date.addingTimeInterval(12 * 3600)
        }
        guard searchEnd > searchStart else { return nil }

        let step: TimeInterval = 15 * 60
        var firstUp: Date?
        var lastUp: Date?
        var t = searchStart
        while t <= searchEnd {
            if sky.milkyWayCorePosition(at: location, date: t).altitudeDeg > 10 {
                if firstUp == nil { firstUp = t }
                lastUp = t
            }
            t = t.addingTimeInterval(step)
        }
        guard let start = firstUp, let end = lastUp, end > start else { return nil }
        return (start, end)
    }

    private func rankedShots(ctx: SkyContext) -> [RankedShot] {
        let quality = skyQuality
        let scored = ShotModeRegistry.all.map {
            RankedShot(item: $0, feasibility: $0.feasibility(ctx, quality))
        }
        let sorted = scored.enumerated().sorted { a, b in
            let ra = FeasibilityPresentation.rank(a.element.feasibility)
            let rb = FeasibilityPresentation.rank(b.element.feasibility)
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map { $0.element }
        return Array(sorted.prefix(3))
    }
}

/// A shot mode paired with tonight's computed feasibility, ready for ranking.
private struct RankedShot: Identifiable {
    let item: ShotModeItem
    let feasibility: Feasibility
    var id: String { item.id }
}
