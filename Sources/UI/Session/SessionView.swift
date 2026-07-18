import SwiftUI
import Foundation
import CoreGraphics
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Flighty-style live session tracker bound to `SessionEngine.shared`.
/// Presented with the shot the user chose; starts the engine on appear.
/// Aborts on disappear only if the user explicitly confirmed leaving mid-session.
struct SessionView: View {
    let shot: ShotModeItem

    @ObservedObject private var appearance = Appearance.shared
    @ObservedObject private var engine = SessionEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showEndDialog = false
    @State private var abortOnExit = false
    @State private var loggedSession = false
    /// The record `logSessionIfNeeded` filed — the landing report's share card
    /// renders from THIS, so the card and the logbook can never disagree.
    @State private var loggedRecord: SessionRecord?
    @State private var showGimbalSchool = false
    @StateObject private var framing = FramingGuidanceModel()

    init(shot: ShotModeItem) {
        self.shot = shot
    }

    var body: some View {
        let night = appearance.nightMode
        ZStack {
            Theme.screenBg(night).ignoresSafeArea()
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                content(now: context.date, night: night)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            #if canImport(UIKit)
            UIDevice.current.isBatteryMonitoringEnabled = true
            #endif
            SessionEngine.shared.start(shot: shot)
            if SessionEngine.shared.phase == .aim, let target = shot.celestialTarget {
                framing.start(target: target)
            }
        }
        .onDisappear {
            framing.stop()
            // Only abort if the user explicitly chose to leave mid-session.
            if abortOnExit {
                SessionEngine.shared.abort()
                // abort() lands on .complete when frames were kept — log those too.
                if SessionEngine.shared.phase == .complete {
                    logSessionIfNeeded()
                }
            }
        }
        .onChange(of: engine.timelapseVideoURL) { _, newURL in
            // The user-stop path assembles the clip AFTER the record was filed
            // (assembly must never block the stop button) — link the finished
            // clip back into the logbook record when it lands.
            guard let newURL, var record = loggedRecord,
                  record.timelapseFilename == nil else { return }
            record.timelapseFilename = newURL.lastPathComponent
            // save() keeps the existing thumbnail when none is passed.
            SessionStore.shared.save(record)
            loggedRecord = record
        }
        .onChange(of: engine.phase) { oldPhase, newPhase in
            guard oldPhase != newPhase else { return }
            phaseFeedback(for: newPhase)
            // Framing guidance lives in the Aim phase only.
            if newPhase == .aim, let target = shot.celestialTarget {
                framing.start(target: target)
            } else {
                framing.stop()
            }
            if newPhase == .complete {
                logSessionIfNeeded()
            }
        }
        .sheet(isPresented: $showGimbalSchool) {
            gimbalSchoolSheet(night: night)
        }
        .confirmationDialog("Stop this session?", isPresented: $showEndDialog, titleVisibility: .visible) {
            Button("Stop & develop the stack") {
                SessionEngine.shared.abort()
            }
            Button("Stop & leave now", role: .destructive) {
                abortOnExit = true
                dismiss()
            }
            Button("Keep shooting", role: .cancel) {}
        } message: {
            Text("Everything captured so far is kept either way. Developing shows your landing report here.")
        }
    }

    // MARK: - Live content

