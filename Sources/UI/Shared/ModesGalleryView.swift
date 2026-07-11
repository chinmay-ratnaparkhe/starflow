import SwiftUI

/// Grid of every shot mode with live feasibility dots. Tapping a tile opens a
/// detail sheet: tagline, honest expectation, recipe chips, tutorial steps,
/// and a Start button into the session.
@MainActor
public struct ModesGalleryView: View {

    @ObservedObject private var appearance = Appearance.shared
    @StateObject private var locationProvider = LocationProvider()
    @AppStorage("skyQuality") private var skyQualityRaw: Int = SkyQuality.suburb.rawValue

    @State private var context: SkyContext?
    @State private var selected: ShotModeItem?

    private let sky: SkyComputing = SkyEngine()

    public init() {}

    private var skyQuality: SkyQuality { SkyQuality(rawValue: skyQualityRaw) ?? .suburb }

    public var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                Theme.screenBg(night).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Shot library")
                                .font(.system(size: 32, weight: .bold, design: .serif))
                                .foregroundStyle(Theme.primaryText(night))
                            Text("Every StarFlow mode. On iPhone, \"long exposure\" means stacking 1-second frames — that cap is real, and every recipe here works within it.")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText(night))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 6)
                        if context == nil {
                            Text("Feasibility dots light up once your location is set on the Tonight tab.")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText(night))
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                            GridItem(.flexible(), spacing: 12)],
                                  spacing: 12) {
                            ForEach(ShotModeRegistry.all) { item in
                                ModeTile(item: item, feasibility: feasibility(for: item)) {
                                    selected = item
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .refreshable { await refreshFeasibility() }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            locationProvider.requestAccess()
            recompute(location: locationProvider.location)
        }
        .onReceive(locationProvider.$location) { newLocation in
            recompute(location: newLocation)
        }
        .sheet(item: $selected) { item in
            ModeDetailSheet(item: item, feasibility: feasibility(for: item))
        }
    }

    private func feasibility(for item: ShotModeItem) -> Feasibility? {
        guard let ctx = context else { return nil }
        return item.feasibility(ctx, skyQuality)
    }

    private func recompute(location: GeoLocation?) {
        guard let location else {
            context = nil
            return
        }
        context = sky.skyContext(at: location, date: Date())
    }

    private func refreshFeasibility() async {
        locationProvider.requestAccess()
        recompute(location: locationProvider.location)
        try? await Task.sleep(nanoseconds: 250_000_000)
    }
}

// MARK: - Grid tile

@MainActor
private struct ModeTile: View {
    @ObservedObject private var appearance = Appearance.shared
    let item: ShotModeItem
    let feasibility: Feasibility?
    let onTap: () -> Void

    init(item: ShotModeItem, feasibility: Feasibility?, onTap: @escaping () -> Void) {
        self.item = item
        self.feasibility = feasibility
        self.onTap = onTap
    }

    var body: some View {
        let night = appearance.nightMode
        Button(action: onTap) {
            SFCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.accent(night))
                        Spacer(minLength: 4)
                        Circle()
                            .fill(dotColor(night: night))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                    Text(item.name)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                        .multilineTextAlignment(.leading)
                    Text(item.tagline)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                .frame(minHeight: 108, alignment: .topLeading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name). \(item.tagline)")
        .accessibilityValue(feasibility.map(FeasibilityPresentation.label) ?? "Feasibility unknown")
        .accessibilityHint("Opens the recipe, tutorial, and start button.")
        .accessibilityAddTraits(.isButton)
    }

    private func dotColor(night: Bool) -> Color {
        guard let feasibility else {
            return Theme.secondaryText(night).opacity(0.35)
        }
        return FeasibilityPresentation.color(feasibility, night: night)
    }
}

// MARK: - Detail sheet

