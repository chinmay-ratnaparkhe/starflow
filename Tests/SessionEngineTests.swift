import XCTest
import CoreGraphics
@testable import StarFlow

// MARK: - Test doubles (file-private; names prefixed to avoid target-wide collisions)

@MainActor
private final class SessionMockMount: MountControlling {
    var connection: MountConnection = .docked(name: "MockFlow")
    var authority: MountAuthority = .granted
    var telemetry: MountTelemetry? = MountTelemetry(pitchDeg: 5, yawDeg: 120,
                                                    speedDegPerSec: 0, batteryPercent: 87)
    var startCount = 0
    var stopCount = 0
    var nudgeCount = 0
    var keepaliveCount = 0

    func start() { startCount += 1 }
    func stopEverything() async { stopCount += 1 }
    func slew(deltaPitchDeg: Double, deltaYawDeg: Double) async throws {}
    func nudge(deltaPitchDeg: Double, deltaYawDeg: Double) async throws { nudgeCount += 1 }
    func waitSettled() async -> Bool { true }
    func keepalivePulse() async { keepaliveCount += 1 }
}

private final class SessionMockStacker: Stacking {
    var resetCount = 0
    var added = 0
    var rejectEvery: Int?
    private let tiny = SessionMockStacker.makeTinyImage()

    func reset(width: Int, height: Int) { resetCount += 1; added = 0 }

    func add(frame: SubFrame) -> Bool {
        added += 1
        if let r = rejectEvery, r > 0, added % r == 0 { return false }
        return true
    }

    func currentResult() -> StackResult {
        StackResult(accepted: added, rejected: 0,
                    integrationSeconds: Double(added), preview: tiny)
    }

    func finalImage() -> CGImage? { tiny }

    static func makeTinyImage() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 8, height: 8,
                                  bitsPerComponent: 8, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()
    }
}

private final class SessionValueBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private struct SessionTestTimeout: Error {}

// MARK: - Tests

@MainActor
final class SessionEngineTests: XCTestCase {

    // MARK: Fixtures

    private func makeShot(subs: Int, nudge: Bool = false, interval: Double = 0,
                          needsGimbal: Bool = true) -> ShotModeItem {
        ShotModeItem(
            id: "test", name: "Test Shot", tagline: "test", symbol: "star",
            recipe: CaptureRecipe(exposureSeconds: 1.0, iso: 800, targetSubCount: subs,
                                  nudgeTracking: nudge, intervalSeconds: interval),
            expectation: "test", tutorial: [], cityViable: true, needsGimbal: needsGimbal,
            feasibility: { _, _ in .great })
    }

    /// Fast hooks: ~2 ms per sub so tests can interleave with the engine, 0.2 ms scheduler
    /// sleeps so debounce/poll loops spin quickly.
    private func makeHooks(thermal: @escaping @MainActor () -> ProcessInfo.ThermalState = { .nominal },
                           battery: @escaping @MainActor () -> Int? = { 80 },
                           freeDisk: @escaping @MainActor () -> Int64? = { 64_000_000_000 }) -> SessionHooks {
        SessionHooks(
            prepareCapture: { _ in (8, 8) },
            captureSub: { recipe, index in
                try await Task.sleep(nanoseconds: 2_000_000)
                return SubFrame(index: index, timestamp: Date(),
                                exposureSeconds: recipe.exposureSeconds, iso: recipe.iso,
                                pixelData: nil)
            },
            endCapture: {},
            thermalState: thermal,
            batteryPercent: battery,
            freeDiskBytes: freeDisk,
            nudgeVector: { (deltaPitchDeg: 0, deltaYawDeg: 0.5) },
            now: { Date() },
            sleep: { _ in try await Task.sleep(nanoseconds: 200_000) })
    }

