import SwiftUI
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Share card (feature 9, docs/ROADMAP-v3.md)
//
// Flighty-style landing-report card: the session's stacked photo framed on a
// deep-navy card with gold accents — wordmark, shot name, date (+ optional
// city), a stats strip, and a starfield border. Rendered offscreen with
// ImageRenderer at exact pixel sizes (1080×1920 story, 2048×2048 square).
//
// Honesty rules, enforced structurally:
//  - Every value on the card comes from the `SessionRecord` and nothing else.
//    No stat is ever invented: sky condition renders only when it was measured,
//    "Calibrated against N stars" only when the SPCC-lite fit really ran, the
//    city only when a real fix reverse-geocoded, and simulated sessions carry
//    the SIMULATED tag onto the card itself.
//  - The card is night-mode INDEPENDENT: it always uses the daylight palette
//    (cards are for daylight sharing). Only the in-app preview is red-tinted
//    in night mode to protect dark adaptation.

// MARK: - Format

/// Export variants. Pixel sizes are exact; layout is designed in a 1080-wide
/// space and scaled by `designScale` so both variants share one design.
public enum ShareCardFormat: String, CaseIterable, Identifiable, Sendable {
    case story
    case square

    public var id: String { rawValue }

    public var pixelSize: CGSize {
        switch self {
        case .story: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 2048, height: 2048)
        }
    }

    public var displayName: String {
        switch self {
        case .story: return "Story"
        case .square: return "Square"
        }
    }

    /// Layout scale relative to the 1080-wide design space.
    public var designScale: CGFloat { pixelSize.width / ShareCardLayout.designWidth }
}

// MARK: - Pure layout math (unit-tested)

public enum ShareCardLayout {

    /// The width every dimension in the card is designed against.
    public static let designWidth: CGFloat = 1080

    /// Horizontal content padding in design units (scaled by `designScale`).
    public static let horizontalPadding: CGFloat = 72

    /// Largest size with `image`'s aspect ratio that fits inside `bounds`.
    /// Small images (the logbook's 256 px thumbnail) upscale to fill the
    /// frame — aspect ratio is always preserved exactly. Degenerate input
    /// (zero/negative area) returns .zero rather than NaN.
    public static func aspectFit(image: CGSize, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// The box the photo may occupy on a card of `cardSize` (pixel space):
    /// full content width, and a height share tuned per orientation — tall
    /// story cards give the photo more vertical room than square ones.
    public static func imageBounds(cardSize: CGSize) -> CGSize {
        guard cardSize.width > 0, cardSize.height > 0 else { return .zero }
        let s = cardSize.width / designWidth
        let width = cardSize.width - 2 * horizontalPadding * s
        let tall = cardSize.height > cardSize.width
        let height = cardSize.height * (tall ? 0.50 : 0.42)
        return CGSize(width: max(0, width), height: max(0, height))
    }
}

// MARK: - Pure stat formatting (unit-tested)

/// Builds the card's text content from a `SessionRecord` — and ONLY from a
/// `SessionRecord`. Anything the record does not hold simply is not rendered.
public enum ShareCardStats {

    public struct Stat: Equatable, Sendable {
        public var value: String
        public var label: String
        public init(value: String, label: String) {
            self.value = value; self.label = label
        }
    }

    /// The stats strip: integration and subs always (every record holds them),
    /// sky condition only when the monitor actually graded the sky.
    public static func strip(for record: SessionRecord) -> [Stat] {
        var stats = [
            Stat(value: TonightFormat.duration(record.integrationSeconds), label: "integrated"),
            Stat(value: "\(record.subsAccepted)", label: "subs stacked"),
        ]
        if let sky = record.skyCondition, sky != .unknown {
            stats.append(Stat(value: sentenceCase(sky.displayName), label: "sky"))
        }
        return stats
    }

    /// "Calibrated against 12 stars" — only when the star-colour calibration
    /// really ran and fitted against that many catalog stars. nil otherwise.
    public static func calibrationLine(for record: SessionRecord) -> String? {
        guard let count = record.calibrationStars, count > 0 else { return nil }
        return "Calibrated against \(count) star\(count == 1 ? "" : "s")"
    }

    /// "Jul 17, 2026 at 9:41 PM" plus " · City" when the record holds a city
    /// AND the user chose to include it.
    public static func dateLine(for record: SessionRecord, includeLocation: Bool) -> String {
        var line = record.date.formatted(date: .abbreviated, time: .shortened)
        if includeLocation, let city = record.locationCity, !city.isEmpty {
            line += " · \(city)"
        }
        return line
    }

