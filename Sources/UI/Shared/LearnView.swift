import SwiftUI

/// Learn tab: every shot mode's tutorial, the field-guide articles, plus a
/// glossary of the words the app uses.
struct LearnView: View {
    @ObservedObject private var appearance = Appearance.shared

    init() {}

    var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                Theme.screenBg(night).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Field guide to shooting the sky with a gimbal — what each mode does, and the words that come with it.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.secondaryText(night))
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 10) {
                            SFSectionLabel("Shot tutorials")
                            ForEach(ShotModeRegistry.all) { item in
                                NavigationLink {
                                    ModeTutorialDetail(item: item)
                                } label: {
                                    ModeRow(item: item, night: night)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the \(item.name) tutorial.")
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            SFSectionLabel("Field guide")
                            ForEach(FieldGuideLibrary.all) { article in
                                NavigationLink {
                                    FieldGuideArticleView(article: article)
                                } label: {
                                    FieldGuideRow(article: article, night: night)
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the \(article.title) article.")
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            SFSectionLabel("Glossary")
                            ForEach(glossaryTerms) { term in
                                GlossaryCard(term: term, night: night)
                            }
                        }
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Learn")
            .toolbarBackground(Theme.screenBg(night), for: .navigationBar)
        }
    }
}

// MARK: - Mode row

private struct ModeRow: View {
    let item: ShotModeItem
    let night: Bool

    var body: some View {
        SFCard {
            HStack(spacing: 12) {
                Image(systemName: item.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent(night))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.accent(night).opacity(0.1))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(item.tagline)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if !item.cityViable {
                            TagBadge(text: "Dark sky", night: night)
                        }
                        if item.needsGimbal {
                            TagBadge(text: "Gimbal", night: night)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText(night))
            }
        }
    }
}

private struct TagBadge: View {
    let text: String
    let night: Bool

