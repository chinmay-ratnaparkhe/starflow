import SwiftUI

// MARK: - Field guide content model
//
// Long-form in-app articles for the Learn tab: the stacking physics, the
// hardware truths from the bench runs, and the planning craft behind the
// shot modes. Pure content structs plus the scrollable rich page that
// renders one article; LearnView wires the rows into its Field Guide section.

struct FieldGuideArticle: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let minutesToRead: Int
    let sections: [FieldGuideSection]
}

/// One block of an article: a heading, body copy (paragraphs separated by
/// blank lines), and an optional takeaway rendered as an accented callout card.
struct FieldGuideSection: Identifiable {
    let heading: String
    let body: String
    let takeaway: String?
    var id: String { heading }
    init(heading: String, body: String, takeaway: String? = nil) {
        self.heading = heading; self.body = body; self.takeaway = takeaway
    }
}

// MARK: - Library

enum FieldGuideLibrary {

    static let all: [FieldGuideArticle] = [stackingPhysics, gimbalSchool, cityShooting, readingTheSky]

    // MARK: Why 1-second exposures beat long ones

    static let stackingPhysics = FieldGuideArticle(
        id: "stacking-physics",
        title: "Why 1-second exposures beat long ones",
        subtitle: "The honest physics of stacking — and what a phone can really do at night.",
        symbol: "square.stack.3d.up.fill",
        minutesToRead: 4,
        sections: [
            FieldGuideSection(
                heading: "The cap nobody advertises",
                body: "iOS caps camera exposure for third-party apps at one second — a hard "
                    + "ceiling, not a StarFlow limitation. No app on the App Store can hold the "
                    + "shutter open for thirty seconds the way a dedicated camera can.\n\n"
                    + "StarFlow doesn't fight the cap; it works with it. Every \"long exposure\" "
                    + "in this app is really hundreds of 1-second RAW frames — subs — captured "
                    + "back to back and combined. The bench-measured duty cycle is 95–100%, so "
                    + "almost no photons are wasted between frames."),
            FieldGuideSection(
                heading: "Noise averages out, signal doesn't",
                body: "Each sub holds the same faint signal buried in random noise. Stack N "
                    + "aligned subs and the signal adds up N times over, while random noise "
                    + "grows only as the square root of N — so the signal-to-noise ratio "
                    + "improves by √N.\n\n"
                    + "Stack 600 subs and faint detail stands roughly 24 times further clear of "
                    + "the noise than in any single frame. That's why the Milky Way's dust "
                    + "lanes, invisible in one exposure, emerge from ten minutes of integration.",
                takeaway: "SNR grows with the square root of frame count: 4× the subs buys 2× "
                    + "the clarity. Depth is bought in minutes, not megapixels."),
            FieldGuideSection(
                heading: "The honest fine print",
                body: "A stack isn't quite free. The sensor adds a pinch of read noise every "
                    + "time a frame is read out, so 600 one-second subs carry 600 doses of it "
                    + "where a single 600-second exposure would carry one. On modern phone "
                    + "sensors read noise is small — but it's real, and it's why a stack is a "
                    + "long exposure minus a modest tax.\n\n"
                    + "The bigger caveat is skyglow. Stacking lifts faint signal above random "
                    + "noise; it cannot subtract a sky that is genuinely brighter than your "
                    + "target. Light pollution stacks just as faithfully as starlight — which "
                    + "is why the Milky Way still demands dark skies no matter how many frames "
                    + "you throw at it."),
            FieldGuideSection(
                heading: "What short subs win",
                body: "At one second, stars don't trail: the NPF rule for an iPhone's optics "
                    + "lands almost exactly at one second, so every sub is sharp without a "
                    + "tracking mount. A plane, satellite or passing cloud ruins one second of "
                    + "data instead of the whole night — the stacker's kappa-sigma filter "
                    + "quietly discards the damage.\n\n"
                    + "Short subs also never blow out: bright stars keep their color instead "
                    + "of clipping to white. And alignment happens in software, frame by frame "
                    + "— which is how StarFlow cancels gimbal drift and field rotation without "
                    + "precision hardware."),
            FieldGuideSection(
                heading: "The bottom line",
                body: "Six hundred 1-second subs come out close to one 10-minute exposure, "
                    + "minus a small read-noise tax, plus enormous robustness: no tracking "
                    + "mount, no ruined nights, no clipped stars.\n\n"
                    + "It's also the only long exposure a phone can honestly do — and knowing "
                    + "that is the difference between being disappointed by the cap and using "
                    + "it well."),
        ])

