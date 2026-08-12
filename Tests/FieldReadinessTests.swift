import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - FieldReadinessTests
//
// Regression cover for the five field-blocking defects found before the
// Perseid-peak field night. Each test names the failure it prevents:
//
//  1. Meteor Shower ran the registered stacker, which averaged every meteor
//     down by 1/N and then clipped the remainder as a >3σ outlier — the mode
//     erased the only thing it exists to catch.
//  2. `isoScale(.dark)` returned 2.0, taking the Milky Way's ISO 3200 to 6400.
//     A 1 s sub at a dark site is read-noise dominated; the extra stop bought
//     no noise improvement and clipped star cores.
//  3. The mid-session ISO refinement's low-background trigger (≤ 0.02) fires
//     on a CORRECT exposure at a genuine dark site (0.005–0.03), doubling gain
//     mid-accumulator and leaving a two-population stack.
//  4. A 2,700-sub plan with "keep RAW subs" on demanded ~83 GB in the storage
//     pre-flight — so `verdict` refused and the session never began — while
//     nothing writes subs, so it would have saved nothing anyway.
//  5. Field nights end on the clock (the core sets, twilight starts), not on a
//     sub count; there was no way to say "stop at 01:00".
//
// All simulator-safe: synthetic frames, injected clocks, no hardware.

// MainActor-isolated because `SessionEngine.makeStacker` (and the engine
// generally) is — the pure model assertions below are cheap enough that running
// them on the main queue costs nothing.
@MainActor
final class FieldReadinessTests: XCTestCase {

    // MARK: - 1. Meteor mode must not erase meteors

    func testMeteorModeUsesTheLightenBlend() throws {
        let meteors = try XCTUnwrap(ShotModeRegistry.mode(id: "meteors"))
        XCTAssertEqual(meteors.stackingStyle, .trails,
                       "A meteor lives in ONE sub: a registered mean divides it by N and "
                       + "kappa-sigma clips the rest. Only the lighten blend keeps it.")
        XCTAssertTrue(SessionEngine.makeStacker(style: meteors.stackingStyle) is TrailsBlender,
                      "The meteor mode's stacker must be the unregistered max blend")
        // Switching styles must not quietly cost the mode its focus sweep:
        // a defocused meteor is a smudge, not a streak.
        XCTAssertTrue(meteors.sweepsFocus,
                      "Meteor sessions still need pinpoint focus before capture")
        // …while genuine trails keep the old behaviour by default.
        let trails = try XCTUnwrap(ShotModeRegistry.mode(id: "startrails"))
        XCTAssertFalse(trails.sweepsFocus)
        let timelapse = try XCTUnwrap(ShotModeRegistry.mode(id: "timelapse"))
        XCTAssertFalse(timelapse.sweepsFocus)
        let milkyWay = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        XCTAssertTrue(milkyWay.sweepsFocus)
    }

    /// The behaviour the style exists for: a streak that appears in exactly ONE
    /// frame out of twenty must survive the stack at full brightness.
    func testAMeteorInOneFrameOfTwentySurvivesTheStack() throws {
        let w = 96, h = 64
        let meteorX = 20..<70, meteorY = 24
        let meteors = try XCTUnwrap(ShotModeRegistry.mode(id: "meteors"))
        let stacker = SessionEngine.makeStacker(style: meteors.stackingStyle)
        stacker.reset(width: w, height: h)

        let frameCount = 20
        let meteorFrame = 7
        for i in 0..<frameCount {
            var buffer = Self.starField(width: w, height: h)
            if i == meteorFrame {
                for x in meteorX { buffer[meteorY * w + x] = 0.95 }
            }
            let image = try XCTUnwrap(CPUStacker.grayImage(from: buffer, width: w, height: h))
            let frame = SubFrame(index: i, timestamp: Date(), exposureSeconds: 1.0,
                                 iso: 3200, pixelData: image)
            XCTAssertTrue(stacker.add(frame: frame), "clean frame \(i) must be accepted")
        }

        let blender = try XCTUnwrap(stacker as? TrailsBlender)
        let blend = blender.accumulatedMax()
        // Sample the middle of the streak, away from its ends.
        let sample = blend[meteorY * w + 45]
        XCTAssertGreaterThan(sample, 0.8,
                             "The meteor faded to \(sample) — a 1-in-20 transient must keep "
                             + "its single-frame brightness, not be averaged to ~1/20th")
        XCTAssertEqual(stacker.currentResult().accepted, frameCount,
                       "Nothing may be rejected: outlier rejection is what clipped meteors")
    }