    @ViewBuilder
    private func content(now: Date, night: Bool) -> some View {
        let phase = engine.phase
        let stats = engine.stats

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(phase: phase, stats: stats, now: now, night: night)

                SFCard { PhaseTimeline(phase: phase, night: night) }

                if phase == .complete {
                    // A guardian stop reason (thermal, battery, camera denied…) must
                    // stay visible on the landing report — never end silently.
                    if let interruption = engine.interruption {
                        GuardianBanner(interruption: interruption, night: night)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    LandingReport(shot: shot, stats: stats, preview: engine.latestPreview,
                                  simulated: engine.captureSourceIsSimulated,
                                  record: loggedRecord,
                                  timelapseURL: engine.timelapseVideoURL,
                                  night: night, onNewSession: { dismiss() })
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.94).combined(with: .opacity),
                            removal: .opacity))
                } else {
                    Group {
                        if phase == .connect && shot.needsGimbal && !gimbalDocked {
                            gimbalWaitCard(night: night)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if phase == .aim, let target = shot.celestialTarget {
                            aimAssistCard(target: target, night: night)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        heroCard(stats: stats, phase: phase, night: night)
                        previewCard(phase: phase, stats: stats, preview: engine.latestPreview, night: night)
                        telemetryCard(stats: stats, phase: phase, night: night)

                        if let interruption = engine.interruption {
                            GuardianBanner(interruption: interruption, night: night)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        footerControls(phase: phase, night: night)
                    }
                    .transition(.opacity)
                }
            }
            .padding(16)
            .animation(.spring(duration: 0.45), value: engine.interruption)
            .animation(.spring(duration: 0.55, bounce: 0.25), value: phase)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Phase feedback (haptics) + logbook

    /// A gentle tap as the session advances a phase; a success chord on landing.
    private func phaseFeedback(for newPhase: SessionPhase) {
        #if canImport(UIKit)
        if newPhase == .complete {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        #endif
    }

    /// File this session in the logbook exactly once, preview thumbnail included.
    private func logSessionIfNeeded() {
        guard !loggedSession else { return }
        loggedSession = true
        let stats = engine.stats
        let record = SessionRecord(
            id: UUID(),
            date: stats.startedAt ?? Date(),
            shotID: shot.id,
            shotName: shot.name,
            integrationSeconds: stats.integrationSeconds,
            subsAccepted: stats.subsAccepted,
            subsRejected: stats.subsRejected,
            nudges: stats.nudges,
            flapsRecovered: stats.flapsRecovered,
            targetSubCount: shot.recipe.targetSubCount,
            captureTilt: stats.captureTilt,
            // .unknown means "never had enough starry frames to grade" — store
            // nothing rather than a hollow verdict.
            skyCondition: stats.skyCondition == .unknown ? nil : stats.skyCondition,
            subsSkippedClouds: stats.subsSkippedClouds,
            subsLostToClouds: stats.subsLostToClouds,
            // 0 = calibration never ran/declined — store nothing, so the share
            // card's "calibrated against N stars" line can never be hollow.
            calibrationStars: stats.calibrationStars > 0 ? stats.calibrationStars : nil,
            // Simulated capture is remembered so the share card stays honest
            // even when shared from the logbook weeks later.
            simulatedCapture: engine.captureSourceIsSimulated ? true : nil,
            // Timelapse clip (feature 8): on the normal path assembly finishes
            // before .complete, so the filename lands here; the user-stop path
            // links it via the onChange above once assembly catches up.
            timelapseFilename: engine.timelapseVideoURL?.lastPathComponent)
        // latestPreview is already rotated upright by the engine's develop phase,
        // so the logbook thumbnail and share sheet inherit the correct orientation.
        SessionStore.shared.save(record, thumbnail: engine.latestPreview)
        loggedRecord = record
        resolveCityIfPossible(for: record)
    }

    /// Best-effort: reverse-geocode the session's location fix into a city
    /// name and re-save the record with it (share card's optional location
    /// line). Requires a real fix; failure stores nothing — never a guess.
    private func resolveCityIfPossible(for record: SessionRecord) {
        guard let location = AppLocation.shared.current else { return }
        Task { @MainActor in
            guard let city = await CityResolver.city(for: location), !city.isEmpty
            else { return }
            // Base the update on the FRESHEST copy of the record, not the one
            // captured before geocoding: on the user-stop path the timelapse
            // onChange above may have linked the clip's filename while the
            // geocoder was in flight, and re-saving the stale capture would
            // silently clobber that link (orphaning the clip forever — the URL
            // never publishes twice). Both closures run on the MainActor, so
            // whichever lands second sees the other's write.
            var updated = (loggedRecord?.id == record.id ? loggedRecord : nil) ?? record
            updated.locationCity = city
            // save() keeps the existing thumbnail when none is passed.
            SessionStore.shared.save(updated)
            if loggedRecord?.id == record.id { loggedRecord = updated }
        }
    }

    // MARK: - Aim Assist status card

    /// Shown during the Aim phase for modes with a celestial target: names the
    /// target, mirrors the engine's live status line, and is honest about the
    /// compass-coarse accuracy so nobody expects telescope-grade pointing.
    private func aimAssistCard(target: CelestialTarget, night: Bool) -> some View {
        SFCard(accent: Theme.accent(night)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent(night))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aim Assist")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Text("Target: \(target.displayName)")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                    Spacer(minLength: 0)
                }
                Text(engine.statusDetail)
                    .font(Theme.body)
                    .foregroundStyle(Theme.primaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: engine.statusDetail)
                framingGuidanceRows(night: night)
                Text("Compass-coarse aim: ±10° — fine-tune by hand if needed.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Live "where's the core?" readout inside the Aim Assist card: an arrow
    /// pointing the way plus the offset in degrees ("Core: 12° left"), computed
    /// by the pure `FramingGuide` from the compass attitude and the
    /// SkyEngine-resolved target. Degrades honestly: no motion hardware or no
    /// location fix shows a one-line reason instead of a fake arrow.
    @ViewBuilder
    private func framingGuidanceRows(night: Bool) -> some View {
        if let reading = framing.reading {
            HStack(spacing: 10) {
                Group {
                    if let angle = FramingGuide.arrowAngleDeg(offset: reading.offset) {
                        Image(systemName: "arrow.up.circle.fill")
                            .rotationEffect(.degrees(angle))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent(night))
                .animation(.easeInOut(duration: 0.3), value: reading.offset)
                Text(reading.line)
                    .font(Theme.liveValue(15))
                    .foregroundStyle(Theme.primaryText(night))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Framing guidance: \(reading.line)")
        } else if let reason = framing.unavailableReason {
            Text(reason)
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryText(night))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Gimbal never docks: guide card + school sheet

    private var gimbalDocked: Bool {
        if case .docked = engine.mountConnection { return true }
        return false
    }

    private func gimbalWaitCard(night: Bool) -> some View {
        SFCard(accent: Theme.warning(night)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.warning(night))
                    Text("Waiting for the gimbal")
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                }
                Text("This shot drives the Flow 2 Pro's motors. Power the gimbal on and dock your iPhone — the session continues by itself the moment it connects.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    showGimbalSchool = true
                } label: {
                    Label("Open gimbal school", systemImage: "hand.tap.fill")
                        .font(Theme.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent(night))
                .background(
                    Capsule()
                        .fill(Theme.accent(night).opacity(0.12))
                        .overlay(Capsule().strokeBorder(Theme.accent(night).opacity(0.4), lineWidth: 1))
                )
                .accessibilityHint("Shows the four-step gimbal setup lesson.")
            }
        }
    }

    private func gimbalSchoolSheet(night: Bool) -> some View {
        NavigationStack {
            ZStack {
                Theme.screenBg(night).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("The two-minute gimbal school. The trigger squeeze is the one everyone forgets.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.secondaryText(night))
                        GimbalSchoolView()
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Gimbal school")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showGimbalSchool = false }
                        .foregroundStyle(Theme.accent(night))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private func header(phase: SessionPhase, stats: SessionStats, now: Date, night: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shot.name)
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                if let startedAt = stats.startedAt, phase != .complete {
                    Text("Elapsed \(sessionClock(now.timeIntervalSince(startedAt)))")
                        .font(Theme.liveValue(13))
                        .foregroundStyle(Theme.secondaryText(night))
                } else {
                    Text(shot.tagline)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                phaseBadge(phase, night: night)
                if engine.captureSourceIsSimulated {
                    SimulatedBadge()
                }
            }
        }
    }

    private func phaseBadge(_ phase: SessionPhase, night: Bool) -> some View {
        let tint = phase == .complete ? Theme.positive(night) : Theme.accent(night)
        return Text(phase.rawValue.uppercased())
            .font(Theme.label)
            .kerning(1.2)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    // MARK: - Hero: integration counter

    private func heroCard(stats: SessionStats, phase: SessionPhase, night: Bool) -> some View {
        let target = max(shot.recipe.targetSubCount, 1)
        let progress = min(1.0, Double(stats.subsAccepted) / Double(target))
        return SFCard {
            VStack(alignment: .leading, spacing: 14) {
                SFSectionLabel("Integration")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sessionClock(stats.integrationSeconds))
                        .font(Theme.heroNumber(56))
                        .foregroundStyle(Theme.primaryText(night))
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.35), value: stats.integrationSeconds)
                    Text("min")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Integration \(TonightFormat.spokenDuration(stats.integrationSeconds))")
                ProgressView(value: progress)
                    .tint(Theme.accent(night))
                    .accessibilityLabel("Capture progress")
                // Live depth meter: qualitative tier for the growing stack,
                // honest per the MEASURED sky (pure IntegrationDepth math).
                // Milky Way sessions only — the tier copy ("faint arms
                // emerging") and the 5/15/30-min thresholds are calibrated to
                // a 1 s / ISO 3200 Milky Way stack. It would be false copy on
                // a Moon or ISS stack and meaningless for trails/timelapse.
                if phase == .capture, shot.stackingStyle == .registered,
                   shot.celestialTarget == .milkyWayCore,
                   stats.subsAccepted > 0 {
                    Text(IntegrationDepth.line(integratedSeconds: stats.integrationSeconds,
                                               condition: engine.skyCondition))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                        .accessibilityLabel(
                            IntegrationDepth.line(integratedSeconds: stats.integrationSeconds,
                                                  condition: engine.skyCondition))
                }
                HStack(spacing: 8) {
                    SFStatChip(symbol: "checkmark.circle", value: "\(stats.subsAccepted)",
                               label: "accepted", tint: Theme.positive(night))
                    SFStatChip(symbol: "xmark.circle", value: "\(stats.subsRejected)",
                               label: "rejected",
                               tint: stats.subsRejected > 0 ? Theme.warning(night) : nil)
                    if stats.subsSkippedClouds > 0 {
                        SFStatChip(symbol: "cloud.fill", value: "\(stats.subsSkippedClouds)",
                                   label: "cloud waits", tint: Theme.warning(night))
                    }
                    SFStatChip(symbol: "square.stack.3d.up", value: "\(shot.recipe.targetSubCount)",
                               label: "target")
                }
            }
        }
    }

    // MARK: - Live preview

    private func previewCard(phase: SessionPhase, stats: SessionStats, preview: CGImage?, night: Bool) -> some View {
        SFCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SFSectionLabel("Live stack")
                    Spacer()
                    if engine.captureSourceIsSimulated {
                        SimulatedBadge()
                    }
                }
                ZStack {
                    if let preview {
                        // scaledToFit, not Fill: the card must show the stack's TRUE
                        // aspect (field report: a fill-cropped landscape stack read
                        // as portrait in-app while the export was landscape).
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .colorMultiply(night ? Theme.nightRed : .white)
                    } else {
                        StarfieldPlaceholder(night: night)
                            .frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .bottomLeading) {
                                Text(phase == .capture
                                     ? "First preview lands after the first accepted subs."
                                     : "Preview appears once capture begins.")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.secondaryText(night))
                                    .padding(10)
                            }
                    }
                    if phase == .develop {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.55))
                            .frame(height: 220)
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(Theme.accent(night))
                            Text("Aligning and stacking \(stats.subsAccepted) subs…")
                                .font(Theme.body)
                                .foregroundStyle(Theme.primaryText(night))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Telemetry chips

    private func telemetryCard(stats: SessionStats, phase: SessionPhase, night: Bool) -> some View {
        let heat = thermal
        return SFCard {
            VStack(spacing: 14) {
                if MountService.isSimulated {
                    HStack(spacing: 8) {
                        SimulatedSourceBadge()
                        Text("Gimbal readings come from the simulated mount.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 8) {
                    SFStatChip(symbol: "battery.75", value: gimbalBattery, label: "gimbal")
                    SFStatChip(symbol: "iphone", value: phoneBattery, label: "phone")
                    SFStatChip(symbol: "thermometer.medium", value: heat.0, label: "thermal",
                               tint: heat.1 ? Theme.warning(night) : nil)
                }
                HStack(spacing: 8) {
                    SFStatChip(symbol: "scope", value: "\(stats.nudges)", label: "nudges")
                    SFStatChip(symbol: "location.north.line", value: driftStatus(phase: phase), label: "drift")
                    SFStatChip(symbol: "arrow.triangle.2.circlepath", value: "\(stats.flapsRecovered)", label: "flaps")
                }
                focusRows(phase: phase, night: night)
                Divider()
                    .overlay(Theme.secondaryText(night).opacity(0.2))
                sourceTruthRows(stats: stats, phase: phase, night: night)
            }
        }
    }

    // MARK: - Focus chip (sweep progress + live sharpness meter)

    /// Focus rows in the telemetry card. During the pre-capture focus sweep a
    /// progress line narrates position N of M; once subs are flowing, a meter
    /// shows the newest frame's star sharpness against the rolling mean — the
    /// metric is relative (variance of Laplacian), so the bar, not a number,
    /// is the honest display. A drift alarm warns when stars are softening
    /// (focus creep, dew, a bumped lens).
    @ViewBuilder
    private func focusRows(phase: SessionPhase, night: Bool) -> some View {
        if case .running(let step, let planned) = engine.focusSweepStatus {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Theme.accent(night))
                Text("Focus sweep — position \(step) of \(planned)")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.accent(night))
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Focus sweep in progress, position \(step) of \(planned)")
        }
        if phase == .capture,
           let sharpness = engine.focusSharpness,
           let mean = engine.focusSharpnessMean, mean > 0 {
            let drifting = engine.focusDrifting
            // On-mean sharpness fills two-thirds of the bar; the drift alarm
            // (30% below mean) lands just under half — visibly sagging.
            let fraction = max(0.05, min(1.0, (sharpness / mean) / 1.5))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "camera.metering.spot")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(drifting ? Theme.warning(night) : Theme.accent(night))
                    Text("focus")
                        .font(Theme.label)
                        .foregroundStyle(Theme.secondaryText(night))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Theme.secondaryText(night).opacity(0.18))
                            Capsule()
                                .fill(drifting ? Theme.warning(night) : Theme.positive(night))
                                .frame(width: max(6, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 6)
                }
                if drifting {
                    Text("Focus drifted — stars softening")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning(night))
                } else if case .locked(_, true) = engine.focusSweepStatus {
                    Text("Best focus locked by the pre-capture sweep")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(focusMeterAccessibilityLabel(drifting: drifting))
        }
    }

    /// VoiceOver text for the focus meter — mirrors everything the sighted
    /// captions say, including the sweep-lock note the `.ignore` element would
    /// otherwise swallow.
    private func focusMeterAccessibilityLabel(drifting: Bool) -> String {
        if drifting { return "Focus warning: focus drifted, stars softening" }
        if case .locked(_, true) = engine.focusSweepStatus {
            return "Focus sharpness steady. Best focus locked by the pre-capture sweep."
        }
        return "Focus sharpness steady"
    }

    // MARK: - Source truth (camera + stacker)

    /// Compact rows under the telemetry chips stating exactly where frames come from
    /// and what the stacker is doing with them. Field lesson: indoors, star
    /// registration rejects every frame (a starless room can't match 5 stars) —
    /// without these rows a healthy camera looks like a broken app.
    @ViewBuilder
    private func sourceTruthRows(stats: SessionStats, phase: SessionPhase, night: Bool) -> some View {
        let camera = cameraTruth(phase: phase, night: night)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(camera.dot)
                    .frame(width: 8, height: 8)
                Text(camera.text)
                    .font(Theme.caption)
                    .foregroundStyle(camera.tint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(camera.text)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent(night))
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(engine.statusDetail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session status: \(engine.statusDetail)")

            if phase == .capture, stats.subsRejected >= 3, stats.subsRejected > stats.subsAccepted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.warning(night))
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    Text("\(stats.subsRejected) of \(stats.subsAccepted + stats.subsRejected) frames rejected — "
                         + "alignment needs at least 5 matched stars per frame. Indoors or under thick "
                         + "cloud every frame is rejected: the camera is working; the view has no stars.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.warning(night))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// One honest line about the capture source. Green dot only when the sensor is
    /// authorized AND the session is actually in its camera-running window.
    private func cameraTruth(phase: SessionPhase, night: Bool)
        -> (dot: Color, text: String, tint: Color) {
        if engine.captureSourceIsSimulated {
            return (Theme.rose,
                    "Camera: simulated — synthetic frames (simulator build)",
                    Theme.rose)
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            if phase == .capture || phase == .develop {
                return (Theme.positive(night),
                        "Camera: live — capturing real sensor frames",
                        Theme.primaryText(night))
            }
            return (Theme.secondaryText(night),
                    "Camera: authorized — the sensor starts at the Capture phase",
                    Theme.secondaryText(night))
        case .notDetermined:
            return (Theme.warning(night),
                    "Camera: not asked yet — iOS prompts when Capture begins",
                    Theme.warning(night))
        default:
            return (Theme.danger(night),
                    "Camera: denied — enable Camera for StarFlow in iOS Settings",
                    Theme.danger(night))
        }
    }

    private var gimbalBattery: String {
        if let percent = MountService.shared.telemetry?.batteryPercent {
            return "\(percent)%"
        }
        return "—"
    }

    private var phoneBattery: String {
        #if canImport(UIKit)
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return "—" }   // simulator reports -1
        return "\(Int((level * 100).rounded()))%"
        #else
        return "—"
        #endif
    }

    private var thermal: (String, Bool) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return ("OK", false)
        case .fair: return ("Fair", false)
        case .serious: return ("Hot", true)
        case .critical: return ("Crit", true)
        @unknown default: return ("—", false)
        }
    }

    private func driftStatus(phase: SessionPhase) -> String {
        guard shot.recipe.nudgeTracking else { return "Off" }
        switch phase {
        case .capture: return "Held"
        case .develop, .complete: return "Done"
        default: return "Armed"
        }
    }

    // MARK: - Footer: stop / developing

    @ViewBuilder
    private func footerControls(phase: SessionPhase, night: Bool) -> some View {
        if phase == .develop {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Theme.accent(night))
                Text("Developing — hold tight, your landing report is next.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            Button {
                showEndDialog = true
            } label: {
                Label("Stop session", systemImage: "stop.circle.fill")
                    .font(Theme.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .foregroundStyle(Theme.danger(night))
            .background(
                Capsule()
                    .fill(Theme.danger(night).opacity(0.12))
                    .overlay(Capsule().strokeBorder(Theme.danger(night).opacity(0.45), lineWidth: 1))
            )
            .padding(.top, 4)
            .accessibilityHint("Asks to confirm before ending the session. Everything captured is kept.")
        }
    }
}