@MainActor
private struct ModeDetailSheet: View {
    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.dismiss) private var dismiss
    let item: ShotModeItem
    let feasibility: Feasibility?
    @State private var sessionShot: ShotModeItem?
    @State private var checkedSteps: Set<Int> = []

    init(item: ShotModeItem, feasibility: Feasibility?) {
        self.item = item
        self.feasibility = feasibility
    }

    var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                Theme.screenBg(night).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        headerBlock(night: night)
                        SFSectionLabel("What you'll get")
                        SFCard {
                            Text(item.expectation)
                                .font(Theme.body)
                                .foregroundStyle(Theme.secondaryText(night))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SFSectionLabel("Recipe")
                        recipeCard(item.recipe)
                        requirementTags(night: night)
                        SFSectionLabel("How it works")
                        tutorialCard(steps: item.tutorial, night: night)
                        if !item.checklist.isEmpty {
                            SFSectionLabel("Before you start · \(checkedSteps.count)/\(item.checklist.count)")
                            checklistCard(night: night)
                        }
                        startButton(night: night)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.secondaryText(night))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .sheet(item: $sessionShot) { shot in
            SessionView(shot: shot)
        }
    }

    private func headerBlock(night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: item.symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Theme.accent(night))
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Theme.accent(night).opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(Theme.title)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(item.tagline)
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryText(night))
                }
            }
            if let f = feasibility {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    FeasibilityBadge(feasibility: f)
                    if let note = FeasibilityPresentation.note(f) {
                        Text(note)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func recipeCard(_ recipe: CaptureRecipe) -> some View {
        let integration = recipe.exposureSeconds * Double(recipe.targetSubCount)
        return SFCard {
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    SFStatChip(symbol: "timer",
                               value: TonightFormat.exposure(recipe.exposureSeconds),
                               label: "Exposure")
                    SFStatChip(symbol: "square.stack.3d.up.fill",
                               value: "×\(recipe.targetSubCount)",
                               label: "Subs")
                    SFStatChip(symbol: "sum",
                               value: TonightFormat.duration(integration),
                               label: "Integration")
                }
                HStack(spacing: 0) {
                    SFStatChip(symbol: "camera.aperture",
                               value: "\(Int(recipe.iso))",
                               label: "ISO")
                    SFStatChip(symbol: "scope",
                               value: recipe.nudgeTracking ? "On" : "Off",
                               label: "Tracking")
                    SFStatChip(symbol: "hourglass",
                               value: recipe.intervalSeconds > 0
                                   ? TonightFormat.duration(recipe.intervalSeconds)
                                   : "None",
                               label: "Interval")
                }
            }
        }
    }

    private func requirementTags(night: Bool) -> some View {
        HStack(spacing: 8) {
            ModeTag(symbol: item.cityViable ? "building.2" : "moon.stars",
                    text: item.cityViable ? "Works in city skies" : "Needs dark skies")
            ModeTag(symbol: item.needsGimbal ? "gyroscope" : "iphone",
                    text: item.needsGimbal ? "Gimbal required" : "Phone-only OK")
        }
    }

    private func tutorialCard(steps: [TutorialStep], night: Bool) -> some View {
        SFCard {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(steps.indices, id: \.self) { i in
                    let step = steps[i]
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .strokeBorder(Theme.accent(night).opacity(0.5), lineWidth: 1)
                                .frame(width: 26, height: 26)
                            Text("\(i + 1)")
                                .font(Theme.label)
                                .foregroundStyle(Theme.accent(night))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: step.symbol)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.accent(night))
                                Text(step.title)
                                    .font(Theme.headline)
                                    .foregroundStyle(Theme.primaryText(night))
                            }
                            Text(step.body)
                                .font(Theme.caption)
                                .foregroundStyle(Theme.secondaryText(night))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// Tappable setup check rows — a pre-flight ritual, not a gate: Start stays enabled.
    private func checklistCard(night: Bool) -> some View {
        SFCard {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(item.checklist.indices, id: \.self) { i in
                    let done = checkedSteps.contains(i)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if done {
                                checkedSteps.remove(i)
                            } else {
                                checkedSteps.insert(i)
                            }
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(done ? Theme.positive(night)
                                                      : Theme.secondaryText(night).opacity(0.6))
                                .padding(.top, 1)
                            Text(item.checklist[i])
                                .font(Theme.caption)
                                .foregroundStyle(done ? Theme.secondaryText(night)
                                                      : Theme.primaryText(night))
                                .strikethrough(done, color: Theme.secondaryText(night))
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(done ? "checked" : "not checked")
                    .accessibilityHint("Toggles this setup step.")
                    if i < item.checklist.count - 1 {
                        Divider().overlay(Theme.accent(night).opacity(0.10))
                    }
                }
            }
        }
    }

    private func startButton(night: Bool) -> some View {
        Button {
            sessionShot = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text("Start this shot")
            }
            .font(Theme.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(night ? Color.black : Theme.bg)
        .background(Capsule().fill(Theme.accent(night)))
        .padding(.top, 4)
        .accessibilityLabel("Start \(item.name)")
        .accessibilityHint("Begins a live session with this recipe.")
    }
}

/// Small requirement tag: "Works in city skies", "Gimbal required", etc.
@MainActor
private struct ModeTag: View {
    @ObservedObject private var appearance = Appearance.shared
    let symbol: String
    let text: String

    init(symbol: String, text: String) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        let night = appearance.nightMode
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent(night))
            Text(text)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText(night))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.cardBg(night)))
        .overlay(Capsule().strokeBorder(Theme.accent(night).opacity(0.18), lineWidth: 1))
    }
}