    // MARK: Gimbal school

    static let gimbalSchool = FieldGuideArticle(
        id: "gimbal-school",
        title: "Gimbal school",
        subtitle: "What the bench runs taught us about turning a selfie stabilizer into a telescope mount.",
        symbol: "gyroscope",
        minutesToRead: 4,
        sections: [
            FieldGuideSection(
                heading: "A stabilizer, moonlighting",
                body: "The Flow 2 Pro is a camera stabilizer that Apple's DockKit lets apps "
                    + "steer — pan and tilt are motorized and commandable, roll is inert. The "
                    + "roll the sky accumulates (field rotation) gets removed in software "
                    + "during stacking instead.\n\n"
                    + "The commandable tilt envelope runs from −38.4° to +27.5°. The galactic "
                    + "core, riding low, fits comfortably; the zenith never will. When a "
                    + "target sits outside the envelope, StarFlow says so up front rather "
                    + "than letting the motors refuse mid-session."),
            FieldGuideSection(
                heading: "The trigger is the handshake",
                body: "The gimbal doesn't hand any app its motors by default — it exposes an "
                    + "authority gate the app can read but not flip. One squeeze of the "
                    + "physical trigger grants control; that's the entire ceremony.\n\n"
                    + "StarFlow watches the gate and prompts you during Connect if authority "
                    + "is missing. After the phone re-docks, authority restores itself — no "
                    + "second squeeze needed.",
                takeaway: "If the mount ever ignores the app, squeeze the trigger once. That "
                    + "fix solves more stalled sessions than every other fix combined."),
            FieldGuideSection(
                heading: "The Free Tilt collar",
                body: "The collar on the tilt arm unlocks the axis for manual reframing — "
                    + "handy in daylight, fatal at night. Left open, the head sags under the "
                    + "phone's weight and motorized tilt commands go nowhere, which smears a "
                    + "stack in ways that look like mysterious tracking failure.\n\n"
                    + "It's the first thing to check when framing slowly slides: click the "
                    + "collar back to locked and the axis is a rock again. Every gimbal-mode "
                    + "checklist in this app starts with it for a reason."),
            FieldGuideSection(
                heading: "Cable slack and the nap habit",
                body: "Charging while shooting is smart on multi-hour sessions — but pan "
                    + "moves wind the cable around the base, so StarFlow budgets net pan to "
                    + "±360° and you should leave a generous service loop. A taut cable "
                    + "mid-slew is how framing dies quietly.\n\n"
                    + "The bench also caught the mount dozing: over long idle stretches the "
                    + "connection can drop and re-dock on its own, taking about ten seconds. "
                    + "StarFlow sends a keep-alive micro-pulse every 15 seconds to prevent "
                    + "the nap — and if a re-dock happens anyway, it pauses capture and rides "
                    + "it out."),
            FieldGuideSection(
                heading: "How StarFlow actually steers",
                body: "There is no reliable \"go to angle\" command: absolute moves under "
                    + "about 1.5° are ignored outright, and the bench showed the orientation "
                    + "API destabilizing the session. So StarFlow steers with velocity "
                    + "impulses — spin at a known rate for a known time and you've moved a "
                    + "known angle. A 0.5° nudge is roughly 0.05 rad/s held for 175 ms, "
                    + "landing within about 0.15°; the 4 Hz encoder then closes the loop.\n\n"
                    + "Velocity commands self-expire after about 2.6 seconds, so sustained "
                    + "slews are re-issued every two. True sidereal tracking sits below the "
                    + "motors' speed floor entirely — which is why the app tracks the sky in "
                    + "small step-and-shoot nudges every 90–120 seconds instead of one "
                    + "continuous crawl.\n\n"
                    + "One last bench truth: a re-dock can recenter the gimbal (a +22° pitch "
                    + "jump was measured), so StarFlow never assumes pointing survived an "
                    + "interruption — it re-verifies aim before capture resumes."),
        ])

    // MARK: Shooting from the city