// MARK: - Shared formatting

/// mm:ss (or h:mm:ss past an hour), monospaced-digit friendly.
private func sessionClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Phase timeline

private struct PhaseTimeline: View {
    let phase: SessionPhase
    let night: Bool

    private static let steps: [SessionPhase] = [.connect, .aim, .calibrate, .capture, .develop]

    private var currentIndex: Int {
        if phase == .complete { return Self.steps.count }
        return Self.steps.firstIndex(of: phase) ?? 0
    }

    private var fraction: CGFloat {
        min(1, CGFloat(currentIndex) / CGFloat(Self.steps.count - 1))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    stepCapsule(step: step, index: index)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.secondaryText(night).opacity(0.18))
                        .frame(height: 3)
                    Capsule()
                        .fill(Theme.accent(night))
                        .frame(width: geo.size.width * fraction, height: 3)
                }
            }
            .frame(height: 3)
        }
        .animation(.spring(duration: 0.6, bounce: 0.3), value: currentIndex)
    }

    private func stepCapsule(step: SessionPhase, index: Int) -> some View {
        let isCurrent = index == currentIndex
        let isDone = index < currentIndex
        return Text(step.rawValue)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
                Capsule()
                    .fill(isCurrent ? Theme.accent(night).opacity(0.16) : Color.clear)
                    .overlay(
                        Capsule().strokeBorder(
                            isCurrent
                                ? Theme.accent(night)
                                : (isDone ? Theme.accent(night).opacity(0.4)
                                          : Theme.secondaryText(night).opacity(0.25)),
                            lineWidth: 1)
                    )
            )
            .foregroundStyle(
                isCurrent
                    ? Theme.accent(night)
                    : (isDone ? Theme.primaryText(night) : Theme.secondaryText(night))
            )
    }
}