    /// The tutorial and expectation copy must describe the lighten blend that
    /// actually runs — including the star trailing it causes — and must not
    /// claim frames are kept individually.
    func testMeteorCopyDescribesWhatActuallyHappens() throws {
        let meteors = try XCTUnwrap(ShotModeRegistry.mode(id: "meteors"))
        let copy = (meteors.expectation + " "
                    + meteors.tutorial.map(\.body).joined(separator: " ")).lowercased()
        XCTAssertTrue(copy.contains("lighten") || copy.contains("brightest"),
                      "Meteor copy must name the blend that runs: \(copy)")
        XCTAssertTrue(copy.contains("trail"),
                      "Meteor copy must warn that the stars trail under a max blend")
        // …and QUANTIFY it. Nothing tracks in this mode, so 20 minutes of sky is
        // ~5° of rotation: the composite is a star-trail frame, not a pinpoint
        // field with meteors on it. "Trails slightly" was the dishonest version.
        XCTAssertTrue(copy.contains("5°"),
                      "Meteor copy must say how far the stars trail, not just that they do")
        XCTAssertFalse(copy.contains("trail slightly") || copy.contains("trail a little"),
                       "5° of untracked rotation is not 'slight' — say what it is")
        XCTAssertFalse(copy.contains("keeping every sub"),
                       "The old claim that every sub is kept was never true")
    }

    // MARK: - 2. No ISO doubling at dark sites

    func testDarkSiteHoldsGainAtTheReadNoiseFloor() {
        for baseISO in [1600.0, 3200.0, 4800.0, 6400.0] {
            let base = CaptureRecipe(exposureSeconds: 1.0, iso: baseISO,
                                     targetSubCount: 100, nudgeTracking: false)
            let planned = ExposurePlanner.plan(base: base, quality: .dark).iso
            // The rule is LIFT-ONLY: a base under the read-noise floor is raised
            // to it (1600 → 3200), a base at or above it is passed through. So
            // the bound is max(base, floor) — asserting `planned <= baseISO`
            // would demand that 1600 stay at 1600 and contradict the floor.
            let expected = min(max(baseISO, ExposurePlanner.darkSiteISOFloor),
                               ExposurePlanner.isoCeiling)
            XCTAssertLessThanOrEqual(planned, expected,
                                     "Dark site amplified ISO \(baseISO) to \(planned)")
            XCTAssertEqual(planned, expected, accuracy: 1e-9,
                           "Dark site must plan max(base, floor) for ISO \(baseISO)")
            XCTAssertGreaterThanOrEqual(planned, ExposurePlanner.darkSiteISOFloor,
                                        "Dim-sky recipes must still clear the read-noise floor")
        }
    }

    func testMilkyWayRunsAt3200NotAt6400UnderDarkSkies() throws {
        let milkyWay = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        XCTAssertEqual(milkyWay.recipe.iso, 3200, accuracy: 1e-9)
        let planned = ExposurePlanner.plan(base: milkyWay.recipe, quality: .dark)
        XCTAssertEqual(planned.iso, 3200, accuracy: 1e-9,
                       "ISO 6400 at a dark site only clips star cores")
    }

    // MARK: - 4a. Session length

    func testMilkyWayPlansADeepSession() throws {
        let milkyWay = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        XCTAssertEqual(milkyWay.recipe.targetSubCount, 2700,
                       "Ten minutes is not a Milky Way stack — the plan is ~45 minutes")
        let minutes = CloudTimeBudget.plannedWallSeconds(recipe: milkyWay.recipe) / 60
        XCTAssertGreaterThan(minutes, 40)
        XCTAssertLessThan(minutes, 50)
        // The copy must match the plan — no mode may promise a duration it
        // doesn't shoot.
        let copy = milkyWay.expectation + " " + milkyWay.tutorial.map(\.body).joined(separator: " ")
        XCTAssertTrue(copy.contains("45 minutes") || copy.contains("2,700"),
                      "Milky Way copy still describes the old ten-minute plan: \(copy)")
        XCTAssertFalse(copy.contains("600 one-second subs"),
                       "Stale sub count in the tutorial copy")
    }

    // MARK: - 4b. Keep-subs can never refuse a session

