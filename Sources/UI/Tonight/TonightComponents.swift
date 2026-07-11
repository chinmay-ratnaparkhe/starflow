import SwiftUI

// MARK: - Feasibility presentation (shared by Tonight and the Modes gallery)

/// Maps `Feasibility` to ranking order, badge copy, and theme colors.
enum FeasibilityPresentation {

    /// Sort order: great < possible < notTonight < notWithPhone.
    static func rank(_ feasibility: Feasibility) -> Int {
        switch feasibility {
        case .great: return 0
        case .possible: return 1
        case .notTonight: return 2
        case .notWithPhone: return 3
        }
    }

    static func label(_ feasibility: Feasibility) -> String {
        switch feasibility {
        case .great: return "Great tonight"
        case .possible: return "Possible"
        case .notTonight: return "Not tonight"
        case .notWithPhone: return "Beyond phone"
        }
    }

    /// The honest one-liner attached to non-great verdicts.
    static func note(_ feasibility: Feasibility) -> String? {
        switch feasibility {
        case .great: return nil
        case .possible(let note): return note
        case .notTonight(let reason): return reason
        case .notWithPhone(let reason): return reason
        }
    }

    static func color(_ feasibility: Feasibility, night: Bool) -> Color {
        switch feasibility {
        case .great: return Theme.positive(night)
        case .possible: return Theme.warning(night)
        case .notTonight: return Theme.secondaryText(night)
        case .notWithPhone: return Theme.danger(night)
        }
    }
}

/// Small capsule badge: GREAT TONIGHT / POSSIBLE / NOT TONIGHT / BEYOND PHONE.
@MainActor
struct FeasibilityBadge: View {
    @ObservedObject private var appearance = Appearance.shared
    let feasibility: Feasibility

    init(feasibility: Feasibility) {
        self.feasibility = feasibility
    }

    var body: some View {
        let night = appearance.nightMode
        let color = FeasibilityPresentation.color(feasibility, night: night)
        Text(FeasibilityPresentation.label(feasibility).uppercased())
            .font(Theme.label)
            .kerning(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
            .fixedSize()
    }
}

// MARK: - Simulated-source badge

/// Unmistakable rose "SIMULATED" pill. Pin it to any UI element whose data comes from
/// a simulated source (`MountService.isSimulated` — simulator builds only), so fake
/// readings can never masquerade as real hardware. Deliberately NOT night-mode tinted:
/// it must stand out in every appearance.
@MainActor
struct SimulatedSourceBadge: View {
    init() {}

    var body: some View {
        Text("SIMULATED")
            .font(Theme.label)
            .kerning(1.0)
            .foregroundStyle(Theme.rose)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Theme.rose.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Theme.rose.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("Simulated data source")
    }
}

// MARK: - Formatting helpers

enum TonightFormat {

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Local sidereal time as "18h 42m".
    static func lst(_ hours: Double) -> String {
        let normalized = ((hours.truncatingRemainder(dividingBy: 24)) + 24)
            .truncatingRemainder(dividingBy: 24)
        let h = Int(normalized)
        let m = Int((normalized - Double(h)) * 60)
        return String(format: "%dh %02dm", h, m)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "45s", "5m", "12m 30s" — for integration totals and intervals.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60
        let s = total % 60
        return s == 0 ? "\(m)m" : "\(m)m \(String(format: "%02d", s))s"
    }

    /// "1s" for the cap, "1/2s" style for sub-second exposures.
    static func exposure(_ seconds: Double) -> String {
        if seconds >= 0.95 { return String(format: "%.0fs", seconds) }
        guard seconds > 0 else { return "0s" }
        return "1/\(Int((1.0 / seconds).rounded()))s"
    }

    static func degrees(_ value: Double) -> String {
        String(format: "%.0f°", value)
    }

