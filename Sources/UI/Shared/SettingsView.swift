import SwiftUI
import Foundation
import AVFoundation
import CoreLocation

/// Settings tab: appearance, sky quality, capture prefs, gimbal, diagnostics, about.
struct SettingsView: View {
    @ObservedObject private var appearance = Appearance.shared
    @AppStorage("skyQuality") private var skyQualityRaw: Int = SkyQuality.suburb.rawValue
    @AppStorage("keepSubs") private var keepSubs: Bool = false
    @State private var showGimbalSchool = false

    init() {}

    var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                Theme.screenBg(night).ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        appearanceSection(night)
                        skySection(night)
                        captureSection(night)
                        gimbalSection(night)
                        diagnosticsSection(night)
                        aboutSection(night)
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .toolbarBackground(Theme.screenBg(night), for: .navigationBar)
        }
        .sheet(isPresented: $showGimbalSchool) {
            gimbalSchoolSheet(night)
        }
    }

    // MARK: - Appearance

    private func appearanceSection(_ night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SFSectionLabel("Appearance")
            SFCard {
                Toggle(isOn: Binding(
                    get: { appearance.nightMode },
                    set: { appearance.nightMode = $0 })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Red night mode")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Text("Pure red-on-black across the whole app. Protects dark adaptation — flip it before you step outside.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                }
                .tint(Theme.accent(night))
            }
        }
    }

    // MARK: - Sky

    private func skySection(_ night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SFSectionLabel("Sky")
            SFCard {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sky quality")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Text("Shot feasibility is judged against this sky.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                    Spacer()
                    Picker("Sky quality", selection: $skyQualityRaw) {
                        ForEach(SkyQuality.allCases, id: \.rawValue) { quality in
                            Text(quality.label).tag(quality.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent(night))
                    .labelsHidden()
                }
            }
        }
    }

    // MARK: - Capture

    private func captureSection(_ night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SFSectionLabel("Capture")
            SFCard {
                Toggle(isOn: $keepSubs) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep RAW subs")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Text("Save every 1-second frame next to the finished stack for re-processing later. Roughly 2 GB per half hour.")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                }
                .tint(Theme.accent(night))
            }
        }
    }

    // MARK: - Gimbal

    private func gimbalSection(_ night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SFSectionLabel("Gimbal")
            SFCard {
                VStack(alignment: .leading, spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 2)) { _ in
                        connectionRow(night)
                    }
                    Divider()
                        .overlay(Theme.secondaryText(night).opacity(0.2))
                    Text("Bench-verified on Insta360 Flow 2 Pro, firmware 5.50.80. Other firmware may respond differently to motor commands.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                    Button {
                        showGimbalSchool = true
                    } label: {
                        Label("Re-run the trigger lesson", systemImage: "hand.tap.fill")
                            .font(Theme.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
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
    }

    private func connectionRow(_ night: Bool) -> some View {
        let mount = MountService.shared
        let state: (dot: Color, text: String) = {
            switch mount.connection {
            case .searching:
                return (Theme.warning(night), "Searching for gimbal…")
            case .docked(let name):
                return (Theme.positive(night), name)
            case .flapping:
                return (Theme.warning(night), "Reconnecting…")
            case .undocked:
                return (Theme.secondaryText(night), "Not connected")
            }
        }()
        return HStack(spacing: 8) {
            Circle()
                .fill(state.dot)
                .frame(width: 8, height: 8)
            Text(state.text)
                .font(Theme.body)
                .foregroundStyle(Theme.primaryText(night))
            if MountService.isSimulated {
                SimulatedSourceBadge()
            }
            Spacer()
            if let percent = mount.telemetry?.batteryPercent {
                Text("\(percent)% battery")
                    .font(Theme.liveValue(13))
                    .foregroundStyle(Theme.secondaryText(night))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(connectionAccessibilityLabel(state.text,
                                                         battery: mount.telemetry?.batteryPercent))
    }

    private func connectionAccessibilityLabel(_ status: String, battery: Int?) -> String {
        let simulatedSuffix = MountService.isSimulated ? " Simulated data source." : ""
        guard let battery else { return "Gimbal: \(status).\(simulatedSuffix)" }
        return "Gimbal: \(status), battery \(battery) percent.\(simulatedSuffix)"
    }

    // MARK: - Diagnostics

    /// One card that answers "is anything blocking a session?" at a glance:
    /// camera + location permission, gimbal link + motor authority, app version.
    /// Each denied state carries the exact iOS Settings path that fixes it.
    private func diagnosticsSection(_ night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SFSectionLabel("Diagnostics")
            SFCard {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    diagnosticsRows(night)
                }
            }
        }
    }

    private func diagnosticsRows(_ night: Bool) -> some View {
        let camera = cameraDiagnostic(night)
        let location = locationDiagnostic(night)
        let gimbal = gimbalDiagnostic(night)
        let authority = authorityDiagnostic(night)
        return VStack(alignment: .leading, spacing: 12) {
            diagnosticRow(label: "Camera", value: camera.value,
                          tint: camera.tint, hint: camera.hint, night: night)
            diagnosticsDivider(night)
            diagnosticRow(label: "Location", value: location.value,
                          tint: location.tint, hint: location.hint, night: night)
            diagnosticsDivider(night)
            diagnosticRow(label: "Gimbal", value: gimbal.value,
                          tint: gimbal.tint, hint: gimbal.hint, night: night,
                          showSimulatedBadge: MountService.isSimulated)
            diagnosticsDivider(night)
            diagnosticRow(label: "Motor authority", value: authority.value,
                          tint: authority.tint, hint: authority.hint, night: night)
            diagnosticsDivider(night)
            diagnosticRow(label: "App version", value: appVersion,
                          tint: Theme.secondaryText(night), hint: nil, night: night)
        }
    }

    private func diagnosticsDivider(_ night: Bool) -> some View {
        Divider().overlay(Theme.secondaryText(night).opacity(0.2))
    }

    private func diagnosticRow(label: String, value: String, tint: Color,
                               hint: String?, night: Bool,
                               showSimulatedBadge: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    if showSimulatedBadge {
                        SimulatedSourceBadge()
                    }
                    Text(value)
                        .font(Theme.body)
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.trailing)
                }
            } label: {
                Text(label)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.primaryText(night))
            }
            if let hint {
                Text(hint)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(diagnosticAccessibilityLabel(
            label: label, value: value, hint: hint, simulated: showSimulatedBadge))
    }

    private func diagnosticAccessibilityLabel(label: String, value: String,
                                              hint: String?, simulated: Bool) -> String {
        var text = "\(label): \(value)."
        if simulated { text += " Simulated data source." }
        if let hint { text += " \(hint)" }
        return text
    }

    private func cameraDiagnostic(_ night: Bool) -> (value: String, tint: Color, hint: String?) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return ("Granted", Theme.positive(night), nil)
        case .notDetermined:
            return ("Not asked yet", Theme.secondaryText(night),
                    "iOS asks the first time a session reaches its Capture phase.")
        case .restricted:
            return ("Restricted", Theme.warning(night),
                    "Camera access is blocked by a device restriction (Screen Time or a "
                    + "management profile) — no session can capture frames until it's lifted.")
        default:
            return ("Denied", Theme.danger(night),
                    "Fix in iOS Settings → Privacy & Security → Camera → StarFlow. "
                    + "Without it, every session ends immediately with no frames.")
        }
    }

    private func locationDiagnostic(_ night: Bool) -> (value: String, tint: Color, hint: String?) {
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return ("Granted", Theme.positive(night), nil)
        case .notDetermined:
            return ("Not asked yet", Theme.secondaryText(night),
                    "The Tonight tab asks when it first plans your sky.")
        case .restricted:
            return ("Restricted", Theme.warning(night),
                    "Location is blocked by a device restriction — Tonight falls back to "
                    + "your last known position.")
        case .denied:
            return ("Denied", Theme.danger(night),
                    "Fix in iOS Settings → Privacy & Security → Location Services → StarFlow. "
                    + "Tonight's sky planning needs a rough position.")
        @unknown default:
            return ("Unknown", Theme.secondaryText(night), nil)
        }
    }

    private func gimbalDiagnostic(_ night: Bool) -> (value: String, tint: Color, hint: String?) {
        switch MountService.shared.connection {
        case .docked(let name):
            return (name, Theme.positive(night), nil)
        case .searching:
            return ("Searching…", Theme.warning(night), nil)
        case .flapping:
            return ("Reconnecting…", Theme.warning(night), nil)
        case .undocked:
            return ("Not connected", Theme.secondaryText(night),
                    "Power the Flow 2 Pro on and dock the phone — connection is automatic.")
        }
    }

    private func authorityDiagnostic(_ night: Bool) -> (value: String, tint: Color, hint: String?) {
        switch MountService.shared.authority {
        case .granted:
            return ("Granted", Theme.positive(night), nil)
        case .denied:
            return ("Not granted", Theme.warning(night),
                    "Squeeze the gimbal's front trigger once — the ring light turns solid "
                    + "when motor control is handed to StarFlow.")
        case .unknown:
            return ("Unknown until docked", Theme.secondaryText(night), nil)
        }
    }

    // MARK: - About

    private func aboutSection(_ night: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SFSectionLabel("About")
            SFCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("StarFlow")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Spacer()
                        Text(appVersion)
                            .font(Theme.liveValue(14))
                            .foregroundStyle(Theme.secondaryText(night))
                    }
                    Divider()
                        .overlay(Theme.secondaryText(night).opacity(0.2))
                    Text("Honest physics, always. iOS caps third-party exposures at 1 second, so every StarFlow image is hundreds of real subs stacked — never a fake long exposure. City glow hides faint targets and we say so up front. The gimbal can't roll-track, so long stacks are de-rotated in software. When something isn't possible tonight, StarFlow tells you before you're out in the cold.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return "\(version) (\(build))"
        }
        return version
    }

    // MARK: - Gimbal school sheet

    private func gimbalSchoolSheet(_ night: Bool) -> some View {
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
}