    func testKeepSubsCannotBlockASessionWhileNothingWritesSubs() throws {
        // The setting may be on; the budget must still describe what the code
        // does, because no per-sub file is written in this build.
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FieldReadinessTests.keepSubs"))
        defaults.set(true, forKey: "keepSubs")
        defer { defaults.removePersistentDomain(forName: "FieldReadinessTests.keepSubs") }
        XCTAssertFalse(StorageBudget.retainsSubsOnDisk(defaults: defaults),
                       "Until sub persistence ships, the pre-flight must budget the real "
                       + "transient cost — not 30 MB/frame for files nobody writes")

        // The concrete field case: 2,700 subs on a phone with 12 GB free.
        let milkyWay = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        let planned = StorageBudget.plannedSessionBytes(
            recipe: milkyWay.recipe,
            keepingSubs: StorageBudget.retainsSubsOnDisk(defaults: defaults))
        XCTAssertNotEqual(StorageBudget.verdict(freeBytes: 12_000_000_000,
                                                plannedBytes: planned), .refuse,
                          "A 2,700-sub plan must not be refused over ~83 GB of "
                          + "sub files that are never written")
        XCTAssertLessThan(planned, 1_000_000_000,
                          "Planned bytes (\(planned)) must reflect transient working "
                          + "storage, not RAW retention")
    }

    // MARK: - 6. Per-year ZHR override

    func testPerseids2026PromisesTheSparseYearRate() throws {
        let catalog = EventCatalog()
        let denver = GeoLocation(latitude: 39.74, longitude: -104.99)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        }
        let events2026 = catalog.events(from: day(2026, 7, 20), days: 40, location: denver)
        guard let perseids2026 = events2026.first(where: { $0.id == "shower.perseids.2026" })
        else { return XCTFail("Perseids 2026 missing") }
        XCTAssertEqual(perseids2026.zhr, 60, "2026 is a documented sparse year")

        // Every other year keeps the long-run average — the override is a
        // per-year fact, not a permanent downgrade.
        let events2027 = catalog.events(from: day(2027, 7, 20), days: 40, location: denver)
        guard let perseids2027 = events2027.first(where: { $0.id == "shower.perseids.2027" })
        else { return XCTFail("Perseids 2027 missing") }
        XCTAssertEqual(perseids2027.zhr, 100)