    /// "12 minutes 30 seconds" — natural VoiceOver phrasing for durations.
    static func spokenDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) \(h == 1 ? "hour" : "hours")") }
        if m > 0 { parts.append("\(m) \(m == 1 ? "minute" : "minutes")") }
        if s > 0 || parts.isEmpty { parts.append("\(s) \(s == 1 ? "second" : "seconds")") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Gimbal status ribbon

/// Compact live ribbon reflecting `MountService` connection + authority,
/// with guidance copy (trigger squeeze, dock prompt, flap recovery).
@MainActor
struct GimbalStatusRibbon: View {
    @ObservedObject private var appearance = Appearance.shared
    let connection: MountConnection
    let authority: MountAuthority

    init(connection: MountConnection, authority: MountAuthority) {
        self.connection = connection
        self.authority = authority
    }

    var body: some View {
        let night = appearance.nightMode
        let s = status(night: night)
        SFCard(accent: s.tint) {
            HStack(spacing: 12) {
                Image(systemName: s.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(s.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(s.detail)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if MountService.isSimulated {
                    SimulatedSourceBadge()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Gimbal status: \(s.title). \(s.detail)"
                                + (MountService.isSimulated ? " Simulated data source." : ""))
        }
    }

    private func status(night: Bool) -> (symbol: String, title: String, detail: String, tint: Color) {
        switch connection {
        case .docked(let name):
            switch authority {
            case .granted:
                return ("dot.radiowaves.left.and.right", "\(name) connected",
                        "Motor control granted — tracked shots are ready.",
                        Theme.positive(night))
            case .denied:
                return ("hand.raised.fill", "\(name) connected",
                        "Squeeze the gimbal trigger to hand StarFlow the motors.",
                        Theme.warning(night))
            case .unknown:
                return ("questionmark.circle", "\(name) connected",
                        "Checking motor control authority…",
                        Theme.warning(night))
            }
        case .searching:
            return ("magnifyingglass", "Looking for your gimbal",
                    "Dock your iPhone on the Flow 2 Pro to connect. Static shots work without it.",
                    Theme.secondaryText(night))
        case .flapping(let since):
            return ("arrow.triangle.2.circlepath", "Gimbal reconnecting",
                    "Brief undock at \(TonightFormat.clock(since)) — recovering automatically.",
                    Theme.warning(night))
        case .undocked:
            return ("iphone.slash", "Gimbal not docked",
                    "Static shots still work. Dock to enable tracked framing.",
                    Theme.secondaryText(night))
        }
    }
}

// MARK: - Location empty state

/// Friendly nil-location / denied prompt for the Tonight screen.
@MainActor
struct LocationPromptCard: View {
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.openURL) private var openURL
    let denied: Bool
    let onRequest: () -> Void

    init(denied: Bool, onRequest: @escaping () -> Void) {
        self.denied = denied
        self.onRequest = onRequest
    }

    var body: some View {
        let night = appearance.nightMode
        SFCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: denied ? "location.slash" : "location")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent(night))
                    Text(denied ? "Location access is off" : "Where are you stargazing?")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                }
                Text(denied
                     ? "StarFlow needs your location to compute tonight's sky. Turn it on in Settings — coordinates never leave the device."
                     : "Tonight's verdict, moon phase, and Milky Way times are computed from your coordinates — on device, never uploaded.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if denied {
                        if let url = URL(string: "app-settings:") {
                            openURL(url)
                        }
                    } else {
                        onRequest()
                    }
                } label: {
                    Text(denied ? "Open Settings" : "Use my location")
                        .font(Theme.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(night ? Color.black : Theme.bg)
                .background(Capsule().fill(Theme.accent(night)))
                .accessibilityHint(denied
                                   ? "Opens the Settings app to turn location access back on."
                                   : "Asks for location permission to compute tonight's sky.")
            }
        }
    }
}

// MARK: - 7-night outlook