    static let cityShooting = FieldGuideArticle(
        id: "city-shooting",
        title: "Shooting from the city",
        subtitle: "What genuinely works under Bortle 8–9 skyglow — and what to save for a road trip.",
        symbol: "building.2.fill",
        minutesToRead: 3,
        sections: [
            FieldGuideSection(
                heading: "Know what skyglow does",
                body: "City light scattered back down by the atmosphere raises the sky's "
                    + "brightness floor. Anything fainter than that floor never reaches the "
                    + "sensor as separable signal — and stacking, for all its power, can only "
                    + "amplify what arrived. Under Bortle 8–9 the floor sits high enough that "
                    + "the Milky Way, faint nebulae and most meteors are simply gone.\n\n"
                    + "The good news: the floor is a filter, not a wall. Everything brighter "
                    + "than it behaves almost as if the city weren't there."),
            FieldGuideSection(
                heading: "The city winners",
                body: "The Moon is daylight-bright and doesn't care where you stand — Lunar "
                    + "Detail works from a downtown balcony exactly as well as a mountaintop. "
                    + "Planets are next: Venus and Jupiter outshine every star, so "
                    + "Conjunction runs happily over rooftops.\n\n"
                    + "Star Trails is the city's signature deep shot — the arcs are drawn by "
                    + "the sky's brightest stars, which punch through the glow. An ISS pass "
                    + "at magnitude −3 beats them all. And City Nights turns the skyline "
                    + "itself into the subject, where light pollution stops being the villain "
                    + "and becomes the picture.",
                takeaway: "From Bortle 8–9, reach for: Lunar Detail, Conjunction, Star "
                    + "Trails, ISS Pass, City Nights, and Night Timelapse over the skyline."),
            FieldGuideSection(
                heading: "What to skip — and why it's not close",
                body: "Milky Way Stack needs light that skyglow buries before it hits the "
                    + "sensor; from Bortle 8 the shot does not exist, and the Tonight verdict "
                    + "will say so plainly. Meteor Shower fares nearly as badly — all but "
                    + "rare fireballs vanish into the glow.\n\n"
                    + "Aurora from a mid-latitude city needs a once-a-decade storm. None of "
                    + "this is a settings problem: no ISO, mode or app choice changes what "
                    + "light survived the trip down."),
            FieldGuideSection(
                heading: "Work the conditions you have",
                body: "Keep direct light sources out of frame — a single streetlight beats "
                    + "any star and prints halos across the stack. Shoot higher rather than "
                    + "lower: glow thickens dramatically toward the horizon, and the sky two "
                    + "hand-spans up is noticeably cleaner.\n\n"
                    + "The hours after midnight help twice — many cities dim signage and "
                    + "office towers, and the air often steadies. Best of all is the night "
                    + "after rain, when the aerosols that scatter light have been washed out "
                    + "and transparency spikes."),
            FieldGuideSection(
                heading: "Flip your moon strategy",
                body: "In dark country, moonlight is the enemy that washes out the faint "
                    + "stuff. In the city the sky is already bright, so a full moon costs "
                    + "almost nothing — the floor barely moves.\n\n"
                    + "So invert the calendar: spend bright-moon weeks on Lunar Detail and "
                    + "Star Trails from home, and bank the new-moon weekends for the "
                    + "dark-sky drives where they actually pay."),
        ])

    // MARK: Reading tonight's sky

