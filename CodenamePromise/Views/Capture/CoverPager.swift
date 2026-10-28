import AVFoundation
import AVKit
import CodenamePromiseCore
import SwiftUI

/// The entry's cover as pages you swipe through: the chosen covers first, then the rest of
/// the entry's photos and videos, with where you are ("3 / 40") in the corner.
///
/// It used to be a still collage of up to four photos, so seeing a fifth, or watching a video,
/// meant opening the full-screen viewer. Now a photo is a swipe away, and a video plays right
/// in the cover. Tapping a photo still opens it full screen.
struct CoverPager: View {
    let items: [DraftSummary.Thumb]
    let fileStore: MediaFileStore
    /// The page showing, so the full-screen viewer opens on it and zooms back to it.
    @Binding var page: UUID?
    let open: (UUID) -> Void

    var body: some View {
        TabView(selection: Binding(
            get: { page ?? items.first?.id },
            set: { page = $0 }
        )) {
            ForEach(items, id: \.id) { item in
                Group {
                    if item.isVideo {
                        CoverVideo(item: item, fileStore: fileStore, isShowing: (page ?? items.first?.id) == item.id)
                    } else {
                        Button {
                            open(item.id)
                        } label: {
                            // Full-screen resolution, so the cover is sharp at its full width.
                            PhotoTile(thumb: item, fileStore: fileStore, maxPixel: 1600)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .tag(Optional(item.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottomLeading) {
            if items.count > 1 {
                let index = (items.firstIndex { $0.id == page } ?? 0) + 1
                Text("\(index) / \(items.count)")
                    .font(Type.label(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// A video in the cover: its first frame and a play button, then the video itself, playing
/// in place. Pauses when swiped away from or when the entry closes.
private struct CoverVideo: View {
    let item: DraftSummary.Thumb
    let fileStore: MediaFileStore
    let isShowing: Bool

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                PhotoTile(thumb: item, fileStore: fileStore, maxPixel: 1600, marksVideo: false)
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 66, height: 66)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Play video")
            }
        }
        .onChange(of: isShowing) { _, showing in
            if !showing { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }

    private func play() {
        guard fileStore.exists(item.relativePath) else { return }
        // Not while recording: switching the session to playback would cut the recording
        // off. The video plays muted instead, as it does full screen.
        if !AudioRecorder.isRecordingAnywhere {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
        let player = AVPlayer(url: fileStore.url(for: item.relativePath))
        self.player = player
        player.play()
    }
}
