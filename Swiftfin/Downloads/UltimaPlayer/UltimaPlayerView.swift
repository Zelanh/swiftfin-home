//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import SwiftUI

/// [Downloads fork] Self-contained offline player for downloaded items.
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/UltimaPlayer/).
/// It drives the fork's own `MediaEnginePlayer` **directly** — none of the base
/// `MediaPlayerManager` / observer / session-scoped-singleton pipeline — so
/// downloaded playback is:
///
///   1. **Isolated** from the base player, and therefore unaffected by future
///      core rewrites of it (this feature can't be silently broken by an
///      upstream player refactor).
///   2. **Leak-free**: the base pipeline leaks a player instance per playback
///      (only one plays per app launch, a force-quit is needed for the next —
///      see its own `// TODO: fix leaks`). Owning a fresh `MediaEnginePlayer`
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
    /// scrubber and bounds the local resume point.
    let runtimeSeconds: Double
    /// Item id, used only as the **local** resume-position key (no server sync).
    /// `nil` disables resume.
    let itemID: String?

    // [MobileVLC4 fork] Was VLCUI's Proxy; now the fork's own engine facade.
    @StateObject
    private var player: MediaEnginePlayer = .init()

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

    // [Downloads fork] Audio / subtitle tracks read straight from VLC at runtime
    // (embedded tracks in the file), and the currently-active indexes. VLC's own
    // track indexes are what `setAudioTrack`/`setSubtitleTrack` expect, so no
    // mapping is needed.
    @State
    private var audioTracks: [Track] = []
    @State
    private var subtitleTracks: [Track] = []
    @State
    private var currentAudioIndex: Int?
    @State
    private var currentSubtitleIndex: Int?

    // [MobileVLC4 fork] Presentation options the overflow menu drives. Local
    // state rather than Defaults: these are per-playback choices, and the
    // offline player deliberately keeps no session of its own.
    @State
    private var isAspectFill = false
    @State
    private var rate: Float = 1

    // [MobileVLC4 fork] `Equatable` is load-bearing, not decoration: without it
    // `[Track]` is not comparable either, so SwiftUI cannot tell that a state
    // assignment changed nothing. The track lists are rebuilt on every time
    // update — several times a second — and that rebuilt the open menu each
    // time, which read as a faint heartbeat flicker.
    struct Track: Identifiable, Equatable {
        let index: Int
        let title: String
        var id: Int { index }
    }

    private var configuration: MediaEngineConfiguration {
        var configuration = MediaEngineConfiguration(url: url)
        configuration.autoPlay = true
        if let resume = resumeSeconds {
            configuration.startSeconds = .seconds(resume)
        }
        return configuration
    }

    /// Locally-saved resume point, if any and if sensible (not near the very
    /// start or end). `ResumeStore` reads UserDefaults, which we only write on
    /// dismiss, so this stays constant across body re-evaluations.
    private var resumeSeconds: Double? {
        guard let itemID, runtimeSeconds > 0,
              let saved = ResumeStore.seconds(for: itemID),
              saved > 5, saved < runtimeSeconds - 15
        else { return nil }
        return saved
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            player.videoView
                .onAppear {
                    player.load(configuration)
                }
                .onChange(of: player.playbackInfo) { _, info in
                    if !isScrubbing {
                        let seconds = Double(info.seconds.components.seconds)
                        // Keep within the slider's range (metadata runtime can be
                        // a touch shorter than the real file).
                        currentSeconds = runtimeSeconds > 0 ? min(seconds, runtimeSeconds) : seconds
                    }

                    // Embedded tracks, read straight from the engine. Assigned
                    // only when they actually differ: this closure runs on every
                    // time update, and a redundant write would rebuild the menu
                    // under the user's finger.
                    let newAudioTracks = info.audioTracks.map { Track(index: $0.index, title: $0.title ?? "") }
                    if newAudioTracks != audioTracks {
                        audioTracks = newAudioTracks
                    }

                    let newSubtitleTracks = info.subtitleTracks.map { Track(index: $0.index, title: $0.title ?? "") }
                    if newSubtitleTracks != subtitleTracks {
                        subtitleTracks = newSubtitleTracks
                    }

                    currentAudioIndex = info.audioTracks.first(where: \.isSelected)?.index
                    currentSubtitleIndex = info.subtitleTracks.first(where: \.isSelected)?.index
                }
                .onChange(of: player.state) { _, state in
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

            // [MobileVLC4 fork] Faded rather than removed. An open `Menu` is
            // anchored to the ellipsis inside these controls, so taking them out
            // of the hierarchy — which `if controlsVisible { }` did — made iOS
            // dismiss the menu the moment the overlay auto-hid. Swiftfin's own
            // player keeps its controls mounted for the same reason.
            controls
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: controlsVisible)
                .allowsHitTesting(controlsVisible)
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

                trackMenus
            }
            .padding()

            Spacer()

            HStack(spacing: 52) {
                Button {
                    player.jumpBackward(.seconds(10))
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
                    player.jumpForward(.seconds(10))
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

    /// Audio / subtitle pickers. Only shown when there's an actual choice: audio
    /// when the file has more than one track; subtitles when it has at least one
    /// real subtitle (VLC also lists a "Disable" entry to turn them off).
    @ViewBuilder
    // [MobileVLC4 fork] Was two separate icons for audio and subtitles; now one
    // overflow menu matching the online player, which also gives speed, aspect
    // fill and Picture in Picture somewhere to live.
    private var trackMenus: some View {
        UltimaPlayerMenu(
            player: player,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            isPictureInPictureAvailable: player.isPictureInPictureAvailable,
            currentAudioIndex: $currentAudioIndex,
            currentSubtitleIndex: $currentSubtitleIndex,
            isAspectFill: $isAspectFill,
            rate: $rate,
            onInteraction: resetAutoHide
        )
        // Without this the menu is rebuilt on every time update and fades under
        // the user's finger. `UltimaPlayerMenu` declares equality over the values
        // it displays, so SwiftUI can skip it when none of them moved.
        .equatable()
    }

    // MARK: Actions

    private func togglePlayPause() {
        // The state callback flips `isPlaying`; we drive the proxy here.
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        resetAutoHide()
    }

    private func scrub(_ editing: Bool) {
        isScrubbing = editing
        if !editing {
            player.setSeconds(.seconds(currentSeconds))
            resetAutoHide()
        }
    }

    private func toggleControls() {
        controlsVisible.toggle()

        if controlsVisible {
            scheduleAutoHide()
        } else {
            autoHideTask?.cancel()
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            // Hiding the controls no longer disturbs an open menu: they stay
            // mounted and merely fade, so the menu keeps its anchor.
            controlsVisible = false
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
        saveResume()
        player.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Persist (or clear) the local resume point for this item. Cleared when
    /// finished or barely started so we don't resume at the very end / start.
    private func saveResume() {
        guard let itemID else { return }
        if currentSeconds > 5, runtimeSeconds > 0, currentSeconds < runtimeSeconds - 15 {
            ResumeStore.set(currentSeconds, for: itemID)
        } else {
            ResumeStore.set(nil, for: itemID)
        }
    }
}

// MARK: - Local resume store

/// [Downloads fork] Local-only resume positions (seconds) keyed by item id, in
/// `UserDefaults`. No server sync — downloads are for offline use.
private enum ResumeStore {

    private static let key = "UltimaPlayerResumeSeconds"

    static func seconds(for id: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[id]
    }

    static func set(_ seconds: Double?, for id: String) {
        var store = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        if let seconds {
            store[id] = seconds
        } else {
            store.removeValue(forKey: id)
        }
        UserDefaults.standard.set(store, forKey: key)
    }
}
