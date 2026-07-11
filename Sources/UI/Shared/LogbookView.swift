import SwiftUI
import CoreGraphics

/// The flight log. Every session lands here as a card — date, shot, integration
/// time, subs, and a tiny stack thumbnail — with lifetime totals up top and a
/// full landing report (plus share) one tap away. Reads `SessionStore.shared`.
@MainActor
public struct LogbookView: View {

    @ObservedObject private var appearance = Appearance.shared
    @ObservedObject private var store = SessionStore.shared

    @State private var selected: SessionRecord?

    public init() {}

    public var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                TonightStarField()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(night: night)
                        if store.records.isEmpty {
                            emptyState(night: night)
                        } else {
                            totalsCard(night: night)
                            SFSectionLabel("Sessions")
                            VStack(spacing: 12) {
                                ForEach(store.records) { record in
                                    LogbookCard(record: record,
                                                thumbnail: store.thumbnail(for: record),
                                                night: night) {
                                        selected = record
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.delete(record)
                                        } label: {
                                            Label("Delete entry", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { store.reload() }
        .sheet(item: $selected) { record in
            LogbookDetailSheet(record: record,
                               thumbnail: store.thumbnail(for: record),
                               onDelete: {
                                   store.delete(record)
                                   selected = nil
                               })
        }
    }

    // MARK: - Header

    private func header(night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Every session, logged")
                .textCase(.uppercase)
                .font(Theme.label)
                .kerning(1.2)
                .foregroundStyle(Theme.secondaryText(night))
            Text("Logbook")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundStyle(Theme.primaryText(night))
        }
        .padding(.top, 6)
    }

    // MARK: - Lifetime totals

    private func totalsCard(night: Bool) -> some View {
        let totalIntegration = store.records.reduce(0) { $0 + $1.integrationSeconds }
        let totalSubs = store.records.reduce(0) { $0 + $1.subsAccepted }
        return SFCard {
            HStack(spacing: 0) {
                SFStatChip(symbol: "book.closed.fill", value: "\(store.records.count)",
                           label: "sessions")
                SFStatChip(symbol: "clock.fill", value: TonightFormat.duration(totalIntegration),
                           label: "integrated")
                SFStatChip(symbol: "square.stack.3d.up.fill", value: "\(totalSubs)",
                           label: "subs stacked", tint: Theme.positive(night))
            }
        }
    }

    // MARK: - Empty state

    private func emptyState(night: Bool) -> some View {
        SFCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent(night))
                    Text("No sessions yet")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                }
                Text("Every stack you shoot lands here automatically — integration time, "
                     + "sub counts, and a preview of the result. Start your first session "
                     + "from the Tonight tab.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Session card

/// One row of the flight log: thumbnail, shot + date, integration + sub count.
@MainActor
private struct LogbookCard: View {
    let record: SessionRecord
    let thumbnail: CGImage?
    let night: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            SFCard {
                HStack(spacing: 12) {
                    thumbnailView
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.shotName)
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                            .lineLimit(1)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened))
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                        if record.endedEarly {
                            Text("ENDED EARLY")
                                .font(Theme.label)
                                .kerning(0.8)
                                .foregroundStyle(Theme.warning(night))
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(TonightFormat.duration(record.integrationSeconds))
                            .font(Theme.liveValue(17))
                            .foregroundStyle(Theme.primaryText(night))
                        Text("\(record.subsAccepted) subs".uppercased())
                            .font(Theme.label)
                            .kerning(0.8)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .colorMultiply(night ? Theme.nightRed : .white)
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent(night).opacity(night ? 0.15 : 0.10))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.accent(night).opacity(0.7))
                )
        }
    }
}

// MARK: - Detail sheet

