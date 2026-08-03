//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import SwiftUI
import SwiftVLC

/// [experiment/swiftvlc-player] Minimal offline player built on **SwiftVLC**
/// (libVLC 4.0, native AVKit-backed PiP), the candidate third engine "UltimaFin".
///
/// This is deliberately bare — play/pause + close only. Its whole purpose in the
/// spike is to force SwiftVLC (and its static libvlc) to actually link and run
/// **alongside** MobileVLCKit (used by the VLCUI-based UltimaPlayer), i.e. the
/// dual-libVLC coexistence test. If this plays a downloaded file with both engines
/// linked, the "3 players" goal is viable and we flesh it out (scrubber, track
/// pickers, resume, PiP). If it doesn't, we bin the branch.
///
/// iOS 18+ only: SwiftVLC requires it (and `Player` is `@Observable`).
@available(iOS 18.0, *)
struct UltimaFinPlayerView: View {

    @Router
    private var router

    let url: URL
    let title: String

    @State
    private var player = Player()
    @State
    private var controlsVisible = true

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VideoView(player)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisible.toggle()
                    }
                }

            if controlsVisible {
                VStack {
                    HStack(spacing: 16) {
                        Button {
                            router.dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.title2.weight(.semibold))
                        }

                        Text(title)
                            .font(.headline)
                            .lineLimit(1)

                        Spacer()

                        // Marks this as the experimental engine while testing.
                        Text(verbatim: "SwiftVLC")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.purple, in: Capsule())
                    }
                    .padding()

                    Spacer()

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 52))
                            .frame(width: 64)
                    }

                    Spacer()
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            try? player.play(url: url)
        }
        .onDisappear {
            player.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
