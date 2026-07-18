import SwiftUI

// MARK: - ScoredSkyEvent

/// A catalog event paired with its computed rarity, ready for the Coming-up cards.
struct ScoredSkyEvent: Identifiable {
    let event: SkyEvent
    let rarity: RarityScore
    var id: String { event.id }
}

// MARK: - Rarity badge

/// Small capsule badge naming the event's rarity tier: ANNUAL / MULTI-YEAR /
/// ONCE A DECADE. Night-mode aware.
@MainActor
struct RarityBadge: View {
    @ObservedObject private var appearance = Appearance.shared
    let tier: RarityTier

    init(tier: RarityTier) {
        self.tier = tier
    }

    var body: some View {
        let night = appearance.nightMode
        let color = Self.color(tier, night: night)
        Text(tier.label.uppercased())
            .font(Theme.label)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
            .fixedSize()
    }

    static func color(_ tier: RarityTier, night: Bool) -> Color {
        switch tier {
        case .annual: return Theme.secondaryText(night)
        case .multiYear: return Theme.accent(night)
        case .decade: return Theme.positive(night)
        }
    }
}

// MARK: - Event card

/// One Coming-up card: name, date, rarity badge, honest reason line. Tapping opens
/// the detail sheet.
@MainActor
struct EventCard: View {
    @ObservedObject private var appearance = Appearance.shared
    let entry: ScoredSkyEvent
    let onTap: () -> Void

    init(entry: ScoredSkyEvent, onTap: @escaping () -> Void) {
        self.entry = entry
        self.onTap = onTap
    }

    var body: some View {
        let night = appearance.nightMode
        let tint = RarityBadge.color(entry.event.tier, night: night)
        Button(action: onTap) {
            SFCard(accent: tint) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(tint)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.event.name)
                                .font(Theme.headline)
                                .foregroundStyle(Theme.primaryText(night))
                                .multilineTextAlignment(.leading)
                            Text(entry.event.date,
                                 format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText(night))
                        }
                        Spacer(minLength: 8)
                        RarityBadge(tier: entry.event.tier)
                    }
                    Text(entry.rarity.reason)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.event.name), "
            + entry.event.date.formatted(date: .abbreviated, time: .omitted)
            + ", \(entry.event.tier.label). \(entry.rarity.reason)")
        .accessibilityHint("Shows viewing advice for this event.")
    }

    private var symbol: String {
        switch entry.event.kind {
        case .meteorShower: return "sparkle"
        case .lunarEclipse: return "circle.lefthalf.filled"
        case .solarEclipse: return "sun.max.fill"
        case .supermoon: return "moon.circle.fill"
        case .milkyWayNewMoon: return "sparkles"
        }
    }
}

// MARK: - Event detail sheet

/// Tapped-event sheet: rarity, reason, local visibility, moon interference, viewing
/// advice, and — when the event maps to a shot mode — a jump straight into it.
@MainActor
struct EventDetailSheet: View {
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("skyQuality") private var skyQualityRaw: Int = SkyQuality.suburb.rawValue
    let entry: ScoredSkyEvent
    let onOpenShotMode: (String) -> Void

    init(entry: ScoredSkyEvent, onOpenShotMode: @escaping (String) -> Void) {
        self.entry = entry
        self.onOpenShotMode = onOpenShotMode
    }

    var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                Theme.screenBg(night).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(night)
                        factsCard(night)
                        SFSectionLabel("Viewing advice")
                        SFCard {
                            Text(entry.event.advice)
                                .font(Theme.body)
                                .foregroundStyle(Theme.secondaryText(night))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let modeID = entry.event.matchingShotModeID,
                           let mode = ShotModeRegistry.mode(id: modeID) {
                            shotModeButton(mode, night: night)
                            // Same city gate the Tonight shot list applies: a mode
                            // that needs dark skies deserves the warning here too,
                            // where the event invites a jump straight into it.
                            if !mode.cityViable,
                               SkyQuality(rawValue: skyQualityRaw) == .city {
                                Text("Your sky quality is set to City — \(mode.name) "
                                     + "needs dark skies, so plan this one as a trip "
                                     + "somewhere darker.")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.warning(night))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Computed offline from the built-in catalog and ephemeris — "
                             + "times are approximate by design, and the weather is yours "
                             + "to check.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(entry.event.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent(night))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func header(_ night: Bool) -> some View {
        HStack(spacing: 10) {
            RarityBadge(tier: entry.event.tier)
            Spacer(minLength: 8)
            Text(entry.event.date, format: dateFormat)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText(night))
        }
    }

    /// Showers carry a whole night, so the clock time would mislead; eclipses and
    /// moon events are instants, so show it.
    private var dateFormat: Date.FormatStyle {
        switch entry.event.kind {
        case .meteorShower, .milkyWayNewMoon:
            return .dateTime.weekday(.wide).month(.wide).day()
        case .lunarEclipse, .solarEclipse, .supermoon:
            return .dateTime.weekday(.wide).month(.wide).day().hour().minute()
        }
    }

    private func factsCard(_ night: Bool) -> some View {
        SFCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.rarity.reason)
                    .font(Theme.body)
                    .foregroundStyle(Theme.primaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                divider(night)
                factRow(label: "Local visibility", value: entry.event.visibility.note,
                        night: night)
                if entry.event.kind != .solarEclipse {
                    divider(night)
                    factRow(label: "Moon",
                            value: TonightFormat.percent(entry.event.moonFraction) + " lit, "
                                + (entry.event.moonUpAtBest ? "up" : "down")
                                + " at prime time",
                            night: night)
                }
                divider(night)
                factRow(label: "About", value: entry.event.detail, night: night)
            }
        }
    }

    private func divider(_ night: Bool) -> some View {
        Divider().overlay(Theme.secondaryText(night).opacity(0.2))
    }

    private func factRow(label: String, value: String, night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.label)
                .kerning(0.8)
                .foregroundStyle(Theme.secondaryText(night))
            Text(value)
                .font(Theme.caption)
                .foregroundStyle(Theme.primaryText(night))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func shotModeButton(_ mode: ShotModeItem, night: Bool) -> some View {
        Button {
            onOpenShotMode(mode.id)
        } label: {
            Label("Set up \(mode.name)", systemImage: mode.symbol)
                .font(Theme.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent(night))
        .background(Capsule().fill(Theme.accent(night).opacity(0.14)))
        .overlay(Capsule().strokeBorder(Theme.accent(night).opacity(0.35), lineWidth: 1))
        .accessibilityHint("Closes this sheet and starts a guided \(mode.name) session.")
    }
}
