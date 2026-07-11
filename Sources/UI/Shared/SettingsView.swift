import SwiftUI
import Foundation

/// Settings tab: appearance, sky quality, capture prefs, gimbal, about.
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
        guard let battery else { return "Gimbal: \(status)" }
        return "Gimbal: \(status), battery \(battery) percent"
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
