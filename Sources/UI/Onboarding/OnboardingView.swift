import SwiftUI
import Foundation
import AVFoundation
import CoreLocation

/// First-run intro pager. Contract: OnboardingView(onComplete: @escaping () -> Void).
/// Five pages: welcome → how it works → gimbal school → permissions → sky quality.
struct OnboardingView: View {
    let onComplete: () -> Void

    @ObservedObject private var appearance = Appearance.shared
    @StateObject private var permissions = OnboardingPermissions()
    @AppStorage("skyQuality") private var skyQualityRaw: Int = SkyQuality.suburb.rawValue
    @State private var page = 0

    private let lastPage = 4

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    var body: some View {
        let night = appearance.nightMode
        ZStack {
            OnboardingStarfield(night: night)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if page < lastPage {
                        Button("Skip") {
                            withAnimation(.easeInOut) { page = lastPage }
                        }
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                    }
                }
                .frame(height: 36)

                TabView(selection: $page) {
                    WelcomePage(night: night).tag(0)
                    HowItWorksPage(night: night).tag(1)
                    GimbalSchoolPage(night: night).tag(2)
                    PermissionsPage(night: night, model: permissions).tag(3)
                    SkyQualityPage(night: night, selectedRaw: $skyQualityRaw).tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                pageDots(night: night)
                    .padding(.top, 6)

                Button {
                    if page < lastPage {
                        withAnimation(.easeInOut) { page += 1 }
                    } else {
                        onComplete()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(page < lastPage ? "Continue" : "Under the stars")
                        if page == lastPage {
                            Image(systemName: "sparkles")
                        }
                    }
                    .font(Theme.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .foregroundStyle(night ? Theme.nightRed : Color(red: 0.06, green: 0.05, blue: 0.02))
                .background(
                    Capsule()
                        .fill(night ? Color.black : Theme.gold)
                        .overlay(Capsule().strokeBorder(
                            Theme.accent(night).opacity(night ? 0.7 : 0), lineWidth: 1))
                )
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: page)
    }

    private func pageDots(night: Bool) -> some View {
        HStack(spacing: 7) {
            ForEach(0...lastPage, id: \.self) { i in
                Capsule()
                    .fill(i == page ? Theme.accent(night) : Theme.secondaryText(night).opacity(0.35))
                    .frame(width: i == page ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.35), value: page)
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    let night: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Theme.accent(night))
                    .padding(.top, 8)
                Text("Your gimbal is a star tracker now.")
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                Text("The Insta360 Flow 2 Pro was built to film people. Tonight it points at the sky instead — StarFlow drives its motors to hold a patch of stars steady while your iPhone quietly collects light.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    conceptRow(symbol: "scope", title: "Aims",
                               text: "Finds tonight's best targets and centers them for you.")
                    conceptRow(symbol: "gyroscope", title: "Holds",
                               text: "Nudges the frame against Earth's spin every couple of minutes.")
                    conceptRow(symbol: "square.stack.3d.up", title: "Stacks",
                               text: "Turns hundreds of 1-second frames into one deep image.")
                }
                Text("No telescope. No equatorial mount. A phone, a gimbal, and honest math.")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryText(night))
            }
            .padding(24)
        }
    }

    private func conceptRow(symbol: String, title: String, text: String) -> some View {
        SFCard {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent(night))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(text)
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                }
            }
        }
    }
}

// MARK: - Page 2: How it works

