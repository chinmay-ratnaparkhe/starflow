import Foundation

/// A scored event: 0–100 plus the honest one-line reason shown on cards and in
/// notification bodies ("Perseids peak Tue — new moon, radiant 52° up at 2 am").
public struct RarityScore: Equatable, Sendable {
    public let score: Double
    public let reason: String

    public init(score: Double, reason: String) {
        self.score = score
        self.reason = reason
    }
}

/// Pure event scoring: rarity tier × local visibility × moon interference.
/// No side effects; the calendar is injected so weekday names are deterministic
/// in tests. The score decides which events earn a notification — the reason
/// line tells the user why, in one honest sentence.
public enum RarityScorer {

    /// Events at or above this within the reminder horizon get an evening-of nudge.
    public static let notifyThreshold: Double = 45.0

    // MARK: Public API

    public static func score(for event: SkyEvent, calendar: Calendar = .current) -> RarityScore {
        let value = scoreValue(tier: event.tier,
                               visible: event.visibility.visible,
                               altitudeDeg: event.visibility.altitudeDeg,
                               moonFraction: event.moonFraction,
                               moonUp: event.moonUpAtBest,
                               moonSensitive: event.moonSensitive)
        return RarityScore(score: value, reason: reason(for: event, calendar: calendar))
    }

    // MARK: Core math (exposed internally for tests)

    /// Monotonic in every axis:
    /// - tier ↑ ⇒ score ↑ (annual 50 < multi-year 70 < decade 90 base)
    /// - altitude ↑ ⇒ score ↑ while visible (saturates at 60°)
    /// - moon fraction ↑ ⇒ score ↓ when the event is moon-sensitive, with a much
    ///   softer penalty when the moon is below the horizon at prime time
    /// - visible always beats not-visible (×0.15 floor keeps the event listed,
    ///   honestly low, never notified)
    static func scoreValue(tier: RarityTier, visible: Bool, altitudeDeg: Double,
                           moonFraction: Double, moonUp: Bool,
                           moonSensitive: Bool) -> Double {
        let base: Double
        switch tier {
        case .annual: base = 50.0
        case .multiYear: base = 70.0
        case .decade: base = 90.0
        }
        let visibilityFactor = visible
            ? 0.7 + 0.3 * min(max(altitudeDeg, 0.0) / 60.0, 1.0)
            : 0.15
        let fraction = min(max(moonFraction, 0.0), 1.0)
        let moonFactor = moonSensitive
            ? (moonUp ? 1.0 - 0.6 * fraction : 1.0 - 0.15 * fraction)
            : 1.0
        return min(100.0, max(0.0, base * visibilityFactor * moonFactor))
    }

    // MARK: Reason line

    /// "Perseids peak Tue — new moon, radiant 52° up at 2 am".
    /// The weekday names the *evening* of the observing night (an event whose best
    /// time is 2 am belongs to the previous evening — the night you actually go out).
    /// Solar eclipses are daytime events: a 10 am eclipse belongs to its own day,
    /// never the previous evening (same anchoring as the planner's fire date).
    static func reason(for event: SkyEvent, calendar: Calendar) -> String {
        var anchor = event.visibility.bestTime ?? event.date
        if event.kind != .solarEclipse, calendar.component(.hour, from: anchor) < 12 {
            anchor = anchor.addingTimeInterval(-43_200)   // pre-noon → previous evening
        }
        let weekdayIndex = calendar.component(.weekday, from: anchor) - 1
        let symbols = calendar.shortWeekdaySymbols
        let weekday = symbols.indices.contains(weekdayIndex) ? symbols[weekdayIndex] : ""

        let verb = event.kind == .meteorShower ? " peak " : " "
        var parts: [String] = []
        if event.moonSensitive {
            parts.append(moonPhrase(fraction: event.moonFraction, up: event.moonUpAtBest))
        }
        parts.append(event.visibility.note)
        return "\(event.name)\(verb)\(weekday) — \(parts.joined(separator: ", "))"
    }

    /// Honest moonlight phrasing for moon-sensitive events.
    static func moonPhrase(fraction: Double, up: Bool) -> String {
        switch fraction {
        case ..<0.08: return "new moon"
        case ..<0.35: return up ? "thin crescent moon" : "crescent moon out of the way"
        case ..<0.65: return up ? "half-lit moon up" : "half-lit moon, down at prime time"
        case ..<0.92: return up ? "bright gibbous moon up" : "bright moon, but down at prime time"
        default: return up ? "full moon washes out faint streaks" : "full moon rises into the night"
        }
    }
}