    /// "clear" → "Clear", "too bright" → "Too bright" (first letter only —
    /// these are sentence fragments, not title-case headlines).
    static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

// MARK: - Card view (always daylight palette)

/// The card itself. Rendered offscreen at exact pixel size — every dimension
/// is a design-space value multiplied by the format's scale. Deliberately does
/// NOT read `Appearance.shared`: share cards are for daylight sharing.
struct ShareCardView: View {
    let record: SessionRecord
    let image: CGImage?
    let format: ShareCardFormat
    let includeLocation: Bool

    var body: some View {
        let size = format.pixelSize
        let s = format.designScale
        let simulated = record.simulatedCapture ?? false
        ZStack {
            Theme.bg
            CardStarfieldBorder(band: 60 * s, goldTint: Theme.gold)
            RoundedRectangle(cornerRadius: 36 * s, style: .continuous)
                .strokeBorder(Theme.gold.opacity(0.35), lineWidth: max(1, 1.5 * s))
                .padding(28 * s)
            VStack(spacing: 0) {
                header(scale: s, simulated: simulated)
                Spacer(minLength: 24 * s)
                photo(cardSize: size, scale: s)
                Spacer(minLength: 24 * s)
                statsBlock(scale: s)
            }
            .padding(.horizontal, ShareCardLayout.horizontalPadding * s)
            .padding(.vertical, 88 * s)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Header — wordmark, shot name, date/location

    private func header(scale s: CGFloat, simulated: Bool) -> some View {
        VStack(spacing: 18 * s) {
            HStack(spacing: 12 * s) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24 * s, weight: .semibold))
                Text("STARFLOW")
                    .font(.system(size: 24 * s, weight: .bold, design: .rounded))
                    .kerning(7 * s)
            }
            .foregroundStyle(Theme.gold)
            Text(record.shotName)
                .font(.system(size: 58 * s, weight: .medium, design: .serif))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            Text(ShareCardStats.dateLine(for: record, includeLocation: includeLocation).uppercased())
                .font(.system(size: 22 * s, weight: .semibold, design: .monospaced))
                .kerning(2 * s)
                .foregroundStyle(Theme.textDim)
            if simulated {
                Text("SIMULATED")
                    .font(.system(size: 20 * s, weight: .bold, design: .monospaced))
                    .kerning(2.5 * s)
                    .foregroundStyle(Theme.rose)
                    .padding(.horizontal, 16 * s)
                    .padding(.vertical, 7 * s)
                    .background(
                        Capsule()
                            .fill(Theme.rose.opacity(0.14))
                            .overlay(Capsule().strokeBorder(Theme.rose.opacity(0.55),
                                                            lineWidth: max(1, 1.5 * s)))
                    )
            }
        }
    }

    // MARK: Photo — aspect-fit, gold hairline frame

    @ViewBuilder
    private func photo(cardSize: CGSize, scale s: CGFloat) -> some View {
        if let image {
            let fitted = ShareCardLayout.aspectFit(
                image: CGSize(width: image.width, height: image.height),
                in: ShareCardLayout.imageBounds(cardSize: cardSize))
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: fitted.width, height: fitted.height)
                .clipShape(RoundedRectangle(cornerRadius: 24 * s, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24 * s, style: .continuous)
                        .strokeBorder(Theme.gold.opacity(0.55), lineWidth: max(1, 2 * s))
                )
                .shadow(color: .black.opacity(0.55), radius: 28 * s, y: 10 * s)
        }
    }

    // MARK: Stats strip + calibration + honest footer

    private func statsBlock(scale s: CGFloat) -> some View {
        let stats = ShareCardStats.strip(for: record)
        return VStack(spacing: 22 * s) {
            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                    if index > 0 {
                        Rectangle()
                            .fill(Theme.gold.opacity(0.3))
                            .frame(width: max(1, 1 * s), height: 52 * s)
                    }
                    VStack(spacing: 8 * s) {
                        Text(stat.value)
                            .font(.system(size: 44 * s, weight: .semibold, design: .rounded)
                                .monospacedDigit())
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(stat.label.uppercased())
                            .font(.system(size: 17 * s, weight: .semibold, design: .monospaced))
                            .kerning(1.5 * s)
                            .foregroundStyle(Theme.textDim)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let calibration = ShareCardStats.calibrationLine(for: record) {
                HStack(spacing: 8 * s) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 19 * s, weight: .semibold))
                    Text(calibration)
                        .font(.system(size: 22 * s, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Theme.gold)
            }
            Rectangle()
                .fill(Theme.gold.opacity(0.25))
                .frame(width: 220 * s, height: max(1, 1 * s))
            Text("Stacked on an iPhone, the honest way")
                .font(.system(size: 20 * s, weight: .regular, design: .serif))
                .italic()
                .foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Starfield border

/// Deterministic scatter of small stars kept to a band around the card's edge
/// (rejection sampling with a hard iteration bound, seeded so the same card
/// renders identically every time). Mostly white pinpricks; every seventh is
/// gold to tie into the accent.
private struct CardStarfieldBorder: View {
    let band: CGFloat
    let goldTint: Color

    var body: some View {
        Canvas { canvas, size in
            let inner = CGRect(x: band, y: band,
                               width: size.width - 2 * band,
                               height: size.height - 2 * band)
            var rng = CardSeededRandom(seed: 9)
            var placed = 0
            var iterations = 0
            while placed < 110 && iterations < 2200 {
                iterations += 1
                let x = rng.next() * size.width
                let y = rng.next() * size.height
                let opacity = 0.18 + rng.next() * 0.5
                let radius = (0.7 + rng.next() * 1.4) * (band / 60)
                guard !inner.contains(CGPoint(x: x, y: y)) else { continue }
                placed += 1
                let color = (placed % 7 == 0 ? goldTint : Color.white).opacity(opacity)
                canvas.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2)),
                    with: .color(color))
            }
        }
    }
}