    var body: some View {
        Text(text.uppercased())
            .font(Theme.label)
            .kerning(0.8)
            .foregroundStyle(Theme.secondaryText(night))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().strokeBorder(Theme.secondaryText(night).opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Tutorial detail

private struct ModeTutorialDetail: View {
    let item: ShotModeItem
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        let night = appearance.nightMode
        ZStack {
            Theme.screenBg(night).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(night)

                    VStack(alignment: .leading, spacing: 10) {
                        SFSectionLabel("What you'll actually get")
                        SFCard(accent: Theme.warning(night)) {
                            Text(item.expectation)
                                .font(Theme.body)
                                .foregroundStyle(Theme.primaryText(night))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SFSectionLabel("Recipe")
                        SFCard {
                            HStack(spacing: 8) {
                                SFStatChip(symbol: "timer",
                                           value: String(format: "%.1f s", item.recipe.exposureSeconds),
                                           label: "exposure")
                                SFStatChip(symbol: "camera.aperture",
                                           value: "\(Int(item.recipe.iso))",
                                           label: "ISO")
                                SFStatChip(symbol: "square.stack.3d.up",
                                           value: "\(item.recipe.targetSubCount)",
                                           label: "subs")
                                SFStatChip(symbol: "location.north.line",
                                           value: item.recipe.nudgeTracking ? "On" : "Off",
                                           label: "tracking")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SFSectionLabel("How to shoot it")
                        ForEach(item.tutorial) { step in
                            NumberedStepCard(step: step, night: night)
                        }
                    }

                    if !item.cityViable {
                        Text("Needs a dark sky — city glow washes this one out. StarFlow's Tonight verdict will say so too.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ night: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accent(night))
                .frame(width: 64, height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.accent(night).opacity(0.1))
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                Text(item.tagline)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
                HStack(spacing: 6) {
                    if !item.cityViable {
                        TagBadge(text: "Dark sky", night: night)
                    }
                    if item.needsGimbal {
                        TagBadge(text: "Gimbal", night: night)
                    }
                }
            }
        }
    }
}

private struct NumberedStepCard: View {
    let step: TutorialStep
    let night: Bool

    var body: some View {
        SFCard {
            HStack(alignment: .top, spacing: 12) {
                Text("\(step.id)")
                    .font(Theme.liveValue(14))
                    .foregroundStyle(Color.black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.accent(night)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(step.title)
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Spacer()
                        Image(systemName: step.symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent(night))
                    }
                    Text(step.body)
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Glossary

private struct GlossaryTerm: Identifiable {
    let term: String
    let definition: String
    var id: String { term }
}

private struct GlossaryCard: View {
    let term: GlossaryTerm
    let night: Bool

    var body: some View {
        SFCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(term.term)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.primaryText(night))
                Text(term.definition)
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private let glossaryTerms: [GlossaryTerm] = [
    GlossaryTerm(term: "Sub",
                 definition: "One short exposure — in StarFlow, a single 1-second RAW frame — destined for the stack. Hundreds of subs add up to one deep image."),
    GlossaryTerm(term: "Stacking",
                 definition: "Averaging many aligned subs so faint signal builds up while random noise cancels out. It's how a phone does long exposure honestly."),
    GlossaryTerm(term: "Integration",
                 definition: "The total exposure time inside a stack. 300 accepted subs at 1 second each is 5 minutes of integration."),
    GlossaryTerm(term: "Bortle",
                 definition: "A 1–9 scale of night-sky darkness — 1 is a pristine dark site, 9 is inner-city glow. Your sky-quality setting maps onto it."),
    GlossaryTerm(term: "Sidereal",
                 definition: "The rate the sky appears to turn: one full rotation in 23 h 56 m. Trackers chase it; your gimbal approximates it with small step nudges instead."),
    GlossaryTerm(term: "Field rotation",
                 definition: "The slow twist of the star field around the frame when you track with an alt-az mount like a gimbal. StarFlow removes it in software during stacking."),
    GlossaryTerm(term: "Dead-band",
                 definition: "The zone where a commanded move is too small for the motors to execute. The Flow 2 Pro ignores absolute moves under about 1.5°, so StarFlow steers with velocity impulses."),
    GlossaryTerm(term: "Authority",
                 definition: "Whether the gimbal currently accepts motor commands from the app. One trigger squeeze grants it, and it restores itself after a re-dock."),
    GlossaryTerm(term: "Plate solving",
                 definition: "Working out exactly where a photo points by matching its star pattern to a catalog — how a mount verifies aim without you squinting through it."),
    GlossaryTerm(term: "NPF",
                 definition: "A rule for the longest untracked exposure before stars streak, computed from aperture, pixel pitch and focal length. On an iPhone it lands near 1 second — conveniently what iOS allows."),
    GlossaryTerm(term: "Skyglow",
                 definition: "Artificial light scattered back down by the atmosphere, raising the sky's brightness floor. Anything fainter than the floor never reaches the sensor — which is why stacking can't fix a city sky."),
    GlossaryTerm(term: "Astronomical darkness",
                 definition: "When the Sun sits more than 18° below the horizon and stops brightening the sky at all. The window between evening and morning astronomical twilight is prime time for faint targets."),
    GlossaryTerm(term: "Galactic core",
                 definition: "The bright, dust-laced center of the Milky Way in Sagittarius — the part people mean by \"Milky Way shot.\" It keeps seasons: northern-hemisphere nights show it roughly March through October."),
    GlossaryTerm(term: "Terminator",
                 definition: "The moving line between lunar day and night. Shadows stretch longest there, so craters show maximum relief — it's where every good Moon shot lives."),
    GlossaryTerm(term: "Radiant",
                 definition: "The point a meteor shower's streaks trace back to, named for its host constellation. Meteors look longest 30–45° away from it, which is where you aim."),
    GlossaryTerm(term: "Kappa-sigma",
                 definition: "The stacker's bouncer: any pixel too many standard deviations from the running mean gets thrown out. It's how planes, satellites and cosmic-ray hits vanish from the final stack."),
    GlossaryTerm(term: "Read noise",
                 definition: "The small error a sensor adds every time it reads a frame out. It's the tax stacking pays versus one long exposure — and the reason more, shorter subs aren't entirely free."),
    GlossaryTerm(term: "Kp index",
                 definition: "A 0–9 scale of geomagnetic storminess. Kp 5 gives high latitudes an aurora chance; mid-latitudes usually need a rare Kp 8–9 storm. StarFlow doesn't fetch it — check a space-weather app."),
]
