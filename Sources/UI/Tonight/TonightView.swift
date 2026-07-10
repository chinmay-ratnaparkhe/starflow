import SwiftUI

/// The front door. One verdict headline, live sky strip, tonight's top three
/// shots ranked by feasibility, and a live gimbal status ribbon.
@MainActor
public struct TonightView: View {

    @ObservedObject private var appearance = Appearance.shared
    @StateObject private var locationProvider = LocationProvider()
    @AppStorage("skyQuality") private var skyQualityRaw: Int = SkyQuality.suburb.rawValue

    @State private var context: SkyContext?
    @State private var coreWindow: (start: Date, end: Date)?
    @State private var connection: MountConnection = .searching
    @State private var authority: MountAuthority = .unknown
    @State private var activeShot: ShotModeItem?
    @State private var startedMount = false
    @State private var lastComputed: Date = .distantPast

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
                            SFSectionLabel("Tonight's shots")
                            shotList(ctx: ctx, night: night)
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
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(tint)
                .background(Capsule().fill(tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            }
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
            return
        }
        let ctx = sky.skyContext(at: location, date: Date())
        context = ctx
        coreWindow = coreVisibilityWindow(location: location, context: ctx)
        lastComputed = Date()
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
