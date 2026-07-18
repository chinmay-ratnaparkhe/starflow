import SwiftUI
import AVKit

/// Minimal AVPlayer sheet for timelapse clips (landing report + Logbook detail).
/// The clip is the deliverable, so playback is shown as-shot — deliberately NOT
/// red-tinted in night mode; the chrome around it stays theme-aware.
struct VideoPlayerSheet: View {
    let url: URL
    let title: String

    @ObservedObject private var appearance = Appearance.shared
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()

    init(url: URL, title: String = "Timelapse") {
        self.url = url
        self.title = title
    }

    var body: some View {
        let night = appearance.nightMode
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VideoPlayer(player: player)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.accent(night))
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.play()
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}
