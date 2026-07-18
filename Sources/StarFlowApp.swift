import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct StarFlowApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
            RootView(hasOnboarded: $hasOnboarded)
                .preferredColorScheme(.dark)
                // Start the mount monitor at app appear — on device this opens the real
                // DockKit accessory-state stream immediately, so the gimbal ribbon,
                // Settings row, and battery telemetry are live before any session starts.
                // Idempotent: MountService.start() guards against double-starts.
                .task {
                    MountService.shared.start()
                    AutoTestRunner.shared.start()
                    Self.setKeepAwake(true)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                Self.setKeepAwake(false)
                Task { await SessionEngine.shared.handleBackgrounded() }
            } else {
                // iOS auto-lock suspends the app and kills capture + motor control;
                // a multi-hour astro session must keep the screen awake (the night
                // theme keeps the OLED cost low). Re-assert on every foregrounding.
                Self.setKeepAwake(true)
                Task { await SessionEngine.shared.handleForegrounded() }
            }
        }
    }

    private static func setKeepAwake(_ on: Bool) {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

struct RootView: View {
    @Binding var hasOnboarded: Bool
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        ZStack {
            Theme.screenBg(appearance.nightMode).ignoresSafeArea()
            if hasOnboarded {
                MainTabView()
            } else {
                OnboardingView(onComplete: { hasOnboarded = true })
            }
        }
    }
}

struct MainTabView: View {
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        TabView {
            TonightView()
                .tabItem { Label("Tonight", systemImage: "moon.stars.fill") }
            ModesGalleryView()
                .tabItem { Label("Shots", systemImage: "camera.aperture") }
            LogbookView()
                .tabItem { Label("Logbook", systemImage: "book.closed.fill") }
            LearnView()
                .tabItem { Label("Learn", systemImage: "book.fill") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent(appearance.nightMode))
    }
}
