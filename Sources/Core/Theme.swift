import SwiftUI

/// StarFlow design system — Flighty × Night Sky.
/// Deep-night navy surfaces, starlight-gold accents, tabular numerals for live data,
/// and a global red night mode that swaps the full palette.
public enum Theme {

    // MARK: Palette (dark-first; night mode swaps to red-on-black)

    public static let bg = Color(red: 0.039, green: 0.055, blue: 0.102)          // #0A0E1A
    public static let surface = Color(red: 0.067, green: 0.090, blue: 0.149)     // #111726
    public static let surfaceElevated = Color(red: 0.086, green: 0.118, blue: 0.188)
    public static let gold = Color(red: 0.831, green: 0.655, blue: 0.227)        // #D4A73A
    public static let blue = Color(red: 0.420, green: 0.608, blue: 0.847)
    public static let green = Color(red: 0.298, green: 0.765, blue: 0.541)
    public static let rose = Color(red: 0.886, green: 0.376, blue: 0.435)
    public static let amber = Color(red: 0.910, green: 0.639, blue: 0.298)
    public static let text = Color(red: 0.910, green: 0.922, blue: 0.957)
    public static let textDim = Color(red: 0.541, green: 0.576, blue: 0.659)

    public static let nightRed = Color(red: 0.86, green: 0.16, blue: 0.16)
    public static let nightRedDim = Color(red: 0.45, green: 0.08, blue: 0.08)

    // MARK: Semantic accessors (respect night mode)

    public static func accent(_ night: Bool) -> Color { night ? nightRed : gold }
    public static func primaryText(_ night: Bool) -> Color { night ? nightRed : text }
    public static func secondaryText(_ night: Bool) -> Color { night ? nightRedDim : textDim }
    public static func cardBg(_ night: Bool) -> Color { night ? Color.black : surface }
    public static func screenBg(_ night: Bool) -> Color { night ? Color.black : bg }
    public static func positive(_ night: Bool) -> Color { night ? nightRed : green }
    public static func warning(_ night: Bool) -> Color { night ? nightRed : amber }
    public static func danger(_ night: Bool) -> Color { night ? nightRed : rose }

    // MARK: Typography

    public static func heroNumber(_ size: CGFloat = 44) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    public static func liveValue(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    public static let title = Font.system(.title2, design: .serif).weight(.medium)
    public static let headline = Font.system(.headline, design: .rounded)
    public static let body = Font.system(.subheadline, design: .default)
    public static let caption = Font.system(.caption, design: .rounded)
    public static let label = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

/// Global appearance state (night mode toggle persists).
@MainActor
public final class Appearance: ObservableObject {
    public static let shared = Appearance()
    @AppStorage("nightMode") public var nightMode: Bool = false { willSet { objectWillChange.send() } }
    private init() {}
}

// MARK: - Reusable components

public struct SFCard<Content: View>: View {
    @ObservedObject private var appearance = Appearance.shared
    let accent: Color?
    let content: Content
    public init(accent: Color? = nil, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }
    public var body: some View {
        let night = appearance.nightMode
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.cardBg(night))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                (accent ?? Theme.accent(night)).opacity(night ? 0.5 : 0.18),
                                lineWidth: 1)
                    )
            )
    }
}

public struct SFSectionLabel: View {
    @ObservedObject private var appearance = Appearance.shared
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        let night = appearance.nightMode
        HStack(spacing: 8) {
            Circle().fill(Theme.accent(night)).frame(width: 6, height: 6)
            Text(text.uppercased())
                .font(Theme.label)
                .kerning(1.5)
                .foregroundStyle(Theme.secondaryText(night))
        }
    }
}

public struct SFStatChip: View {
    @ObservedObject private var appearance = Appearance.shared
    let symbol: String
    let value: String
    let label: String
    var tint: Color?
    public init(symbol: String, value: String, label: String, tint: Color? = nil) {
        self.symbol = symbol; self.value = value; self.label = label; self.tint = tint
    }
    public var body: some View {
        let night = appearance.nightMode
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint ?? Theme.accent(night))
                Text(value)
                    .font(Theme.liveValue(17))
                    .foregroundStyle(Theme.primaryText(night))
            }
            Text(label.uppercased())
                .font(Theme.label)
                .kerning(0.8)
                .foregroundStyle(Theme.secondaryText(night))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(spokenValue)")
    }

    /// Expands compact chip values into natural VoiceOver speech:
    /// "12m 30s" → "12 minutes 30 seconds", "×300" → "300", "—" → "unavailable".
    private var spokenValue: String {
        if value == "—" { return "unavailable" }
        let cleaned = value.hasPrefix("×") ? String(value.dropFirst()) : value
        return cleaned.split(separator: " ")
            .map { Self.spokenToken(String($0)) }
            .joined(separator: " ")
    }

    private static func spokenToken(_ token: String) -> String {
        let units: [(suffix: String, singular: String, plural: String)] = [
            ("h", "hour", "hours"),
            ("m", "minute", "minutes"),
            ("s", "second", "seconds"),
        ]
        for unit in units where token.hasSuffix(unit.suffix) {
            let number = String(token.dropLast(unit.suffix.count))
            guard !number.isEmpty,
                  number.allSatisfy({ $0.isNumber || $0 == "/" || $0 == "." }) else { continue }
            return "\(number) \(number == "1" ? unit.singular : unit.plural)"
        }
        return token
    }
}
