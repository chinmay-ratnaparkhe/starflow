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
    /// How this mode's sub-frames are combined (SessionEngine picks the stacker from
    /// this). Appended field, defaulted `.registered` so pre-existing call sites keep
    /// compiling; only trails/timelapse override it.
    public let stackingStyle: StackingStyle
    /// Sky target Aim Assist slews to automatically during the Aim phase. Appended
    /// field, defaulted `nil` so pre-existing call sites keep compiling; only modes
    /// with a well-defined single target (Milky Way, Moon) set it.
    public let celestialTarget: CelestialTarget?
    /// True when sessions of this mode retain per-sub frames for a timelapse
    /// video export (bounded by `TimelapseFramePolicy`: 1080p-class downscale,
    /// frame cap, storage pre-flight). Appended field, defaulted `false` so
    /// pre-existing call sites keep compiling; only Night Timelapse sets it.
    public let producesTimelapse: Bool
    /// True for the cityscape dual-phase mode (feature 10): the session banks
    /// a bracketed static foreground FIRST (head parked), then runs this
    /// mode's recipe as the registered sky stack, and Develop composites the
    /// two along a computed horizon mask (`CityscapeComposer`). Appended
    /// field, defaulted `false` so pre-existing call sites keep compiling;
    /// only City Nights sets it.
    public let capturesForeground: Bool

    public init(id: String, name: String, tagline: String, symbol: String,
                recipe: CaptureRecipe, expectation: String, tutorial: [TutorialStep],
                checklist: [String] = [],
                cityViable: Bool, needsGimbal: Bool,
                stackingStyle: StackingStyle = .registered,
                celestialTarget: CelestialTarget? = nil,
                producesTimelapse: Bool = false,
                capturesForeground: Bool = false,
                feasibility: @escaping @Sendable (SkyContext, SkyQuality) -> Feasibility) {
        self.id = id; self.name = name; self.tagline = tagline; self.symbol = symbol
        self.recipe = recipe; self.expectation = expectation; self.tutorial = tutorial
        self.checklist = checklist
        self.cityViable = cityViable; self.needsGimbal = needsGimbal
        self.stackingStyle = stackingStyle
        self.celestialTarget = celestialTarget
        self.producesTimelapse = producesTimelapse
        self.capturesForeground = capturesForeground
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
            TutorialStep(id: 1, title: "What you're going for",
                body: "A luminous band with real dust-lane texture rising out of the grain — a "
                    + "strong phone image, not a tracked-DSLR poster. Ten minutes of stacked "
                    + "1-second frames builds it, and the darkness of your site decides how deep "
                    + "it goes.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Set up in real darkness",
                body: "Get to Bortle 4 or better — skyglow that reaches the sensor can never be "
                    + "subtracted later. Tripod solid, Free Tilt collar locked, and give your "
                    + "eyes ten minutes to adapt while the rig settles.",
                symbol: "map"),
            TutorialStep(id: 3, title: "Aim low, include the land",
                body: "StarFlow points you toward the galactic core, which rides low in the sky "
                    + "— conveniently inside the gimbal's tilt range. Frame a slice of horizon or "
                    + "a silhouette for scale; the foreground is what sells the shot.",
                symbol: "scope"),
            TutorialStep(id: 4, title: "What the app does",
                body: "It fires 600 one-second subs at ISO 3200, nudging the gimbal about every "
                    + "two minutes to cancel the sky's quarter-degree-per-minute drift, then "
                    + "aligns, derotates and averages every frame — rejecting any that a cloud "
                    + "or plane ruins.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "Plan around the Moon before you plan around the weather: a moonless core "
                    + "window roughly doubles contrast. Near new moon, shoot when the core rides "
                    + "highest — Tonight shows the darkness window that matters.",
                symbol: "lightbulb"),
        ],
        checklist: ModeChecklists.milkyWay,
        cityViable: false,
        needsGimbal: true,
        celestialTarget: .milkyWayCore,
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
            TutorialStep(id: 1, title: "What you're going for",
                body: "Clean star arcs about 7.5° long, drawn by 30 minutes of Earth's rotation "
                    + "and blended brightest-pixel over a sharp foreground. This is the "
                    + "city-proof shot — bright stars punch through skyglow better than any "
                    + "other night subject.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Compose with an anchor",
                body: "Put something solid in the frame — rooftop, tree, chimney — so the arcs "
                    + "have a still point to swing around. Face north toward Polaris for "
                    + "circles, or east/west for long diagonal streaks.",
                symbol: "viewfinder"),
            TutorialStep(id: 3, title: "Capture is 1,800 stills",
                body: "One-second subs at ISO 400 for 30 minutes, back to back. The gimbal's "
                    + "only job is to be a rock — one bump prints a kink into every single "
                    + "trail, so hands off from the first frame to the last.",
                symbol: "lock.fill"),
            TutorialStep(id: 4, title: "What the app does",
                body: "It blends the brightest pixel from each frame live, so you can watch the "
                    + "trails grow, and sends a keep-alive micro-pulse every 15 seconds so the "
                    + "mount never dozes off mid-sequence.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "Arc length is pure time: double the session, double the sweep. And this "
                    + "mode barely cares about the Moon — save moonlit nights for trails and "
                    + "keep the dark ones for the Milky Way.",
                symbol: "lightbulb"),
        ],
        checklist: ModeChecklists.starTrails,
        cityViable: true,
        needsGimbal: true,
        stackingStyle: .trails,   // lighten blend — star registration would erase the arcs
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
            TutorialStep(id: 1, title: "What you're going for",
                body: "A crisp lunar disk with crater shadows along the terminator — the "
                    + "day/night line — at the phone's telephoto scale. Think excellent phone "
                    + "photo, not telescope image; the Moon is bright enough that city skies "
                    + "don't matter at all.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Set up on the bright side",
                body: "You need the Moon above the horizon and at least a crescent lit. Let it "
                    + "climb above about 15° — low moons smear in the thick air near the "
                    + "horizon — and switch to the phone's longest optical lens (5× on your "
                    + "hardware).",
                symbol: "moon.stars"),
            TutorialStep(id: 3, title: "Capture short and fast",
                body: "The lit Moon is daylight-bright: ISO 100 at 1/125 s, about 150 frames. "
                    + "Skip digital zoom — it only enlarges blur. If you want bigger, crop the "
                    + "stacked result instead.",
                symbol: "bolt.fill"),
            TutorialStep(id: 4, title: "What the app does",
                body: "Nudge tracking follows the Moon's drift while the stack averages out the "
                    + "atmosphere's shimmer — the same trick planetary imagers call lucky "
                    + "imaging, scaled to a phone.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "Shoot near first or last quarter, not full moon. A full moon is lit "
                    + "face-on — flat and shadowless — while at quarter phase the terminator "
                    + "shadows stretch long and every crater pops in relief.",
                symbol: "lightbulb"),
        ],
        checklist: ModeChecklists.lunar,
        cityViable: true,
        needsGimbal: true,
        celestialTarget: .moon,
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
            TutorialStep(id: 1, title: "What you're going for",
                body: "One unbroken bright arc crossing your frame, stacked from a 2–6 minute "
                    + "pass. At magnitude −3 the station outshines every star in the sky, so "
                    + "this works even from a city — the whole game is timing.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Scout the pass",
                body: "StarFlow can't predict passes yet. Check Spot the Station or "
                    + "Heavens-Above for tonight's visible pass, and note three things before "
                    + "you set up: start time, direction, and peak altitude.",
                symbol: "clock.badge.exclamationmark"),
            TutorialStep(id: 3, title: "Frame the path, start early",
                body: "Aim where the pass begins and leave crossing room in the direction of "
                    + "travel — the motorized tilt tops out around +27°, so frame wide for high "
                    + "passes. Begin capture two minutes before the rise time.",
                symbol: "scope"),
            TutorialStep(id: 4, title: "What the app does",
                body: "The mount holds framing dead still while half-second subs at ISO 800 "
                    + "stack the moving station into one continuous streak — bright without "
                    + "blowing out the sky. An empty result almost always means the pass time "
                    + "was off.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "Prefer passes within a couple of hours of twilight. Later at night the "
                    + "station flies into Earth's shadow and vanishes mid-sky — if your arc "
                    + "fades partway across the frame, that's the shadow, not a failure.",
                symbol: "lightbulb"),
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
            + "ten-second clip of stars wheeling and clouds streaming, assembled on-device into an "
            + ".mp4 at your chosen 24 or 30 fps. Night scenes stay bright and smooth because every "
            + "frame is a real long exposure, not a starved snapshot. In v1 the gimbal holds framing "
            + "rock-steady; a slow cinematic pan is on the roadmap.",
        tutorial: [
            TutorialStep(id: 1, title: "What you're going for",
                body: "240 frames across two hours playing back as a ten-second clip at 24 fps "
                    + "— stars wheeling, clouds streaming, traffic pulsing. Every frame is a "
                    + "true 1-second exposure, so night scenes stay bright and smooth instead "
                    + "of starved and flickery.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Pick a scene with motion",
                body: "Clouds, stars, fog, traffic — timelapse rewards change. A static subject "
                    + "makes a boring clip no matter how pretty the frame is, so hunt for "
                    + "something that will visibly move over two hours.",
                symbol: "wind"),
            TutorialStep(id: 3, title: "One frame every 30 seconds",
                body: "Each frame is a full 1-second exposure at ISO 800, fired on a 30-second "
                    + "interval. The long stretch between frames is normal — resist the urge "
                    + "to check on the rig; a single touch shows as a jolt in the clip.",
                symbol: "timer"),
            TutorialStep(id: 4, title: "What the app does",
                body: "The gimbal holds framing while keep-alive micro-pulses between frames "
                    + "stop the motors from sleeping (a slow cinematic pan is on the roadmap). "
                    + "Every frame is kept for the clip, and Develop assembles the .mp4 at "
                    + "your chosen frame rate. Guardians end gracefully, keeping everything "
                    + "shot so far.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "Battery is the real constraint: start above 60% or bring a power bank "
                    + "with a slack cable loop. And frame across the wind, so clouds stream "
                    + "through the shot instead of crawling toward the lens.",
                symbol: "lightbulb"),
        ],
        checklist: ModeChecklists.timelapse,
        cityViable: true,
        needsGimbal: true,
        stackingStyle: .unregistered,   // plain mean — timelapse frames need no star lock
        producesTimelapse: true,        // per-sub frames become the exported .mp4 clip
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
        // The SKY phase recipe (Phase B): 1 s subs with real gain so stars
        // survive city glow. Phase A brackets the city separately at low ISO
        // (see CityscapeComposer.bracketRecipes).
        recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 1600, targetSubCount: 120, nudgeTracking: false),
        expectation: "One session, two phases: first a bracketed pass banks the lit-up city — "
            + "three exposures so bright signs keep their detail — then 120 one-second subs at "
            + "ISO 1600 go deep on the sky above the skyline. StarFlow blends the two along a "
            + "horizon mask computed from brightness and texture: city lights stay bright, sky "
            + "goes deep. v1 works best with a clean horizon line — when the mask isn't "
            + "confident, you get both stacks separately instead of a bad blend. City glow "
            + "still sets the ceiling: expect the brighter stars, not a Milky Way.",
        tutorial: [
            TutorialStep(id: 1, title: "What you're going for",
                body: "City lights that stay bright under a sky with real stars in it — "
                    + "one frame, two exposures' worth of truth. Under city glow that means "
                    + "the brighter stars, not a Milky Way. The blend follows a horizon "
                    + "line computed from brightness and texture, so a clean skyline is the "
                    + "whole game in v1.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Compose a clean horizon",
                body: "Frame with the lit city below and open sky above. The mask reads the "
                    + "boundary from where brightness and detail fall away — cranes, trees, "
                    + "and rooftop clutter across the line confuse it, so keep the skyline "
                    + "crisp and don't touch the rig once you start.",
                symbol: "building.2"),
            TutorialStep(id: 3, title: "Capture in two acts",
                body: "Phase one takes about ten seconds: three bracketed exposures — a base, "
                    + "one two stops darker for the bright signs, one a stop brighter for the "
                    + "shadows — plus six matching frames to average the noise down. Phase two "
                    + "then stacks 1-second subs at ISO 1600 for the sky, same framing.",
                symbol: "circle.lefthalf.filled"),
            TutorialStep(id: 4, title: "What the app does",
                body: "It averages the base frames robustly (a passing headlight gets dropped, "
                    + "not blended), fuses the bracket so nothing clips, finds the horizon "
                    + "from the image itself, and feathers the sky stack in above it. If the "
                    + "horizon isn't confident, it hands you both stacks separately and says "
                    + "why — never a bad blend silently.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "The darker your vantage, the deeper the sky phase digs — a rooftop "
                    + "away from streetlights beats a bright sidewalk. Check the mask "
                    + "confidence on the landing report before sharing: high means the "
                    + "blend followed a clean line.",
                symbol: "lightbulb"),
        ],
        checklist: ModeChecklists.cityscape,
        cityViable: true,
        needsGimbal: false,
        capturesForeground: true,   // dual-phase: bracketed foreground, then the sky stack
        feasibility: { sky, _ in
            if sky.sunAltitudeDeg > -6 {
                return .possible(note: "Come back once twilight fades — the sky phase needs "
                    + "stars above the skyline, and the city needs its lights on.")
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
            TutorialStep(id: 1, title: "What you're going for",
                body: "If the sky fires: curtains with color your eyes barely register, plus "
                    + "the whole sequence as a timelapse for free. If Kp stays low you'll "
                    + "record gray-green airglow and nothing more — that's the honest deal.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Check the forecast first",
                body: "Aurora is Kp-gated and StarFlow doesn't fetch space weather. Check a "
                    + "forecast app: Kp 5+ gives high latitudes a real chance; mid-latitudes "
                    + "need a severe Kp 8–9 storm.",
                symbol: "chart.line.uptrend.xyaxis"),
            TutorialStep(id: 3, title: "Face the pole, find dark",
                body: "Aurora hugs the poleward horizon — north in the northern hemisphere. "
                    + "Get the darkest view you can in that direction; a single streetlight in "
                    + "frame beats even a strong display.",
                symbol: "location.north.line"),
            TutorialStep(id: 4, title: "What the app does",
                body: "One-second subs at ISO 1600 on a two-second cadence, no tracking — the "
                    + "mount just holds framing so fast-moving curtains keep their structure "
                    + "instead of smearing. Stills and motion from one session.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "The camera sees color before you do. A faint gray band on the poleward "
                    + "horizon that reads as odd cloud is often aurora — shoot it and check "
                    + "the frame for green before you pack up.",
                symbol: "lightbulb"),
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
            TutorialStep(id: 1, title: "What you're going for",
                body: "A patience game with sharp rewards: during a good shower's peak, 20 "
                    + "minutes of frames might catch 2–3 meteors, each frozen crisp in a "
                    + "single 1-second sub. Most frames will be empty sky — normal, not a "
                    + "failure.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Dark skies on the peak night",
                body: "Meteors are faint, fast, one-frame events; city glow erases all but "
                    + "rare fireballs. Get to rural darkness on the shower's actual peak "
                    + "night — rates fall off hard just a night or two either side.",
                symbol: "map"),
            TutorialStep(id: 3, title: "Frame off the radiant",
                body: "Streaks trace back to the shower's namesake constellation but look "
                    + "longest 30–45° away from it, so aim there. The motorized tilt tops out "
                    + "around +27° — for higher fields, tilt the phone in its clamp first.",
                symbol: "scope"),
            TutorialStep(id: 4, title: "What the app does",
                body: "It fires 1,200 one-second frames at ISO 3200 with no tracking, keeping "
                    + "every sub so a meteor is never averaged away. Watch the live preview "
                    + "for streaks as they land.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "Stay up late: after midnight your side of Earth turns to face the "
                    + "meteor stream head-on, and hourly counts often double what the evening "
                    + "gave you. Bring a chair and a warm layer.",
                symbol: "lightbulb"),
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
            TutorialStep(id: 1, title: "What you're going for",
                body: "Two crisp planet points over graded twilight color — Venus may show a "
                    + "hint of a disk at tele zoom; the rest stay perfect dots. Short session, "
                    + "forgiving conditions: a great first StarFlow shot.",
                symbol: "photo"),
            TutorialStep(id: 2, title: "Time the twilight window",
                body: "Close planet pairs usually sit low near the Sun, so your window is "
                    + "civil to nautical twilight — roughly 20–60 minutes after sunset. Check "
                    + "which pair is up this month before heading out.",
                symbol: "sun.horizon"),
            TutorialStep(id: 3, title: "Claim the pair's horizon",
                body: "Planets are far brighter than stars — Venus and Jupiter cut through any "
                    + "skyglow, so a west-facing balcony often works. A clear view toward the "
                    + "pair's horizon matters more than darkness.",
                symbol: "building.2"),
            TutorialStep(id: 4, title: "What the app does",
                body: "Half-second subs at ISO 400 keep bright planets from blooming while the "
                    + "twilight gradient survives in the stack, and gentle nudge tracking "
                    + "holds the sinking pair in frame.",
                symbol: "wand.and.stars"),
            TutorialStep(id: 5, title: "Pro tip",
                body: "Shoot through the whole window rather than one burst — the sky "
                    + "gradient changes minute by minute, and the keeper often lands deep in "
                    + "nautical twilight when the pair blazes against the last color.",
                symbol: "lightbulb"),
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
