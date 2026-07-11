import Foundation

// MARK: - ShotModeItem
//
// Value-type shot mode used across Tonight, the modes gallery, and SessionView.
// Field order and names are a cross-module contract — do not reorder.

public struct ShotModeItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let tagline: String
    public let symbol: String
    public let recipe: CaptureRecipe
    public let expectation: String
    public let tutorial: [TutorialStep]
    /// Setup checklist rendered as tappable check rows in the mode detail sheet
    /// (see ModeExtras.swift for the per-mode content). Defaulted so pre-checklist
    /// call sites keep compiling.
    public let checklist: [String]
    public let cityViable: Bool
    public let needsGimbal: Bool
    /// Tonight-gate. Call as `shot.feasibility(sky, quality)`.
    public let feasibility: @Sendable (SkyContext, SkyQuality) -> Feasibility

    public init(id: String, name: String, tagline: String, symbol: String,
                recipe: CaptureRecipe, expectation: String, tutorial: [TutorialStep],
                checklist: [String] = [],
                cityViable: Bool, needsGimbal: Bool,
                feasibility: @escaping @Sendable (SkyContext, SkyQuality) -> Feasibility) {
        self.id = id; self.name = name; self.tagline = tagline; self.symbol = symbol
        self.recipe = recipe; self.expectation = expectation; self.tutorial = tutorial
        self.checklist = checklist
        self.cityViable = cityViable; self.needsGimbal = needsGimbal
        self.feasibility = feasibility
    }
}

// MARK: - Registry

public enum ShotModeRegistry {

    public static func mode(id: String) -> ShotModeItem? {
        all.first { $0.id == id }
    }

    public static let all: [ShotModeItem] = [
        milkyWay, starTrails, lunar, issPass, timelapse,
        cityscape, aurora, meteors, conjunction,
    ]

    // MARK: Milky Way Stack