// MARK: - Guardian banners

private struct GuardianBanner: View {
    let interruption: SessionInterruption
    let night: Bool

    var body: some View {
        let s = spec
        SFCard(accent: s.tint) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: s.symbol)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(s.tint)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(s.message)
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var spec: (symbol: String, title: String, message: String, tint: Color) {
        switch interruption {
        case .authorityNeeded:
            return ("hand.tap.fill",
                    "Squeeze the trigger",
                    "The motors are waiting for permission. Squeeze the front trigger once — the ring light turns solid — and StarFlow takes it from there. Your stack is paused, not lost.",
                    Theme.accent(night))
        case .gimbalFlapping:
            return ("antenna.radiowaves.left.and.right",
                    "Gimbal reconnecting — stack is safe",
                    "The dock link dropped for a moment. Capture resumes by itself when it re-docks, and pointing gets re-checked.",
                    Theme.warning(night))
        case .gimbalLost:
            return ("bolt.horizontal.circle",
                    "Gimbal connection lost",
                    "It didn't come back within \(Int(GimbalConstants.flapDebounce)) seconds. Re-dock the phone — everything stacked so far is safe.",
                    Theme.danger(night))
        case .thermalBackoff:
            return ("thermometer.medium",
                    "Cooling down",
                    "The phone is running warm, so capture cadence is slowed. Slightly fewer subs per minute; the stack keeps growing.",
                    Theme.warning(night))
        case .thermalCritical:
            return ("thermometer.sun.fill",
                    "Too hot — saving your stack",
                    "Thermal limit reached. StarFlow is stopping gracefully and keeping everything captured so far.",
                    Theme.danger(night))
        case .batteryLow(let percent):
            return ("battery.25",
                    "Battery at \(percent)%",
                    "Below 20% the session stops and saves automatically. Plug in now to keep integrating.",
                    Theme.danger(night))
        case .storageLow:
            return ("internaldrive.fill",
                    "Storage low",
                    "Free up space soon — the session will stop early and save if the disk fills.",
                    Theme.warning(night))
        case .backgrounded:
            return ("moon.zzz.fill",
                    "Paused in background",
                    "Capture pauses while StarFlow is backgrounded. Come back to resume — the stack is safe.",
                    Theme.warning(night))
        case .cameraDenied:
            return ("camera.badge.ellipsis",
                    "Camera access needed",
                    "StarFlow can't capture stars without the camera — and it never fakes them. Enable Camera for StarFlow in Settings, then start the session again.",
                    Theme.danger(night))
        }
    }
}