/// One night of the week-ahead strip: computed via the sky engine at +1..7 days.
struct OutlookNight: Identifiable, Equatable {
    let date: Date
    let moonFraction: Double     // 0..1 illuminated
    let coreVisible: Bool        // galactic core clears 10° during darkness
    let hasDarkness: Bool        // astronomical darkness occurs at all

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }

    /// The next seven nights, one sky context each (pure math, no network).
    static func nextSeven(sky: SkyComputing, location: GeoLocation, from date: Date) -> [OutlookNight] {
        (1...7).map { offset in
            let night = date.addingTimeInterval(Double(offset) * 86_400)
            let ctx = sky.skyContext(at: location, date: night)
            return OutlookNight(date: night,
                                moonFraction: ctx.moon.illuminatedFraction,
                                coreVisible: ctx.coreVisibleTonight,
                                hasDarkness: ctx.darknessWindow != nil)
        }
    }
}

/// Horizontally scrolling week-ahead strip: seven small day chips, each with a
/// core-visibility dot and the moon's illuminated fraction. Night-mode aware.
@MainActor
struct OutlookStrip: View {
    @ObservedObject private var appearance = Appearance.shared
    let nights: [OutlookNight]

    init(nights: [OutlookNight]) {
        self.nights = nights
    }

    var body: some View {
        let night = appearance.nightMode
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(nights) { entry in
                        chip(entry, night: night)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            Text("Gold dot — the galactic core rides above 10° in darkness that night.")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText(night))
        }
    }

    private func chip(_ entry: OutlookNight, night: Bool) -> some View {
        VStack(spacing: 7) {
            Text(entry.date, format: .dateTime.weekday(.abbreviated))
                .textCase(.uppercase)
                .font(Theme.label)
                .kerning(0.8)
                .foregroundStyle(Theme.secondaryText(night))
            Circle()
                .fill(entry.coreVisible
                      ? Theme.accent(night)
                      : Theme.secondaryText(night).opacity(0.25))
                .frame(width: 7, height: 7)
            HStack(spacing: 3) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText(night))
                Text(TonightFormat.percent(entry.moonFraction))
                    .font(Theme.liveValue(13))
                    .foregroundStyle(entry.hasDarkness
                                     ? Theme.primaryText(night)
                                     : Theme.secondaryText(night))
            }
        }
        .frame(minWidth: 58)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(entry))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.cardBg(night))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            entry.coreVisible
                                ? Theme.accent(night).opacity(night ? 0.5 : 0.35)
                                : Theme.accent(night).opacity(night ? 0.35 : 0.14),
                            lineWidth: 1)
                )
        )
    }

    /// "Wednesday: moon 42% illuminated, galactic core visible" — one chip, one sentence.
    private func accessibilitySummary(_ entry: OutlookNight) -> String {
        var parts = ["moon \(TonightFormat.percent(entry.moonFraction)) illuminated"]
        parts.append(entry.coreVisible ? "galactic core visible" : "core stays low")
        if !entry.hasDarkness { parts.append("no full darkness") }
        let day = entry.date.formatted(.dateTime.weekday(.wide))
        return "\(day): \(parts.joined(separator: ", "))"
    }
}

// MARK: - Star field backdrop

/// Subtle deterministic star field behind the Tonight scroll. Night-mode aware.
@MainActor
struct TonightStarField: View {
    @ObservedObject private var appearance = Appearance.shared

    init() {}

    var body: some View {
        let night = appearance.nightMode
        let starColor = night ? Theme.nightRedDim : Theme.text
        ZStack {
            Theme.screenBg(night).ignoresSafeArea()
            Canvas { context, size in
                let width = Double(size.width)
                let height = Double(size.height)
                guard width > 1, height > 1 else { return }
                var rng = TonightSeededGenerator(seed: 0x5AF10)
                for _ in 0..<90 {
                    let x = Double.random(in: 0..<width, using: &rng)
                    let y = Double.random(in: 0..<height, using: &rng)
                    let r = Double.random(in: 0.4...1.3, using: &rng)
                    let alpha = Double.random(in: 0.06...0.30, using: &rng)
                    let rect = CGRect(x: x, y: y, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(starColor.opacity(alpha)))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

/// xorshift64 — deterministic so the star field never shimmers between renders.
private struct TonightSeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