/// Full landing report for one logged session: hero integration number, the
/// stack image, every stat, and a share button.
@MainActor
private struct LogbookDetailSheet: View {
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.dismiss) private var dismiss
    let record: SessionRecord
    let thumbnail: CGImage?
    let onDelete: () -> Void

    init(record: SessionRecord, thumbnail: CGImage?, onDelete: @escaping () -> Void) {
        self.record = record
        self.thumbnail = thumbnail
        self.onDelete = onDelete
    }

    var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                Theme.screenBg(night).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        heroCard(night: night)
                        stackCard(night: night)
                        statsCard(night: night)
                        deleteButton(night: night)
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle(record.shotName)
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

    // MARK: Hero

    private func heroCard(night: Bool) -> some View {
        SFCard(accent: record.endedEarly ? Theme.warning(night) : Theme.positive(night)) {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.date.formatted(date: .complete, time: .shortened).uppercased())
                    .font(Theme.label)
                    .kerning(1.2)
                    .foregroundStyle(Theme.secondaryText(night))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(TonightFormat.duration(record.integrationSeconds))
                        .font(Theme.heroNumber(48))
                        .foregroundStyle(Theme.primaryText(night))
                    Text("integrated")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                }
                if record.endedEarly {
                    Text("Ended early — \(record.subsAccepted + record.subsRejected) of "
                         + "\(record.targetSubCount) planned subs. Everything captured was kept.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning(night))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Stack image + share

    @ViewBuilder
    private func stackCard(night: Bool) -> some View {
        SFCard {
            VStack(alignment: .leading, spacing: 12) {
                SFSectionLabel("The stack")
                if let thumbnail {
                    let image = Image(decorative: thumbnail, scale: 1)
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(height: 220)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .colorMultiply(night ? Theme.nightRed : .white)
                    ShareLink(item: image,
                              message: Text(shareSummary),
                              preview: SharePreview("StarFlow — \(record.shotName)", image: image)) {
                        shareLabel
                    }
                    .foregroundStyle(night ? Theme.nightRed : Color.black)
                    .background(Capsule().fill(night ? Theme.nightRedDim.opacity(0.4) : Theme.gold))
                } else {
                    Text("No preview was saved with this session — the stats below are the whole story.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                    ShareLink(item: shareSummary) {
                        shareLabel
                    }
                    .foregroundStyle(Theme.accent(night))
                    .background(Capsule().strokeBorder(Theme.accent(night).opacity(0.5), lineWidth: 1))
                }
            }
        }
    }

    private var shareLabel: some View {
        Label("Share this session", systemImage: "square.and.arrow.up")
            .font(Theme.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }

    private var shareSummary: String {
        "StarFlow — \(record.shotName): \(TonightFormat.duration(record.integrationSeconds)) "
        + "integrated from \(record.subsAccepted) × 1 s subs on "
        + record.date.formatted(date: .abbreviated, time: .shortened)
        + ". Stacked on an iPhone, the honest way."
    }

    // MARK: Full stats

    private func statsCard(night: Bool) -> some View {
        SFCard {
            VStack(spacing: 14) {
                SFSectionLabel("Flight record")
                HStack(spacing: 8) {
                    SFStatChip(symbol: "checkmark.circle", value: "\(record.subsAccepted)",
                               label: "accepted", tint: Theme.positive(night))
                    SFStatChip(symbol: "xmark.circle", value: "\(record.subsRejected)",
                               label: "rejected",
                               tint: record.subsRejected > 0 ? Theme.warning(night) : nil)
                    SFStatChip(symbol: "square.stack.3d.up", value: "\(record.targetSubCount)",
                               label: "planned")
                }
                HStack(spacing: 8) {
                    SFStatChip(symbol: "scope", value: "\(record.nudges)", label: "nudges")
                    SFStatChip(symbol: "arrow.triangle.2.circlepath", value: "\(record.flapsRecovered)",
                               label: "flaps recovered")
                    SFStatChip(symbol: "camera.aperture", value: acceptanceRate, label: "kept")
                }
            }
        }
    }

    private var acceptanceRate: String {
        let total = record.subsAccepted + record.subsRejected
        guard total > 0 else { return "—" }
        return TonightFormat.percent(Double(record.subsAccepted) / Double(total))
    }

    // MARK: Delete

    private func deleteButton(night: Bool) -> some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete this entry", systemImage: "trash")
                .font(Theme.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .foregroundStyle(Theme.danger(night))
        .background(Capsule().strokeBorder(Theme.danger(night).opacity(0.45), lineWidth: 1))
    }
}