// MARK: - Simulated-source badge

/// Unmistakable rose "SIMULATED" pill shown wherever a simulated capture source is
/// active (simulator builds), so synthetic stars can never masquerade as real data.
struct SimulatedBadge: View {
    var body: some View {
        Text("SIMULATED")
            .font(Theme.label)
            .kerning(1.2)
            .foregroundStyle(Theme.rose)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Theme.rose.opacity(0.16))
                    .overlay(Capsule().strokeBorder(Theme.rose.opacity(0.55), lineWidth: 1))
            )
            .accessibilityLabel("Simulated data source")
    }
}

// MARK: - Landing report

private struct LandingReport: View {
    let shot: ShotModeItem
    let stats: SessionStats
    let preview: CGImage?
    let simulated: Bool
    /// The logbook record this session filed — share cards render from it
    /// (and only it), so the card can never claim more than the logbook holds.
    let record: SessionRecord?
    /// The assembled timelapse clip (feature 8), when this session made one.
    let timelapseURL: URL?
    let night: Bool
    let onNewSession: () -> Void

    @State private var showTimelapsePlayer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SFCard(accent: Theme.positive(night)) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Theme.positive(night))
                        Text("Session complete")
                            .font(Theme.title)
                            .foregroundStyle(Theme.primaryText(night))
                        if simulated {
                            Spacer(minLength: 4)
                            SimulatedBadge()
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sessionClock(stats.integrationSeconds))
                            .font(Theme.heroNumber(52))
                            .foregroundStyle(Theme.primaryText(night))
                        Text("total integration")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Total integration \(TonightFormat.spokenDuration(stats.integrationSeconds))")
                    HStack(spacing: 8) {
                        SFStatChip(symbol: "square.stack.3d.up.fill", value: "\(stats.subsAccepted)",
                                   label: "subs stacked", tint: Theme.positive(night))
                        SFStatChip(symbol: "xmark.circle", value: "\(stats.subsRejected)",
                                   label: "rejected")
                        if stats.subsSkippedClouds > 0 {
                            SFStatChip(symbol: "cloud.fill", value: "\(stats.subsSkippedClouds)",
                                       label: "cloud waits")
                        }
                    }
                    HStack(spacing: 8) {
                        SFStatChip(symbol: "scope", value: "\(stats.nudges)", label: "nudges")
                        // Plate-solve drift corrections (feature 5) — shown only
                        // when one actually fired, mirroring the engine's
                        // completion summary so the report never undercounts
                        // what the narration already claimed.
                        if stats.driftCorrections > 0 {
                            SFStatChip(symbol: "location.north.line",
                                       value: "\(stats.driftCorrections)", label: "drift fixes")
                        }
                        SFStatChip(symbol: "arrow.triangle.2.circlepath", value: "\(stats.flapsRecovered)",
                                   label: "flaps recovered")
                    }
                    Text("Stacked from \(stats.subsAccepted) × 1 s subs — the honest way a phone does a long exposure.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                }
            }

            if let preview {
                let image = Image(decorative: preview, scale: 1)
                SFCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SFSectionLabel("Your stack")
                        // scaledToFit: the landing report must show exactly the
                        // aspect and orientation the share/export will have.
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .colorMultiply(night ? Theme.nightRed : .white)
                            .overlay(alignment: .topTrailing) {
                                if simulated { SimulatedBadge().padding(8) }
                            }
                        #if canImport(UIKit)
                        if let record {
                            // Share card first (feature 9), raw image second —
                            // both inside the section. Renders from the SAME
                            // record the logbook just filed.
                            ShareCardSection(record: record, image: preview, night: night)
                        } else {
                            rawOnlyShareLink(image: image, night: night)
                        }
                        #else
                        rawOnlyShareLink(image: image, night: night)
                        #endif
                    }
                }
            } else {
                SFCard {
                    Text("No preview image was produced this run — subs are saved, so nothing is lost.")
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryText(night))
                }
            }

            if let timelapseURL {
                timelapseCard(url: timelapseURL)
            } else if shot.producesTimelapse {
                // Honest placeholder: the user-stop path assembles the clip
                // AFTER landing (the card appears when the URL publishes), a
                // session can end before any frame was retained, and a failed
                // assembly is narrated by the engine — no fake spinner here.
                SFCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "film")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.accent(night))
                        Text("No video yet. If frames were kept for the clip, assembly "
                             + "runs right after the session ends and the video appears "
                             + "here — and in the Logbook — when it's done.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button(action: onNewSession) {
                Label("New session", systemImage: "plus.circle")
                    .font(Theme.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .foregroundStyle(Theme.accent(night))
            .background(Capsule().strokeBorder(Theme.accent(night).opacity(0.5), lineWidth: 1))
            .accessibilityHint("Closes this report and returns to the shot list.")
        }
        .sheet(isPresented: $showTimelapsePlayer) {
            if let timelapseURL {
                VideoPlayerSheet(url: timelapseURL, title: shot.name)
            }
        }
    }

    /// The timelapse deliverable: play it right here, share the .mp4 anywhere.
    private func timelapseCard(url: URL) -> some View {
        SFCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SFSectionLabel("Your timelapse")
                    Spacer()
                    if simulated { SimulatedBadge() }
                }
                Button {
                    showTimelapsePlayer = true
                } label: {
                    Label("Play the clip", systemImage: "play.circle.fill")
                        .font(Theme.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent(night))
                .background(Capsule().strokeBorder(Theme.accent(night).opacity(0.5), lineWidth: 1))
                .accessibilityHint("Plays the assembled timelapse video.")
                ShareLink(item: url) {
                    Label("Share the video", systemImage: "square.and.arrow.up")
                        .font(Theme.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .foregroundStyle(night ? Theme.nightRed : Color.black)
                .background(Capsule().fill(night ? Theme.nightRedDim.opacity(0.4) : Theme.gold))
                Text("Saved as an .mp4 in StarFlow's documents — it stays on this phone "
                     + "until you share it, and lives in the Logbook with this session.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Fallback share (raw stack only) for the pathological case where the
    /// report shows before the logbook record landed.
    private func rawOnlyShareLink(image: Image, night: Bool) -> some View {
        ShareLink(item: image,
                  preview: SharePreview("StarFlow — \(shot.name)", image: image)) {
            Label("Share the stack", systemImage: "square.and.arrow.up")
                .font(Theme.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .foregroundStyle(night ? Theme.nightRed : Color.black)
        .background(Capsule().fill(night ? Theme.nightRedDim.opacity(0.4) : Theme.gold))
    }
}

// MARK: - Framing guidance (Aim phase)

/// Live "where is the target relative to my frame?" feed for the Aim phase.
/// Polls the compass/attitude with the same `AimAssist` sensing path the
/// auto-aim slew uses, resolves the target with the same SkyEngine math, and
/// publishes a pure `FramingGuide` offset for the card to render.
///
/// Degrades gracefully and HONESTLY: no motion hardware (simulator), no
/// location fix, or a compass that never settles all surface as a one-line
/// reason instead of a fake arrow.
@MainActor
final class FramingGuidanceModel: ObservableObject {

    struct Reading: Equatable {
        var offset: FramingGuide.Offset
        var line: String
    }

    @Published private(set) var reading: Reading?
    @Published private(set) var unavailableReason: String?

    private var pollTask: Task<Void, Never>?
    private let assist = AimAssist()

    /// Begin polling (idempotent). Call when the Aim phase starts.
    func start(target: CelestialTarget) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let location = AppLocation.shared.current else {
                    self.reading = nil
                    self.unavailableReason =
                        "Waiting for a location fix to place \(target.displayName)."
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                do {
                    let attitude = try await self.assist.readAttitude(timeout: 2.0)
                    // stop() may have run while the read was in flight — a late
                    // publish would resurrect a reading stop() just cleared.
                    guard !Task.isCancelled else { return }
                    let coord = self.assist.resolve(target: target, location: location,
                                                    date: Date())
                    let offset = FramingGuide.offset(cameraAzimuthDeg: attitude.azimuthDeg,
                                                     cameraAltitudeDeg: attitude.altitudeDeg,
                                                     target: coord)
                    self.reading = Reading(
                        offset: offset,
                        line: FramingGuide.guidanceLine(offset: offset,
                                                        targetName: Self.shortName(for: target)))
                    self.unavailableReason = nil
                } catch AimAssistError.motionUnavailable {
                    // No motion hardware here (simulator / unsupported device) —
                    // it will not appear mid-session, so stop polling entirely.
                    guard !Task.isCancelled else { return }
                    self.reading = nil
                    self.unavailableReason =
                        "No motion sensors here — frame \(target.displayName) by eye."
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.reading = nil
                    self.unavailableReason =
                        "Compass unsettled — guidance resumes when it stabilizes."
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    /// Stop polling and release the motion sensors (idempotent).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        assist.stopMotionUpdates()
        reading = nil
        unavailableReason = nil
    }

    /// Short readout name ("Core: 12° left"), distinct from the sentence-form
    /// `displayName` ("the Milky Way") used in status prose.
    private static func shortName(for target: CelestialTarget) -> String {
        switch target {
        case .milkyWayCore: return "Core"
        case .moon: return "Moon"
        }
    }
}

// MARK: - Animated starfield placeholder

private struct StarfieldPlaceholder: View {
    let night: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSinceReferenceDate
                var rng = SeededRandom(seed: 42)
                for _ in 0..<90 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height
                    let base = 0.25 + rng.next() * 0.55
                    let speed = 0.4 + rng.next() * 1.2
                    let phase = rng.next() * .pi * 2
                    let twinkle = 0.55 + 0.45 * sin(t * speed + phase)
                    let r = 0.6 + rng.next() * 1.3
                    let color = (night ? Theme.nightRed : Color.white).opacity(base * twinkle)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(color))
                }
            }
            .background(night ? Color.black : Theme.bg)
        }
    }
}

/// Deterministic xorshift so the placeholder stars don't jump between frames.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