private struct HowItWorksPage: View {
    let night: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("One second at a time.")
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                    .padding(.top, 8)
                Text("iOS caps third-party cameras at a 1-second exposure. StarFlow doesn't fight the cap — it stacks past it.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) {
                    stepRow(number: 1, symbol: "camera.aperture", title: "Shoot",
                            text: "Hundreds of 1-second RAW frames, back to back — the sensor barely rests.")
                    stepRow(number: 2, symbol: "wand.and.stars", title: "Align",
                            text: "Every frame is star-matched, then shifted and de-rotated onto the first.")
                    stepRow(number: 3, symbol: "sum", title: "Stack",
                            text: "Signal adds up; random noise averages away. 300 subs behaves like a 5-minute exposure.")
                }
                SFCard(accent: Theme.warning(night)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The honest part")
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Text("Stacking can't beat physics. City glow still drowns faint nebulae, and a single 1-second sub won't freeze a meteor that lands between frames. StarFlow tells you what a shot will really look like before you commit to the cold.")
                            .font(Theme.body)
                            .foregroundStyle(Theme.secondaryText(night))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
        }
    }

    private func stepRow(number: Int, symbol: String, title: String, text: String) -> some View {
        SFCard {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(Theme.liveValue(14))
                    .foregroundStyle(Color.black)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.accent(night)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title)
                            .font(Theme.headline)
                            .foregroundStyle(Theme.primaryText(night))
                        Spacer()
                        Image(systemName: symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent(night))
                    }
                    Text(text)
                        .font(Theme.body)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Page 3: Gimbal school

private struct GimbalSchoolPage: View {
    let night: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Gimbal school.")
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                    .padding(.top, 8)
                Text("Ninety seconds of setup saves a ruined stack. Step three is the one everyone forgets.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                GimbalSchoolView()
            }
            .padding(24)
        }
    }
}

/// The gimbal-setup lesson. Internal on purpose: SettingsView re-presents it in a sheet.
struct GimbalSchoolView: View {
    @ObservedObject private var appearance = Appearance.shared

    private let steps: [TutorialStep] = [
        TutorialStep(id: 1, title: "Mount the phone",
                     body: "Clip the iPhone into the magnetic clamp, camera pointing away from the handle. Let it balance before powering on.",
                     symbol: "iphone.gen3"),
        TutorialStep(id: 2, title: "Power on & dock",
                     body: "Hold the power button until the ring light breathes. StarFlow finds the gimbal automatically once it's awake.",
                     symbol: "power"),
        TutorialStep(id: 3, title: "The trigger — one squeeze",
                     body: "Out of the box the motors ignore apps. Squeeze the front trigger once: the ring light goes solid and the gimbal hands StarFlow the controls. If it ever re-docks mid-session, authority comes back on its own.",
                     symbol: "hand.tap.fill"),
        TutorialStep(id: 4, title: "Free Tilt collar: OFF",
                     body: "Lock the Free Tilt collar. Left loose, the phone sags mid-exposure and every single sub smears.",
                     symbol: "lock.fill"),
    ]

    var body: some View {
        let night = appearance.nightMode
        VStack(spacing: 10) {
            ForEach(steps) { step in
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
    }
}

// MARK: - Page 4: Permissions

private struct PermissionsPage: View {
    let night: Bool
    @ObservedObject var model: OnboardingPermissions
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Two permissions, both boring.")
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                    .padding(.top, 8)
                Text("Camera to capture. Location to compute your sky — darkness windows, moonrise, where the core climbs. Nothing leaves your phone.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                    .fixedSize(horizontal: false, vertical: true)

                permissionCard(symbol: "camera.fill", title: "Camera",
                               state: cameraState) { model.requestCamera() }
                permissionCard(symbol: "location.fill", title: "Location",
                               state: locationState) { model.requestLocation() }
            }
            .padding(24)
        }
    }

    private enum PermState {
        case notAsked, granted, denied
        var statusText: String {
            switch self {
            case .notAsked: return "Not asked yet"
            case .granted: return "Granted"
            case .denied: return "Denied — open Settings"
            }
        }
    }

