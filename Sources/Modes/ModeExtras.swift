import Foundation

// MARK: - ModeChecklists
//
// Per-mode setup checklists, rendered as tappable check rows in the mode detail
// sheet above the Start button. The shared rig steps cover the physical failure
// modes the bench runs actually hit — a Free Tilt collar left open, authority
// never granted (no trigger squeeze), a charging cable snagging mid-pan, a
// smudged lens — and every mode ends on one concrete framing hint.

enum ModeChecklists {

    // MARK: Shared rig steps (gimbal modes)

    private static let tripod =
        "Tripod set — mount the gimbal on a tripod or a dead-solid surface; "
        + "hand-holding ruins a stack in a single frame."
    private static let collarOff =
        "Free Tilt collar OFF — click the tilt collar back to locked, or the head "
        + "sags and motorized tilt commands go nowhere."
    private static let trigger =
        "Trigger squeeze ready — when Connect asks, squeeze the gimbal trigger to "
        + "hand StarFlow the controls."
    private static let cableSlack =
        "Cable slack — charging while you shoot? Leave a generous loop so pan "
        + "moves can't snag the cable."
    private static let lensWipe =
        "Lens wiped — night skies turn every fingerprint into a halo; a microfiber "
        + "pass is the cheapest upgrade there is."

    // MARK: Shared rig steps (phone-only modes)

    private static let steady =
        "Phone rock-steady — gimbal, tripod, or a beanbag on a ledge; the frames "
        + "must line up for minutes at a time."

    private static func gimbalRig(framing: String) -> [String] {
        [tripod, collarOff, trigger, cableSlack, lensWipe, framing]
    }

    // MARK: Per-mode checklists

    static let milkyWay = gimbalRig(framing:
        "Framed low toward the core with a slice of horizon — a real foreground "
        + "is what sells the scale.")

    static let starTrails = gimbalRig(framing:
        "Anchor in frame — face north for circles around Polaris, or east/west "
        + "for long diagonal streaks.")

    static let lunar = gimbalRig(framing:
        "Longest optical lens selected and the Moon above ~15° — a low moon "
        + "smears in the atmosphere.")

    static let issPass = gimbalRig(framing:
        "Pass time noted and the frame aimed where it begins, with crossing room "
        + "in the direction of travel.")

    static let timelapse = gimbalRig(framing:
        "Something in frame that moves — clouds, stars, traffic; a static scene "
        + "makes a boring clip.")

    static let conjunction = gimbalRig(framing:
        "Clear view to the pair's horizon — close pairs hang low in twilight, so "
        + "no rooftops in the way.")

    static let cityscape: [String] = [
        steady,
        lensWipe,
        "Clean horizon line composed — lit city below, open sky above; clutter "
        + "across the boundary is what confuses the v1 mask.",
        "Committed to holding still — both phases share one framing, and the "
        + "composite falls apart if the rig moves between them.",
    ]

    static let aurora: [String] = [
        "Kp forecast checked — StarFlow doesn't fetch space weather; no storm, "
        + "no show.",
        steady,
        lensWipe,
        "Low, dark poleward horizon in frame — a single streetlight in view "
        + "beats a faint display.",
    ]

    static let meteors: [String] = [
        "Dark site reached — city glow erases all but rare fireballs.",
        steady,
        lensWipe,
        "Framed 30–45° off the radiant, where streaks stretch longest — tilt the "
        + "phone in its clamp for high fields.",
    ]
}