    private func waitUntil(timeout: TimeInterval = 10,
                           _ what: String,
                           _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                XCTFail("Timed out waiting for: \(what)")
                throw SessionTestTimeout()
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Happy path

    func testHappyPathReachesCompleteWithStats() async throws {
        let mount = SessionMockMount()
        let stacker = SessionMockStacker()
        let engine = SessionEngine(mount: mount, stacker: stacker, hooks: makeHooks())
        let shot = makeShot(subs: 12)

        engine.start(shot: shot)
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(engine.stats.subsAccepted, 12)
        XCTAssertEqual(engine.stats.subsRejected, 0)
        XCTAssertEqual(engine.stats.integrationSeconds, 12.0, accuracy: 0.001)
        XCTAssertEqual(engine.stats.flapsRecovered, 0)
        XCTAssertNil(engine.interruption)
        XCTAssertNotNil(engine.latestPreview, "Develop phase must publish a final image")
        XCTAssertNotNil(engine.stats.startedAt)
        XCTAssertFalse(engine.pointingInvalidated)
        XCTAssertEqual(stacker.resetCount, 1)
        XCTAssertGreaterThanOrEqual(mount.stopCount, 1, "stopEverything on every exit path")
    }

    func testRejectedSubsAreCountedNotIntegrated() async throws {
        let mount = SessionMockMount()
        let stacker = SessionMockStacker()
        stacker.rejectEvery = 4   // every 4th frame rejected (cloud/misalignment)
        let engine = SessionEngine(mount: mount, stacker: stacker, hooks: makeHooks())

        engine.start(shot: makeShot(subs: 12))
        try await waitUntil("phase == .complete") { engine.phase == .complete }

        XCTAssertEqual(engine.stats.subsAccepted, 9)
        XCTAssertEqual(engine.stats.subsRejected, 3)
        XCTAssertEqual(engine.stats.integrationSeconds, 9.0, accuracy: 0.001)
    }

    // MARK: Authority gate

    func testAuthorityDeniedSurfacesInterruptionThenProceedsWhenGranted() async throws {
        let mount = SessionMockMount()
        mount.authority = .denied
        let stacker = SessionMockStacker()
        let engine = SessionEngine(mount: mount, stacker: stacker, hooks: makeHooks())

        engine.start(shot: makeShot(subs: 10))
        try await waitUntil("authorityNeeded interruption") {
            engine.interruption == .authorityNeeded
        }
        XCTAssertEqual(engine.phase, .connect, "Must hold in Connect until the trigger squeeze")
        XCTAssertEqual(engine.stats.subsAccepted, 0)

        mount.authority = .granted   // user squeezes the trigger
        try await waitUntil("phase == .complete") { engine.phase == .complete }

        XCTAssertNil(engine.interruption, "Authority interruption must clear once granted")
        XCTAssertEqual(engine.stats.subsAccepted, 10)
    }

    // MARK: Flap (mid-capture undock → re-dock)

    func testMidCaptureFlapPausesThenAutoResumesAndCountsRecovery() async throws {
        let mount = SessionMockMount()
        let stacker = SessionMockStacker()
        let engine = SessionEngine(mount: mount, stacker: stacker, hooks: makeHooks())

        engine.start(shot: makeShot(subs: 60))
        try await waitUntil("some subs captured") { engine.stats.subsAccepted >= 5 }

        mount.connection = .flapping(since: Date())
        try await waitUntil("gimbalFlapping interruption") {
            engine.interruption == .gimbalFlapping
        }
        XCTAssertEqual(engine.phase, .capture, "Flap pauses capture; it does not end the session")

        // While undocked, capture must be fully paused.
        let frozenCount = engine.stats.subsAccepted
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.stats.subsAccepted, frozenCount,
                       "No subs may be captured while the gimbal is flapping")

        // Re-dock: auto-resume, count the recovery, invalidate pointing.
        mount.connection = .docked(name: "MockFlow")
        try await waitUntil("interruption cleared") { engine.interruption == nil }
        try await waitUntil("phase == .complete") { engine.phase == .complete }

        XCTAssertEqual(engine.stats.flapsRecovered, 1)
        XCTAssertTrue(engine.pointingInvalidated,
                      "Re-dock can recenter the head — pointing must be flagged invalid")
        XCTAssertEqual(engine.stats.subsAccepted + engine.stats.subsRejected, 60,
                       "Capture must resume and finish the plan after recovery")
    }

    // MARK: Thermal guardian

    func testThermalCriticalStopsGracefullyWithPartialStats() async throws {
        let mount = SessionMockMount()
        let stacker = SessionMockStacker()
        let thermalBox = SessionValueBox(ProcessInfo.ThermalState.nominal)
        let hooks = makeHooks(thermal: { thermalBox.value })
        let engine = SessionEngine(mount: mount, stacker: stacker, hooks: hooks)

        engine.start(shot: makeShot(subs: 40))
        try await waitUntil("some subs captured") { engine.stats.subsAccepted >= 5 }

        thermalBox.value = .critical
        try await waitUntil("phase == .complete") { engine.phase == .complete }
        try await waitUntil("engine idle") { !engine.isRunning }

        XCTAssertEqual(engine.interruption, .thermalCritical,
                       "The stop reason must stay visible for the landing report")
        XCTAssertGreaterThanOrEqual(engine.stats.subsAccepted, 5)
        XCTAssertLessThan(engine.stats.subsAccepted, 40, "Must stop early, not finish the plan")
        XCTAssertNotNil(engine.latestPreview, "Graceful stop must still develop the partial stack")
        XCTAssertGreaterThanOrEqual(mount.stopCount, 1)
    }

    // MARK: Abort