/// Deterministic xorshift so the border stars never shift between renders.
private struct CardSeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

#if canImport(UIKit)

// MARK: - Offscreen renderer

/// Renders the card to a UIImage at the format's exact pixel size
/// (`renderer.scale = 1`, view framed at pixel dimensions).
@MainActor
enum ShareCardRenderer {
    static func render(record: SessionRecord, image: CGImage?,
                       format: ShareCardFormat, includeLocation: Bool) -> UIImage? {
        let renderer = ImageRenderer(content: ShareCardView(record: record,
                                                            image: image,
                                                            format: format,
                                                            includeLocation: includeLocation))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - In-app share section (landing report + logbook)

/// The share block used by the landing report and the logbook detail sheet:
/// live card preview, format picker (story / square), the opt-in location
/// toggle (OFF by default — privacy), and two ShareLinks — the CARD by
/// default, the raw stack second.
/// Night-aware in its chrome; the card itself stays daylight.
@MainActor
struct ShareCardSection: View {
    let record: SessionRecord
    let image: CGImage
    let night: Bool
    /// Optional message attached to the raw-image share (logbook parity).
    var rawShareMessage: String? = nil

    @State private var format: ShareCardFormat = .story
    /// Location privacy: the city line is strictly opt-in, so this defaults
    /// OFF — sharing a card never reveals where the user was unless they
    /// flip the toggle themselves, every time.
    @State private var includeLocation = false
    @State private var card: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SFSectionLabel("Share card")
            preview
            Picker("Card format", selection: $format) {
                ForEach(ShareCardFormat.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Card format")
            if let city = record.locationCity, !city.isEmpty {
                Toggle(isOn: $includeLocation) {
                    Text("Show location — \(city)")
                        .font(Theme.body)
                        .foregroundStyle(Theme.primaryText(night))
                }
                .tint(Theme.accent(night))
            }
            if night {
                Text("The card shares in full daylight color — the red preview is just protecting your eyes.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
            cardShareLink
            rawShareLink
        }
        .task(id: "\(format.rawValue)|\(includeLocation)") {
            card = ShareCardRenderer.render(record: record, image: image,
                                            format: format,
                                            includeLocation: includeLocation)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let card {
            Image(uiImage: card)
                .resizable()
                .scaledToFit()
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .colorMultiply(night ? Theme.nightRed : .white)
                .accessibilityLabel("Share card preview for \(record.shotName)")
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent(night).opacity(0.08))
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .overlay(ProgressView().tint(Theme.accent(night)))
                .accessibilityLabel("Share card rendering")
        }
    }

    @ViewBuilder
    private var cardShareLink: some View {
        if let card {
            let cardImage = Image(uiImage: card)
            ShareLink(item: cardImage,
                      preview: SharePreview("StarFlow — \(record.shotName)", image: cardImage)) {
                Label("Share the card", systemImage: "square.and.arrow.up")
                    .font(Theme.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .foregroundStyle(night ? Theme.nightRed : Color.black)
            .background(Capsule().fill(night ? Theme.nightRedDim.opacity(0.4) : Theme.gold))
        }
    }

    private var rawShareLink: some View {
        let raw = Image(decorative: image, scale: 1)
        return ShareLink(item: raw,
                         message: rawShareMessage.map { Text($0) },
                         preview: SharePreview("StarFlow — \(record.shotName)", image: raw)) {
            Label("Share the raw image", systemImage: "photo")
                .font(Theme.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .foregroundStyle(Theme.accent(night))
        .background(Capsule().strokeBorder(Theme.accent(night).opacity(0.5), lineWidth: 1))
    }
}

#endif
