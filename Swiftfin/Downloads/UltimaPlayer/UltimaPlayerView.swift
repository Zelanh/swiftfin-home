//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import SwiftUI
import VLCUI

/// [Downloads fork] Self-contained offline player for downloaded items.
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/UltimaPlayer/).
/// It drives VLCUI's `VLCVideoPlayer` **directly** — none of the base
/// `MediaPlayerManager` / observer / session-scoped-singleton pipeline — so
/// downloaded playback is:
///
///   1. **Isolated** from the base player, and therefore unaffected by future
///      core rewrites of it (this feature can't be silently broken by an
///      upstream player refactor).
///   2. **Leak-free**: the base pipeline leaks a player instance per playback
///      (only one plays per app launch, a force-quit is needed for the next —
///      see its own `// TODO: fix leaks`). Owning a fresh `VLCVideoPlayer.Proxy`
///      per presentation and tearing it down on disappear avoids that entirely.
///   3. **Network-free**: no playback reports, no server negotiation — it just
///      opens the local file. No sidecar subtitle "children" pointing at the
///      server either, so none of the offline all-black hangs.
///
/// It takes only `Sendable` primitives (a local `URL` + display strings), never a
/// `DownloadTask`, so there's nothing to reach back into.
struct UltimaPlayerView: View {

    @Router
    private var router

    /// Local media file (`DownloadTask.getMediaURL()`).
    let url: URL
    /// Display title for the top bar.
    let title: String
    /// Total runtime in seconds (from `Item.json`), `0` if unknown — drives the
    /// scrubber. We never seek the player to a resume point on open, so a stale
    /// server watch-position can't strand playback at the end offline.
    let runtimeSeconds: Double

    @StateObject
    private var proxy: VLCVideoPlayer.Proxy = .init()

    @State
    private var currentSeconds: Double = 0
    @State
    private var isPlaying = true
    @State
    private var controlsVisible = true
    @State
    private var isScrubbing = false
    @State
    private var hasError = false
    @State
    private var autoHideTask: Task<Void, Never>?

    private var configuration: VLCVideoPlayer.Configuration {
        var configuration = VLCVideoPlayer.Configuration(url: url)
        configuration.autoPlay = true
        return configuration
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VLCVideoPlayer(configuration: configuration)
                .proxy(proxy)
                .onSecondsUpdated { newSeconds, _ in
                    guard !isScrubbing else { return }
                    let seconds = Double(newSeconds.components.seconds)
                    // Keep within the slider's range (metadata runtime can be a
                    // touch shorter than the real file).
                    currentSeconds = runtimeSeconds > 0 ? min(seconds, runtimeSeconds) : seconds
                }
                .onStateUpdated { state, _ in
                    switch state {
                    case .playing:
                        isPlaying = true
                    case .paused:
                        isPlaying = false
                    case .ended:
                        router.dismiss()
                    case .error:
                        hasError = true
                    default:
                        break
                    }
                }
                .ignoresSafeArea()

            // Tap anywhere (behind the controls) to toggle the overlay.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleControls)

            if controlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: activate)
        .onDisappear(perform: deactivate)
        .alert(L10n.error, isPresented: $hasError) {
            Button(L10n.dismiss) { router.dismiss() }
        } message: {
            Text(L10n.unableToLoadThisItem)
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 0) {
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
            }
            .padding()

            Spacer()

            HStack(spacing: 52) {
                Button {
                    proxy.jumpBackward(.seconds(10))
                    resetAutoHide()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 34))
                }

                Button(action: togglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 52))
                        .frame(width: 64)
                }

                Button {
                    proxy.jumpForward(.seconds(10))
                    resetAutoHide()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 34))
                }
            }

            Spacer()

            if runtimeSeconds > 0 {
                HStack(spacing: 12) {
                    Text(Duration.seconds(currentSeconds), format: .runtime)
                        .monospacedDigit()

                    Slider(
                        value: $currentSeconds,
                        in: 0 ... runtimeSeconds,
                        onEditingChanged: scrub
                    )

                    Text(Duration.seconds(runtimeSeconds), format: .runtime)
                        .monospacedDigit()
                }
                .font(.caption)
                .padding()
            }
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.55), .clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        )
    }

    // MARK: Actions

    private func togglePlayPause() {
        // The state callback flips `isPlaying`; we drive the proxy here.
        if isPlaying {
            proxy.pause()
        } else {
            proxy.play()
        }
        resetAutoHide()
    }

    private func scrub(_ editing: Bool) {
        isScrubbing = editing
        if !editing {
            proxy.setSeconds(.seconds(currentSeconds))
            resetAutoHide()
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
        if controlsVisible {
            scheduleAutoHide()
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }

    private func resetAutoHide() {
        guard controlsVisible else { return }
        scheduleAutoHide()
    }

    // MARK: Lifecycle

    private func activate() {
        // Play through the silent switch, like any video player.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        scheduleAutoHide()
    }

    private func deactivate() {
        autoHideTask?.cancel()
        proxy.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