    static let readingTheSky = FieldGuideArticle(
        id: "reading-the-sky",
        title: "Reading tonight's sky",
        subtitle: "Moonlight, darkness windows and core season — the three dials behind every Tonight verdict.",
        symbol: "moon.stars.fill",
        minutesToRead: 3,
        sections: [
            FieldGuideSection(
                heading: "Three questions decide the night",
                body: "Every Tonight verdict boils down to: how dark does it truly get, "
                    + "where is the Moon and how lit is it, and is your target actually above "
                    + "the horizon during that darkness?\n\n"
                    + "StarFlow computes all three from pure ephemeris math — no network, no "
                    + "forecast feeds. Learn to read the same three dials and you can plan a "
                    + "shooting week from anywhere."),
            FieldGuideSection(
                heading: "Darkness comes in stages",
                body: "Twilight is measured by how far the Sun sits below the horizon. At −6° "
                    + "(civil) skylines glow and only planets show. At −12° (nautical) the "
                    + "bright stars arrive — and the conjunction window is closing. Real "
                    + "darkness begins at −18°: astronomical twilight ends and the sky is as "
                    + "dark as it will ever get.\n\n"
                    + "Your darkness window is the stretch between evening and morning "
                    + "astronomical twilight. It shrinks with latitude and season — at high "
                    + "latitudes near midsummer it can vanish entirely, and the app will tell "
                    + "you the sky never fully darkens tonight."),
            FieldGuideSection(
                heading: "The Moon is a floodlight on a timer",
                body: "Moonlight is skyglow you can predict. A full moon can wash a rural sky "
                    + "to suburban brightness; a crescent barely matters. Two numbers tell the "
                    + "story: the illuminated fraction and the Moon's altitude — a bright "
                    + "moon below the horizon costs nothing.\n\n"
                    + "That second number is the trick. Moonrise and moonset carve usable "
                    + "dark hours out of moon-bright nights, so a 90%-lit moon that sets at "
                    + "1 a.m. still leaves a pristine pre-dawn window.",
                takeaway: "Don't write off a bright-moon night — check when the Moon sets. "
                    + "The hours between moonset and morning twilight are full dark."),
            FieldGuideSection(
                heading: "Core season",
                body: "The galactic core — the bright, structured heart of the Milky Way — "
                    + "sits in Sagittarius, and Earth's orbit decides when it shares the "
                    + "night. From northern mid-latitudes it's a pre-dawn object in late "
                    + "winter, up all night by June, an evening object through October, and "
                    + "lost behind the Sun from November to January.\n\n"
                    + "It also never climbs very high from the north — which, for once, is "
                    + "luck: it keeps the core inside the gimbal's tilt envelope. The farther "
                    + "south you live, the higher and longer it rides."),
            FieldGuideSection(
                heading: "Putting it together",
                body: "The premium nights are simply the intersections: astronomical darkness "
                    + "in progress, Moon down or under a quarter lit, target above the "
                    + "horizon and inside the mount's reach. That intersection is precisely "
                    + "what the feasibility gate behind each shot card computes.\n\n"
                    + "Plan a week out: find the new moon, check when your target crosses "
                    + "the darkness window, and let the weather pick the winner among those "
                    + "nights."),
        ])
}

// MARK: - Row (used by LearnView's Field Guide section)

struct FieldGuideRow: View {
    let article: FieldGuideArticle
    let night: Bool

    var body: some View {
        SFCard {
            HStack(spacing: 12) {
                Image(systemName: article.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent(night))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.accent(night).opacity(0.1))
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(article.title)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(article.subtitle)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .lineLimit(2)
                    Text("\(article.minutesToRead) MIN READ")
                        .font(Theme.label)
                        .kerning(0.8)
                        .foregroundStyle(Theme.secondaryText(night))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText(night))
            }
        }
    }
}

// MARK: - Article page

/// Scrollable rich page rendering one field-guide article: header, numbered
/// sections, and accented takeaway callouts. Night-mode aware via Theme.
struct FieldGuideArticleView: View {
    let article: FieldGuideArticle
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        let night = appearance.nightMode
        ZStack {
            Theme.screenBg(night).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(night)
                    ForEach(article.sections.indices, id: \.self) { i in
                        FieldGuideSectionBlock(index: i + 1,
                                               section: article.sections[i],
                                               night: night)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle(article.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(_ night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: article.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.accent(night))
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Theme.accent(night).opacity(0.1))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(Theme.title)
                        .foregroundStyle(Theme.primaryText(night))
                    Text("\(article.minutesToRead) MIN READ · \(article.sections.count) SECTIONS")
                        .font(Theme.label)
                        .kerning(0.8)
                        .foregroundStyle(Theme.secondaryText(night))
                }
            }
            Text(article.subtitle)
                .font(Theme.body)
                .foregroundStyle(Theme.secondaryText(night))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FieldGuideSectionBlock: View {
    let index: Int
    let section: FieldGuideSection
    let night: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%02d", index))
                    .font(Theme.liveValue(13))
                    .foregroundStyle(Theme.accent(night))
                Text(section.heading)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.primaryText(night))
            }
            Text(section.body)
                .font(Theme.body)
                .foregroundStyle(Theme.secondaryText(night))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let takeaway = section.takeaway {
                SFCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent(night))
                            .padding(.top, 2)
                        Text(takeaway)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.primaryText(night))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