    private var cameraState: PermState {
        switch model.camera {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }

    private var locationState: PermState {
        switch model.location {
        case .authorizedWhenInUse, .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        default: return .notAsked
        }
    }

    private func permissionCard(symbol: String, title: String, state: PermState,
                                request: @escaping () -> Void) -> some View {
        SFCard {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent(night))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(state.statusText)
                        .font(Theme.caption)
                        .foregroundStyle(state == .granted
                                         ? Theme.positive(night)
                                         : Theme.secondaryText(night))
                }
                Spacer()
                switch state {
                case .granted:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.positive(night))
                case .notAsked:
                    Button("Allow", action: request)
                        .font(Theme.headline)
                        .foregroundStyle(night ? Theme.nightRed : Color.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(night ? Theme.nightRedDim.opacity(0.5) : Theme.gold))
                case .denied:
                    Button("Settings") {
                        if let url = URL(string: "app-settings:") { openURL(url) }
                    }
                    .font(Theme.headline)
                    .foregroundStyle(Theme.accent(night))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().strokeBorder(Theme.accent(night).opacity(0.5), lineWidth: 1))
                }
            }
        }
    }
}

/// Camera + location permission state for the onboarding page.
@MainActor
private final class OnboardingPermissions: NSObject, ObservableObject {
    @Published var camera: AVAuthorizationStatus
    @Published var location: CLAuthorizationStatus

    private let manager: CLLocationManager

    override init() {
        let m = CLLocationManager()
        manager = m
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        location = m.authorizationStatus
        super.init()
        m.delegate = self
    }

    func requestCamera() {
        #if targetEnvironment(simulator)
        camera = .authorized
        #else
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor [weak self] in
                self?.camera = granted ? .authorized : .denied
            }
        }
        #endif
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
    }
}

extension OnboardingPermissions: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.location = status
        }
    }
}

// MARK: - Page 5: Sky quality

private struct SkyQualityPage: View {
    let night: Bool
    @Binding var selectedRaw: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("How dark is your sky?")
                    .font(Theme.title)
                    .foregroundStyle(Theme.primaryText(night))
                    .padding(.top, 8)
                Text("Feasibility verdicts are only as honest as this answer. Change it any time in Settings.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondaryText(night))
                VStack(spacing: 10) {
                    ForEach(SkyQuality.allCases, id: \.rawValue) { quality in
                        qualityCard(quality)
                    }
                }
            }
            .padding(24)
        }
    }

    private func qualityCard(_ quality: SkyQuality) -> some View {
        let selected = selectedRaw == quality.rawValue
        return Button {
            selectedRaw = quality.rawValue
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(quality.label)
                        .font(Theme.headline)
                        .foregroundStyle(Theme.primaryText(night))
                    Text(blurb(quality))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.secondaryText(night))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected
                                     ? Theme.accent(night)
                                     : Theme.secondaryText(night).opacity(0.4))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.cardBg(night))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.accent(night).opacity(selected ? 0.8 : 0.12),
                                          lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func blurb(_ quality: SkyQuality) -> String {
        switch quality {
        case .city:
            return "Moon, planets and bright star trails. The Milky Way isn't coming — we'll always be straight with you."
        case .suburb:
            return "Bright constellations, trails, lunar detail. The core shows faintly on the best nights."
        case .rural:
            return "Milky Way core in season, meteor showers, honest deep stacks."
        case .dark:
            return "Everything on the menu. Bring layers and a power bank."
        }
    }
}

// MARK: - Starfield backdrop

private struct OnboardingStarfield: View {
    let night: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: night
                    ? [Color.black, Color.black]
                    : [Color(red: 0.02, green: 0.03, blue: 0.07),
                       Theme.bg,
                       Color(red: 0.05, green: 0.07, blue: 0.14)],
                startPoint: .top, endPoint: .bottom)
            Canvas { context, size in
                var rng = OnboardingSeededRandom(seed: 7)
                for _ in 0..<130 {
                    let x = rng.next() * size.width
                    let y = rng.next() * size.height
                    let r = 0.4 + rng.next() * 1.1
                    let alpha = 0.15 + rng.next() * 0.55
                    let color = (night ? Theme.nightRed : Color.white).opacity(alpha)
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(color))
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

private struct OnboardingSeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