    func testAbortMidCaptureIsSafeAndKeepsPartialData() async throws {
        let mount = SessionMockMount()
        let stacker = SessionMockStacker()
        let engine = SessionEngine(mount: mount, stacker: stacker, hooks: makeHooks())

        engine.start(shot: makeShot(subs: 500))
        try await waitUntil("some subs captured") { engine.stats.subsAccepted >= 3 }

        engine.abort()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.phase, .complete, "Abort with data ends at the landing report")
        XCTAssertNil(engine.interruption)
        XCTAssertNotNil(engine.latestPreview)
        try await waitUntil("mount stopped") { mount.stopCount >= 1 }
    }

    // MARK: Registry + feasibility gates

    func testRegistryHasNineWellFormedModes() {
        let all = ShotModeRegistry.all
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(Set(all.map(\.id)).count, 9, "Mode ids must be unique")
        for mode in all {
            XCTAssertEqual(mode.tutorial.count, 4, "\(mode.id) must ship a 4-step tutorial")
            XCTAssertFalse(mode.expectation.isEmpty, "\(mode.id) needs honest expectation copy")
            XCTAssertGreaterThanOrEqual(mode.checklist.count, 4,
                                        "\(mode.id) must ship a setup checklist")
            XCTAssertFalse(mode.checklist.contains(where: \.isEmpty),
                           "\(mode.id): checklist rows must not be blank")
            XCTAssertLessThanOrEqual(mode.recipe.exposureSeconds, 1.0,
                                     "\(mode.id): 1 s is the hard third-party exposure cap")
            XCTAssertGreaterThan(mode.recipe.targetSubCount, 0)
        }
        let ids = Set(all.map(\.id))
        for expected in ["milkyway", "startrails", "lunar", "isspass", "timelapse",
                         "cityscape", "aurora", "meteors", "conjunction"] {
            XCTAssertTrue(ids.contains(expected), "Missing mode id: \(expected)")
        }
    }

    func testFeasibilityGates() throws {
        let darkSky = makeSky()
        let citySky = makeSky()

        let milkyway = try XCTUnwrap(ShotModeRegistry.mode(id: "milkyway"))
        XCTAssertTrue(isNotTonight(milkyway.feasibility(citySky, .city)),
                      "Milky Way must gate out of city skies")
        XCTAssertEqual(milkyway.feasibility(darkSky, .dark), .great)
        let noCore = makeSky(coreVisible: false)
        XCTAssertTrue(isNotTonight(milkyway.feasibility(noCore, .dark)),
                      "Milky Way must gate when the core isn't up tonight")

        let lunar = try XCTUnwrap(ShotModeRegistry.mode(id: "lunar"))
        let moonUp = makeSky(moonFrac: 0.6, moonAlt: 45)
        XCTAssertEqual(lunar.feasibility(moonUp, .city), .great,
                       "Bright moon well above the horizon is a great lunar night, even in a city")
        let moonDown = makeSky(moonFrac: 0.6, moonAlt: -10)
        XCTAssertTrue(isNotTonight(lunar.feasibility(moonDown, .city)))
        let newMoon = makeSky(moonFrac: 0.02, moonAlt: 30)
        XCTAssertTrue(isNotTonight(lunar.feasibility(newMoon, .city)))

        let trails = try XCTUnwrap(ShotModeRegistry.mode(id: "startrails"))
        XCTAssertEqual(trails.feasibility(citySky, .city), .great,
                       "Star trails is the city-viable hero shot")
        let dusk = makeSky(sunAlt: -3)
        XCTAssertTrue(isNotTonight(trails.feasibility(dusk, .city)))

        let iss = try XCTUnwrap(ShotModeRegistry.mode(id: "isspass"))
        XCTAssertTrue(isPossible(iss.feasibility(darkSky, .city)),
                      "ISS needs a pass time — always 'possible' with a note")

        let meteors = try XCTUnwrap(ShotModeRegistry.mode(id: "meteors"))
        XCTAssertTrue(isNotTonight(meteors.feasibility(citySky, .city)))
        XCTAssertEqual(meteors.feasibility(darkSky, .dark), .great)

        let conjunction = try XCTUnwrap(ShotModeRegistry.mode(id: "conjunction"))
        let twilight = makeSky(sunAlt: -8, dark: false)
        XCTAssertEqual(conjunction.feasibility(twilight, .city), .great,
                       "Conjunction shines in the twilight window")
    }

    // MARK: Sky fixture

    private func makeSky(coreVisible: Bool = true, sunAlt: Double = -20, dark: Bool = true,
                         moonFrac: Double = 0.05, moonAlt: Double = -10,
                         lat: Double = 40) -> SkyContext {
        SkyContext(
            date: Date(),
            location: GeoLocation(latitude: lat, longitude: -105),
            sunAltitudeDeg: sunAlt,
            isAstronomicalDark: dark,
            darknessWindow: (start: Date(), end: Date().addingTimeInterval(6 * 3600)),
            moon: MoonInfo(illuminatedFraction: moonFrac, phaseName: "Waxing crescent",
                           position: HorizontalCoord(altitudeDeg: moonAlt, azimuthDeg: 120)),
            milkyWayCore: HorizontalCoord(altitudeDeg: 25, azimuthDeg: 180),
            coreVisibleTonight: coreVisible,
            lstHours: 18)
    }

    private func isNotTonight(_ f: Feasibility) -> Bool {
        if case .notTonight = f { return true }
        return false
    }

    private func isPossible(_ f: Feasibility) -> Bool {
        if case .possible = f { return true }
        return false
    }
}