        // Unrelated showers are untouched by the new field.
        let geminids = try XCTUnwrap(
            catalog.events(from: day(2026, 12, 1), days: 20, location: denver)
                .first(where: { $0.id == "shower.geminids.2026" }))
        XCTAssertEqual(geminids.zhr, 150)
    }

    // MARK: - 5. Wall-clock stop (pure model)

    func testStoppingAtBuildsADeadlineWithoutChangingThePlan() throws {
        let milkyWay = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        XCTAssertNil(milkyWay.recipe.stopAt, "Modes ship with no deadline")

        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let timed = milkyWay.stopping(afterMinutes: 45, from: now)
        XCTAssertEqual(try XCTUnwrap(timed.recipe.stopAt).timeIntervalSince(now),
                       45 * 60, accuracy: 1e-6)
        // Everything else is the mode's contract and must be untouched.
        XCTAssertEqual(timed.id, milkyWay.id)
        XCTAssertEqual(timed.recipe.targetSubCount, milkyWay.recipe.targetSubCount)
        XCTAssertEqual(timed.recipe.iso, milkyWay.recipe.iso, accuracy: 1e-9)
        XCTAssertEqual(timed.recipe.exposureSeconds, milkyWay.recipe.exposureSeconds,
                       accuracy: 1e-12)
        XCTAssertEqual(timed.stackingStyle, milkyWay.stackingStyle)
        XCTAssertEqual(timed.celestialTarget, milkyWay.celestialTarget)
        XCTAssertEqual(timed.checklist, milkyWay.checklist)

        // "None" clears rather than scheduling a stop in the past.
        XCTAssertNil(milkyWay.stopping(afterMinutes: 0, from: now).recipe.stopAt)
        XCTAssertNil(milkyWay.stopping(afterMinutes: -30, from: now).recipe.stopAt)
        XCTAssertNil(timed.stopping(at: nil).recipe.stopAt)
    }

    func testSecondsUntilStopNeverGoesNegative() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        var recipe = CaptureRecipe(exposureSeconds: 1.0, iso: 800,
                                   targetSubCount: 10, nudgeTracking: false)
        XCTAssertNil(recipe.secondsUntilStop(from: now))
        recipe.stopAt = now.addingTimeInterval(90)
        XCTAssertEqual(try XCTUnwrap(recipe.secondsUntilStop(from: now)), 90, accuracy: 1e-9)
        // Past the deadline the answer is zero, never a negative wait.
        let overdue = try XCTUnwrap(recipe.secondsUntilStop(from: now.addingTimeInterval(500)))
        XCTAssertEqual(overdue, 0, accuracy: 1e-9)
    }

    func testStopChoiceLabels() {
        XCTAssertEqual(SessionStopChoice.minuteOptions, [0, 15, 30, 45, 60, 90])
        XCTAssertEqual(SessionStopChoice.label(minutes: 0), "None")
        XCTAssertEqual(SessionStopChoice.label(minutes: 45), "45 min")
        XCTAssertEqual(SessionStopChoice.label(minutes: 60), "1 h")
        XCTAssertEqual(SessionStopChoice.label(minutes: 90), "1 h 30 m")
    }

    /// The mode sheet's "full plan" duration must be a WALL-CLOCK estimate, not
    /// integration time. Multiplying the shutter by the sub count told a Lunar
    /// user their 150-frame plan takes "about 1 s".
    func testStopCardDurationUsesShotToShotNotShutter() throws {
        let lunar = try XCTUnwrap(ShotModeRegistry.mode(id: "lunar"))
        let integration = lunar.recipe.exposureSeconds * Double(lunar.recipe.targetSubCount)
        XCTAssertLessThan(integration, 5,
                          "Precondition: lunar's integration time really is a couple of seconds")
        let wall = SessionStopChoice.estimatedWallSeconds(recipe: lunar.recipe)
        XCTAssertEqual(wall, Double(lunar.recipe.targetSubCount)
                       * SessionStopChoice.minimumFrameWallSeconds, accuracy: 1e-9,
                       "A sub-second shutter still costs a full shot-to-shot cycle")
        XCTAssertGreaterThan(wall, 60, "\(wall)s is not an honest run length for 150 frames")

        // A 1 s mode is unchanged: the floor only ever lifts short exposures.
        let milkyWay = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        XCTAssertEqual(SessionStopChoice.estimatedWallSeconds(recipe: milkyWay.recipe),
                       2700, accuracy: 1e-9)
        // Cadence gaps are added on top, not floored away.
        let spaced = CaptureRecipe(exposureSeconds: 0.5, iso: 800, targetSubCount: 100,
                                   nudgeTracking: false, intervalSeconds: 30)
        XCTAssertEqual(SessionStopChoice.estimatedWallSeconds(recipe: spaced),
                       100 * 31.0, accuracy: 1e-9)
        // The cloud budget's own math is untouched — it drives the 2× extension
        // cap and must keep meaning exactly what it meant.
        XCTAssertEqual(CloudTimeBudget.plannedWallSeconds(recipe: lunar.recipe),
                       integration, accuracy: 1e-9)
    }

    // MARK: - Fixtures

    /// Flat night pedestal with a handful of static gaussian stars.
    static func starField(width w: Int, height h: Int) -> [Float] {
        var buffer = [Float](repeating: 0.04, count: w * h)
        let stars = [(12.0, 10.0), (40.0, 48.0), (70.0, 14.0), (84.0, 52.0)]
        let sigma = 1.4, amp = 0.7
        let inv = 1.0 / (2 * sigma * sigma)
        for (sx, sy) in stars {
            for y in max(0, Int(sy) - 5)...min(h - 1, Int(sy) + 5) {
                for x in max(0, Int(sx) - 5)...min(w - 1, Int(sx) + 5) {
                    let dx = Double(x) - sx, dy = Double(y) - sy
                    buffer[y * w + x] += Float(amp * exp(-(dx * dx + dy * dy) * inv))
                }
            }
        }
        for i in 0..<buffer.count { buffer[i] = min(1, max(0, buffer[i])) }
        return buffer
    }
}

// MARK: - Session-engine integration (clock stop + ISO gating)

@MainActor
private final class FieldMockMount: MountControlling {
    var connection: MountConnection = .docked(name: "MockFlow")
    var authority: MountAuthority = .granted
    var telemetry: MountTelemetry?
    func start() {}
    func stopEverything() async {}
    func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func waitSettled() async -> Bool { true }
    func keepalivePulse() async {}
}

private final class FieldMockStacker: Stacking {
    func reset(width: Int, height: Int) {}
    func add(frame: SubFrame) -> Bool { true }
    func currentResult() -> StackResult {
        StackResult(accepted: 0, rejected: 0, integrationSeconds: 0, preview: nil)
    }
    func finalImage() -> CGImage? { nil }
}