    static let milkyWay = ShotModeItem(
        id: "milkyway",
        name: "Milky Way Stack",
        tagline: "Pull the galactic core out of the noise",
        symbol: "sparkles",
        recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 3200, targetSubCount: 600, nudgeTracking: true),
        expectation: "Ten minutes of stacked 1-second frames — the iPhone's hard exposure cap for "
            + "third-party apps — pulls the core's dust lanes out of the noise. Expect a softly "
            + "glowing band with real structure: a strong phone image, not a tracked-DSLR poster. "
            + "Dark skies are non-negotiable; from a city this shot simply does not exist.",
        tutorial: [
            TutorialStep(id: 1, title: "Find real darkness",
                body: "Skip this one in the city — no amount of stacking recovers what skyglow buries "
                    + "before it reaches the sensor. Get to a rural or darker site (Bortle 4 or better) "
                    + "and give your eyes ten minutes to adapt.",
                symbol: "map"),
            TutorialStep(id: 2, title: "Aim at the core",
                body: "StarFlow points you toward the galactic core, which rides low in the sky — "
                    + "conveniently inside the gimbal's tilt range. Include a slice of horizon for "
                    + "scale; a good foreground makes the shot.",
                symbol: "scope"),
            TutorialStep(id: 3, title: "Let it stack",
                body: "The app fires 600 one-second frames and re-frames with a tiny gimbal nudge "
                    + "about every two minutes to fight the sky's drift. Don't touch the rig — this "
                    + "is ten minutes of hands-off.",
                symbol: "square.stack.3d.up"),
            TutorialStep(id: 4, title: "What you'll get",
                body: "A luminous band with dust-lane structure emerging from the grain. Moonless "
                    + "nights roughly double the contrast — check tonight's moon before driving out.",
                symbol: "photo"),
        ],
        checklist: ModeChecklists.milkyWay,
        cityViable: false,
        needsGimbal: true,
        feasibility: { sky, quality in
            if quality == .city {
                return .notTonight(reason: "City skyglow buries the Milky Way — even a perfect stack "
                    + "can't recover light the sensor never saw. Take this one to rural or darker skies.")
            }
            if !sky.coreVisibleTonight {
                return .notTonight(reason: "The galactic core doesn't rise during darkness at this "
                    + "time of year from your location.")
            }
            if sky.darknessWindow == nil && !sky.isAstronomicalDark {
                return .notTonight(reason: "No astronomical darkness tonight — the sky never gets "
                    + "fully dark at your latitude right now.")
            }
            if sky.moon.illuminatedFraction > 0.5 && sky.moon.position.altitudeDeg > 0 {
                return .possible(note: "A bright moon is up — the core will look washed out. "
                    + "Best after moonset or near new moon.")
            }
            if quality == .suburb {
                return .possible(note: "Suburban skies mute the core. Expect a faint band with some "
                    + "structure, not a glowing arch.")
            }
            return .great
        })

    // MARK: Star Trails — the city hero

    static let starTrails = ShotModeItem(
        id: "startrails",
        name: "Star Trails",
        tagline: "Turn Earth's rotation into art",
        symbol: "hurricane",
        recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 400, targetSubCount: 1800, nudgeTracking: false),
        expectation: "1,800 one-second frames over 30 minutes, blended brightest-pixel: clean arcs "
            + "about 7.5° long. This is the shot that works from a city balcony — bright stars cut "
            + "through light pollution better than any other night subject. Longer sessions draw "
            + "longer arcs; the gimbal's only job is to hold perfectly still.",
        tutorial: [
            TutorialStep(id: 1, title: "Any sky works",
                body: "This is the city-proof shot. Bright stars punch through skyglow, and 30 minutes "
                    + "of Earth's rotation draws clean arcs even from a balcony over a lit street.",
                symbol: "building.2"),
            TutorialStep(id: 2, title: "Compose with an anchor",
                body: "Put something solid in the frame — rooftop, tree, chimney. Face north toward "
                    + "Polaris for circular arcs, or east/west for long diagonal streaks.",
                symbol: "viewfinder"),
            TutorialStep(id: 3, title: "Gimbal goes to HOLD",
                body: "The gimbal's only job is to be a rock. Motors hold framing while StarFlow "
                    + "sends a keep-alive micro-pulse every 15 seconds so the mount never dozes off "
                    + "mid-sequence.",
                symbol: "lock.fill"),
            TutorialStep(id: 4, title: "The long game",
                body: "1,800 frames take 30 minutes, and the app blends the brightest pixels live so "
                    + "you can watch the trails grow. 30 minutes ≈ 7.5° of arc — double the time, "
                    + "double the sweep.",
                symbol: "clock"),
        ],
        checklist: ModeChecklists.starTrails,
        cityViable: true,
        needsGimbal: true,
        feasibility: { sky, _ in
            if sky.sunAltitudeDeg > -6 {
                return .notTonight(reason: "Wait for the end of civil twilight — trails need stars, "
                    + "and stars need at least a dusky sky.")
            }
            if sky.moon.illuminatedFraction > 0.8 && sky.moon.position.altitudeDeg > 20 {
                return .possible(note: "A bright, high moon will thin the trails to the brightest "
                    + "stars — still a good shot, just sparser.")
            }
            return .great
        })

    // MARK: Lunar Detail

    static let lunar = ShotModeItem(
        id: "lunar",
        name: "Lunar Detail",
        tagline: "Crisp moon portraits, craters and all",
        symbol: "moon.fill",
        recipe: CaptureRecipe(exposureSeconds: 0.008, iso: 100, targetSubCount: 150, nudgeTracking: true),
        expectation: "A crisp lunar disk with crater detail along the terminator at the phone's "
            + "telephoto scale — think excellent phone photo, not telescope image. Stacking ~150 "
            + "short 1/125 s subs at ISO 100 averages out atmospheric shimmer. The Moon is bright "
            + "enough that city skies don't matter at all.",
        tutorial: [
            TutorialStep(id: 1, title: "Moon checks",
                body: "You need the Moon above the horizon and at least a crescent lit. The best "
                    + "detail lives along the terminator — the day/night line — where shadows "
                    + "stretch long and craters pop.",
                symbol: "moon.stars"),
            TutorialStep(id: 2, title: "Zoom with glass, not pixels",
                body: "Switch to the phone's longest optical lens (5× on your hardware). Digital "
                    + "zoom just enlarges blur — if you want bigger, crop the stacked result instead.",
                symbol: "camera.aperture"),
            TutorialStep(id: 3, title: "Short, fast frames",
                body: "The lit Moon is daylight-bright: ISO 100 at 1/125 s. StarFlow stacks about "
                    + "150 of these to average out the atmosphere's shimmer — the same trick "
                    + "planetary imagers use, scaled to a phone.",
                symbol: "bolt.fill"),
            TutorialStep(id: 4, title: "Honest expectations",
                body: "Expect crisp craters along the terminator at phone-telephoto scale. A low "
                    + "moon is mushy — atmosphere smears it — so let it climb above about 15° first.",
                symbol: "photo"),
        ],
        checklist: ModeChecklists.lunar,
        cityViable: true,
        needsGimbal: true,
        feasibility: { sky, _ in
            if sky.moon.illuminatedFraction <= 0.1 {
                return .notTonight(reason: "The Moon is new (or a hair-thin sliver) — there's almost "
                    + "nothing lit to photograph. Wait a few nights for the crescent to fatten.")
            }
            if sky.moon.position.altitudeDeg <= 0 {
                return .notTonight(reason: "The Moon is below the horizon right now. Check its rise "
                    + "time and come back.")
            }
            if sky.moon.position.altitudeDeg < 10 {
                return .possible(note: "The Moon is low — the atmosphere will smear detail. It "
                    + "sharpens fast once it climbs above ~15°.")
            }
            return .great
        })

    // MARK: ISS Pass

    static let issPass = ShotModeItem(
        id: "isspass",
        name: "ISS Pass",
        tagline: "Catch the station streaking overhead",
        symbol: "point.3.connected.trianglepath.dotted",
        recipe: CaptureRecipe(exposureSeconds: 0.5, iso: 800, targetSubCount: 300, nudgeTracking: false),
        expectation: "A single bright streak crossing your frame over 2–6 minutes, stacked into one "
            + "unbroken arc. The station outshines every star (magnitude −3), so this works even "
            + "from a city — but you must know the pass time. Miss it by a minute and you stack "
            + "empty sky.",
        tutorial: [
            TutorialStep(id: 1, title: "Know the pass",
                body: "StarFlow can't predict passes yet. Check Spot the Station or Heavens-Above "
                    + "for tonight's visible pass, and note the start time, direction, and peak "
                    + "altitude before you set up.",
                symbol: "clock.badge.exclamationmark"),
            TutorialStep(id: 2, title: "Frame the path",
                body: "Aim where the pass begins and leave room across the frame in the direction of "
                    + "travel. The gimbal's motorized tilt tops out around +27°, so for high passes "
                    + "frame wide and let the station cross through.",
                symbol: "scope"),
            TutorialStep(id: 3, title: "Start two minutes early",
                body: "Begin capture before the ISS rises. Half-second subs at ISO 800 keep the "
                    + "streak bright without blowing out the sky — city skies are genuinely fine here.",
                symbol: "timer"),
            TutorialStep(id: 4, title: "One bright arc",
                body: "The frames stack into a single arc crossing the sky. This mode is all about "
                    + "timing: an empty result almost always means the pass time was off.",
                symbol: "photo"),
        ],
        checklist: ModeChecklists.issPass,
        cityViable: true,
        needsGimbal: true,
        feasibility: { _, _ in
            .possible(note: "Needs a pass time: StarFlow can't predict ISS passes yet. Look up "
                + "tonight's visible pass (Spot the Station or Heavens-Above), then start this mode "
                + "two minutes before it rises.")
        })

    // MARK: Motion Timelapse

    static let timelapse = ShotModeItem(
        id: "timelapse",
        name: "Night Timelapse",
        tagline: "Two hours of sky in ten seconds",
        symbol: "timelapse",
        recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: 240,
                              nudgeTracking: false, intervalSeconds: 30),
        expectation: "One full-second exposure every 30 seconds: 240 frames over two hours become a "
            + "ten-second clip of stars wheeling and clouds streaming. Night scenes stay bright and "
            + "smooth because every frame is a real long exposure, not a starved snapshot. In v1 the "
            + "gimbal holds framing rock-steady; a slow cinematic pan is on the roadmap.",
        tutorial: [
            TutorialStep(id: 1, title: "Pick a scene with motion",
                body: "Clouds, stars, traffic, fog — timelapse rewards change. A static subject "
                    + "makes a boring clip no matter how pretty the frame is.",
                symbol: "wind"),
            TutorialStep(id: 2, title: "One frame every 30 seconds",
                body: "Each frame is a full 1-second exposure, so night scenes stay bright. "
                    + "240 frames over two hours play back as roughly ten seconds at 24 fps.",
                symbol: "timer"),
            TutorialStep(id: 3, title: "The gimbal keeps watch",
                body: "In v1 the gimbal's job is stability: it holds framing and StarFlow sends "
                    + "keep-alive micro-pulses between frames so the motors never sleep. A slow "
                    + "cinematic pan is on the roadmap.",
                symbol: "lock.fill"),
            TutorialStep(id: 4, title: "Battery math",
                body: "Two hours of capture is the real constraint. Thermal and battery guardians "
                    + "will pause or stop the session gracefully — start above 60% charge and "
                    + "consider a power bank.",
                symbol: "battery.50"),
        ],
        checklist: ModeChecklists.timelapse,
        cityViable: true,
        needsGimbal: true,
        feasibility: { sky, _ in
            if sky.sunAltitudeDeg > 0 {
                return .possible(note: "Daylight timelapses work, but stars wheeling over the "
                    + "skyline are where this mode shines. Come back after dark.")
            }
            return .great
        })

    // MARK: City Nights (dual-phase)

    static let cityscape = ShotModeItem(
        id: "cityscape",
        name: "City Nights",
        tagline: "Skyline stacks above the glow",
        symbol: "building.2.fill",
        recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 100, targetSubCount: 120, nudgeTracking: false),
        expectation: "A two-phase shot: a blue-hour base while the sky still holds color, then a "
            + "stack of the lit-up skyline once windows glow. Expect clean, low-noise city lights — "
            + "not a sky full of stars. Note: v1 saves both stacks to your library; the final "
            + "day-night blend is still a manual step in your photo editor.",
        tutorial: [
            TutorialStep(id: 1, title: "Two phases, one shot",
                body: "Phase one shoots at blue hour while the sky still holds color; phase two "
                    + "stacks the skyline after the lights come on. The mix of the two is what "
                    + "makes the image.",
                symbol: "circle.lefthalf.filled"),
            TutorialStep(id: 2, title: "Blue hour first",
                body: "Start 10–20 minutes after sunset. The stacked base exposure banks clean, "
                    + "noise-free shadow detail you can't recover once the sky goes black.",
                symbol: "sun.horizon"),
            TutorialStep(id: 3, title: "Then the lights",
                body: "Once windows and streetlights dominate, the second stack captures them "
                    + "clean: 1-second subs at ISO 100 keep bright signs and windows from clipping.",
                symbol: "building.2"),
            TutorialStep(id: 4, title: "Blend honestly",
                body: "v1 saves both stacks; blending them into one image is a manual step in your "
                    + "editor (auto-blend is on the roadmap). Any rock-steady support works — the "
                    + "gimbal is simply a convenient tripod here.",
                symbol: "slider.horizontal.3"),
        ],
        checklist: ModeChecklists.cityscape,
        cityViable: true,
        needsGimbal: false,
        feasibility: { sky, _ in
            if sky.sunAltitudeDeg > 0 {
                return .possible(note: "Come back at blue hour — starting about 15 minutes after "
                    + "sunset — for the balanced sky the blend needs.")
            }
            return .great
        })

    // MARK: Aurora Watch

    static let aurora = ShotModeItem(
        id: "aurora",
        name: "Aurora Watch",
        tagline: "When the sky catches fire",
        symbol: "wind",
        recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 1600, targetSubCount: 300,
                              nudgeTracking: false, intervalSeconds: 2),
        expectation: "If the aurora shows, 1-second frames catch curtains and color your eyes "
            + "barely register, and the sequence doubles as a timelapse. If Kp stays low, you'll "
            + "record gray-green airglow and nothing more — this mode is gated on the geomagnetic "
            + "forecast, which StarFlow does not fetch. Check a space-weather app first.",
        tutorial: [
            TutorialStep(id: 1, title: "Check the forecast first",
                body: "Aurora is Kp-gated and StarFlow doesn't fetch space weather. Check a "
                    + "forecast app: Kp 5+ gives high latitudes a real chance; mid-latitudes need "
                    + "a severe Kp 8–9 storm.",
                symbol: "chart.line.uptrend.xyaxis"),
            TutorialStep(id: 2, title: "Face the pole, find dark",
                body: "Aurora hugs the poleward horizon — north in the northern hemisphere. Get "
                    + "away from city glow in that direction; even a strong display loses to a "
                    + "streetlight in the frame.",
                symbol: "location.north.line"),
            TutorialStep(id: 3, title: "One-second frames, no tracking",
                body: "Aurora moves fast, so the mount just holds framing while 1-second subs at "
                    + "ISO 1600 record the curtains without smearing their structure.",
                symbol: "camera"),
            TutorialStep(id: 4, title: "Stills and motion",
                body: "You get both: individual frames catch curtain structure, and the sequence "
                    + "plays back as a timelapse. If Kp stays low you'll capture faint airglow at "
                    + "best — that's the honest deal.",
                symbol: "film"),
        ],
        checklist: ModeChecklists.aurora,
        cityViable: false,
        needsGimbal: false,
        feasibility: { sky, quality in
            if sky.sunAltitudeDeg > -6 {
                return .notTonight(reason: "Too bright — aurora hunting starts after twilight ends.")
            }
            let horizon = sky.location.latitude >= 0 ? "northern" : "southern"
            if abs(sky.location.latitude) < 45 {
                return .possible(note: "Kp-gated: at your latitude the aurora only shows during "
                    + "severe storms (Kp 8+). Check a space-weather app — StarFlow doesn't fetch "
                    + "Kp — and find a low, dark \(horizon) horizon.")
            }
            if quality == .city {
                return .possible(note: "Kp-gated: check tonight's forecast (Kp 5+ helps at your "
                    + "latitude). City glow hides faint displays — get the darkest \(horizon) view "
                    + "you can.")
            }
            return .possible(note: "Kp-gated: StarFlow doesn't fetch space weather. If tonight's "
                + "Kp is 5 or higher, you're in business — frame the \(horizon) horizon.")
        })

    // MARK: Meteor Shower

    static let meteors = ShotModeItem(
        id: "meteors",
        name: "Meteor Shower",
        tagline: "Patience, pointed near the radiant",
        symbol: "sparkle",
        recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 3200, targetSubCount: 1200, nudgeTracking: false),
        expectation: "This is a patience game: during a good shower's peak, 20 minutes of frames "
            + "might catch 2–3 meteors, each frozen as a sharp streak in a single 1-second sub. "
            + "Most frames will be empty sky — that's normal and expected. Dark skies are required; "
            + "city glow erases all but rare fireballs.",
        tutorial: [
            TutorialStep(id: 1, title: "Dark skies or don't bother",
                body: "Meteors are faint, fast, one-frame events. City glow erases all but rare "
                    + "fireballs — this mode needs rural darkness, ideally on a shower's peak night.",
                symbol: "map"),
            TutorialStep(id: 2, title: "Frame off the radiant",
                body: "Meteors radiate from the shower's namesake constellation but look longest "
                    + "30–45° away from it. The motorized tilt tops out around +27°, so for higher "
                    + "fields tilt the phone in its clamp before you start.",
                symbol: "scope"),
            TutorialStep(id: 3, title: "Volume is the strategy",
                body: "1,200 one-second frames at ISO 3200. Any frame that catches a meteor "
                    + "freezes it sharp; watch the live preview for streaks as they land.",
                symbol: "square.stack.3d.up"),
            TutorialStep(id: 4, title: "Real catch rates",
                body: "A strong shower at a dark site yields a few meteors per 20 minutes of "
                    + "capture. Empty frames are the norm, not a failure — patience is the whole "
                    + "game.",
                symbol: "photo"),
        ],
        checklist: ModeChecklists.meteors,
        cityViable: false,
        needsGimbal: false,
        feasibility: { sky, quality in
            if quality == .city {
                return .notTonight(reason: "Meteors are faint and fast — city skyglow erases all "
                    + "but rare fireballs. This one needs dark skies.")
            }
            if sky.sunAltitudeDeg > -12 {
                return .notTonight(reason: "The sky is still too bright — meteor watching starts "
                    + "once twilight fully fades.")
            }
            if sky.moon.illuminatedFraction > 0.6 && sky.moon.position.altitudeDeg > 0 {
                return .possible(note: "A bright moon will hide the fainter meteors — you'll only "
                    + "catch the brightest streaks.")
            }
            if quality == .suburb {
                return .possible(note: "Suburban glow hides fainter meteors; expect only the "
                    + "brighter streaks in your frames.")
            }
            return .great
        })

    // MARK: Conjunction

    static let conjunction = ShotModeItem(
        id: "conjunction",
        name: "Conjunction",
        tagline: "Two worlds in one frame",
        symbol: "circlebadge.2.fill",
        recipe: CaptureRecipe(exposureSeconds: 0.5, iso: 400, targetSubCount: 180, nudgeTracking: true),
        expectation: "Two planets as crisp, bright points over graded twilight color — Venus may "
            + "show a hint of a disk at tele zoom; the rest stay perfect dots. Planets outshine "
            + "city skyglow, so a west-facing balcony often works. The catch is timing: close "
            + "pairs usually hang low near the Sun, so your window is the hour around twilight.",
        tutorial: [
            TutorialStep(id: 1, title: "The twilight window",
                body: "Close planet pairs usually sit low near the Sun, so your window is civil to "
                    + "nautical twilight — roughly 20–60 minutes after sunset. Check which pair is "
                    + "up this month before heading out.",
                symbol: "sun.horizon"),
            TutorialStep(id: 2, title: "City-friendly targets",
                body: "Planets are far brighter than stars — Venus and Jupiter cut through any "
                    + "skyglow. A clear view toward the pair's horizon matters more than darkness.",
                symbol: "building.2"),
            TutorialStep(id: 3, title: "Short subs, clean points",
                body: "Half-second subs at ISO 400 keep bright planets from blooming while the "
                    + "twilight gradient survives in the stack. Gentle nudge tracking holds the "
                    + "pair in frame as they sink.",
                symbol: "camera.aperture"),
            TutorialStep(id: 4, title: "What you'll see",
                body: "Two crisp points over twilight color — simple, reliable, and shareable. "
                    + "This is a great first StarFlow shot: short session, forgiving conditions.",
                symbol: "photo"),
        ],
        checklist: ModeChecklists.conjunction,
        cityViable: true,
        needsGimbal: true,
        feasibility: { sky, _ in
            if sky.sunAltitudeDeg > 0 {
                return .possible(note: "The window opens at twilight — bright planet pairs pop out "
                    + "30–60 minutes after sunset, low in the west.")
            }
            if sky.sunAltitudeDeg >= -12 {
                return .great   // twilight window is open right now
            }
            return .possible(note: "The twilight window has passed and low pairs may have set — "
                + "but if your targets are still up, this works fine in full darkness too.")
        })
}