/// Virtual clock: every captured frame advances it by the frame's wall cost, so
/// a 45-minute deadline can be exercised in milliseconds of real time.
private final class FieldClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(start: Date) { self.now = start }
    var current: Date {
        lock.lock(); defer { lock.unlock() }
        return now
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        now = now.addingTimeInterval(seconds)
    }
}

private final class FieldISOLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ iso: Double) {
        lock.lock(); defer { lock.unlock() }
        values.append(iso)
    }
    var isos: [Double] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private struct FieldTestTimeout: Error {}

@MainActor
final class FieldReadinessSessionTests: XCTestCase {

    // MARK: - 5. The capture loop honours stopAt

    /// A 100-sub plan with a 20-frame-equivalent deadline must stop on the
    /// clock, well short of the sub count, and still develop what it has.
    func testCaptureStopsOnTheWallClockDeadline() async throws {
        let clock = FieldClock(start: Date(timeIntervalSince1970: 1_786_000_000))
        let side = 32
        let image = Self.flatGray(side: side, gray: 0.10)
        let hooks = Self.hooks(clock: clock, image: image, side: side, isoLog: nil)

        let engine = SessionEngine(mount: FieldMockMount(),
                                   stacker: FieldMockStacker(), hooks: hooks)
        engine.autoFocusSweep = false
        let base = ShotModeItem(
            id: "clockstop", name: "Clock Stop", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: 100,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            stackingStyle: .registered,
            feasibility: { _, _ in .great })
        // Each captured frame advances the virtual clock 1 s, so a 20 s
        // deadline is ~20 frames of a 100-frame plan.
        let shot = base.stopping(at: clock.current.addingTimeInterval(20))
        engine.start(shot: shot)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertTrue(engine.stats.stoppedOnClock,
                      "The session must record that the clock, not the plan, ended it")
        XCTAssertGreaterThan(engine.stats.subsAccepted, 0,
                             "Frames captured before the deadline must be kept")
        XCTAssertLessThan(engine.stats.subsAccepted, 100,
                          "The deadline must cut the plan short — that is the whole point")
        XCTAssertLessThanOrEqual(engine.stats.subsAccepted, 25,
                                 "Capture must stop AT the deadline, not drift past it")
        XCTAssertNil(engine.interruption,
                     "A wall-clock stop is a clean finish, not a guardian interruption")
    }

    /// No deadline: the plan runs to its sub count exactly as before. The new
    /// field must be inert when unset.
    func testSessionsWithoutADeadlineRunTheFullPlan() async throws {
        let clock = FieldClock(start: Date(timeIntervalSince1970: 1_786_000_000))
        let side = 32
        let image = Self.flatGray(side: side, gray: 0.10)
        let hooks = Self.hooks(clock: clock, image: image, side: side, isoLog: nil)

        let engine = SessionEngine(mount: FieldMockMount(),
                                   stacker: FieldMockStacker(), hooks: hooks)
        engine.autoFocusSweep = false
        let shot = ShotModeItem(
            id: "noclockstop", name: "No Stop", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: 14,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            stackingStyle: .registered,
            feasibility: { _, _ in .great })
        engine.start(shot: shot)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(engine.stats.subsAccepted, 14)
        XCTAssertFalse(engine.stats.stoppedOnClock)
    }

    /// The deadline is absolute and starts running the moment the user sets it,
    /// so Connect, framing confirmation, GoTo and the focus sweep all spend it.
    /// If it is already gone by the time capture begins, the session must still
    /// take an exposure rather than develop an empty stack — a landing report
    /// with zero subs reads as a crash to someone standing in the cold.
    func testAnElapsedDeadlineStillCapturesAFrameRatherThanNothing() async throws {
        let clock = FieldClock(start: Date(timeIntervalSince1970: 1_786_000_000))
        let side = 32
        let image = Self.flatGray(side: side, gray: 0.10)
        let hooks = Self.hooks(clock: clock, image: image, side: side, isoLog: nil)

        let engine = SessionEngine(mount: FieldMockMount(),
                                   stacker: FieldMockStacker(), hooks: hooks)
        engine.autoFocusSweep = false
        let base = ShotModeItem(
            id: "elapsedstop", name: "Elapsed Stop", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: 100,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: false,
            stackingStyle: .registered,
            feasibility: { _, _ in .great })
        // Setup ate the whole window: the stop time is already an hour past.
        let shot = base.stopping(at: clock.current.addingTimeInterval(-3600))
        engine.start(shot: shot)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        let shutterActuations = engine.stats.subsAccepted + engine.stats.subsRejected
            + engine.stats.subsSkippedClouds
        XCTAssertEqual(shutterActuations, 1,
                       "Exactly one frame: never zero (an empty night), never a run-on "
                       + "past a deadline the user already missed")
        XCTAssertTrue(engine.stats.stoppedOnClock,
                      "The report must still say the clock ended it")
        XCTAssertNil(engine.interruption,
                     "An elapsed deadline is a clean finish, not a guardian interruption")
    }

    // MARK: - 3. Registered stacks hold their ISO by default

    /// The dark-site case that ruined stacks: frames measuring a background of
    /// ~0.01 (a correct 1 s sub at Bortle 1–2) sit right on the refinement's
    /// low-background trigger. By default the session must ignore it and run
    /// one ISO from first frame to last.
    func testRegisteredStacksHoldTheirISOByDefault() async throws {
        let clock = FieldClock(start: Date(timeIntervalSince1970: 1_786_000_000))
        let side = 64
        let darkSky = Self.flatGray(side: side, gray: 0.01)
        let log = FieldISOLog()
        let hooks = Self.hooks(clock: clock, image: darkSky, side: side, isoLog: log)

        let engine = SessionEngine(mount: FieldMockMount(),
                                   stacker: FieldMockStacker(), hooks: hooks)
        engine.autoFocusSweep = false
        // midSessionISORefine left at its default (nil → follow Settings → off).
        let shot = ShotModeItem(
            id: "darkstack", name: "Dark Stack", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 3200, targetSubCount: 14,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: false, needsGimbal: false,
            stackingStyle: .registered,
            feasibility: { _, _ in .great })
        engine.start(shot: shot)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(Set(log.isos), [3200],
                       "A dark sky must not double a registered stack's ISO mid-session — "
                       + "that leaves two populations in one accumulator. Saw: \(log.isos)")
    }

    /// The same session with the opt-in ON does tune — the mechanism is
    /// preserved for the deliberate experimenter, just off the default path.
    func testOptingInRestoresTheMidSessionTuning() async throws {
        let clock = FieldClock(start: Date(timeIntervalSince1970: 1_786_000_000))
        let side = 64
        let darkSky = Self.flatGray(side: side, gray: 0.01)
        let log = FieldISOLog()
        let hooks = Self.hooks(clock: clock, image: darkSky, side: side, isoLog: log)

        let engine = SessionEngine(mount: FieldMockMount(),
                                   stacker: FieldMockStacker(), hooks: hooks)
        engine.autoFocusSweep = false
        engine.midSessionISORefine = true
        let shot = ShotModeItem(
            id: "darkstackoptin", name: "Dark Stack", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 1600, targetSubCount: 14,
                                  nudgeTracking: false),
            expectation: "test", tutorial: [], cityViable: false, needsGimbal: false,
            stackingStyle: .registered,
            feasibility: { _, _ in .great })
        engine.start(shot: shot)

        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(log.isos.first ?? 0, 1600, accuracy: 1e-9)
        XCTAssertEqual(log.isos.last ?? 0, 3200, accuracy: 1e-9,
                       "Opted in, a darker-than-planned sky still raises one stop")
    }

    // MARK: Helpers

    private static func hooks(clock: FieldClock, image: CGImage?, side: Int,
                              isoLog: FieldISOLog?) -> SessionHooks {
        SessionHooks(
            prepareCapture: { _ in (side, side) },
            captureSub: { recipe, index in
                try await Task.sleep(nanoseconds: 1_000_000)
                isoLog?.record(recipe.iso)
                // Each frame costs its exposure + cadence on the VIRTUAL clock,
                // so a 45-minute deadline is exercised in milliseconds.
                clock.advance(max(recipe.exposureSeconds, 0) + max(recipe.intervalSeconds, 0))
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                                pixelData: image)
            },
            endCapture: {},
            thermalState: { .nominal },
            batteryPercent: { 80 },
            freeDiskBytes: { 64_000_000_000 },
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0.5) },
            now: { clock.current },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })
    }

    private static func flatGray(side: Int, gray: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: gray, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    private func waitUntil(timeout: TimeInterval = 15,
                           _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw FieldTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
