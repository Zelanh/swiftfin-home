//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import SwiftUI
import UIKit

// [MobileVLC4 fork]

/// What the rest of Swiftfin holds when it wants to play video.
///
/// An `ObservableObject` over a ``MediaEngineSession``, so SwiftUI views can
/// observe playback instead of wiring closures by hand, plus the surface the
/// old VLCUI proxy offered — the same verbs, without VLCUI's types.
///
/// This is the only type playback code needs. ``VLCKitBackend`` stays private
/// behind it, which is what keeps `import VLCKit` inside `Backend/`.
@MainActor
final class MediaEnginePlayer: ObservableObject {

    /// Current playback state, including the synthesised
    /// ``MediaEngineState/ended`` that advances a series.
    @Published
    private(set) var state: MediaEngineState = .opening

    /// Latest snapshot: position, video size, dropped frames, track lists.
    @Published
    private(set) var playbackInfo: MediaEnginePlaybackInfo = .empty

    /// Whether Picture in Picture can be started right now.
    ///
    /// VLCKit only offers a controller once video output is running, so this
    /// stays false until playback has actually begun — which is the honest
    /// signal for whether to show the button.
    @Published
    private(set) var isPictureInPictureAvailable = false

    /// Whether playback is currently in the floating PiP window.
    @Published
    private(set) var isPictureInPictureActive = false

    private let backend: VLCKitBackend

    init(subtitleStyle: MediaEngineSubtitleStyle? = nil) {
        backend = VLCKitBackend(subtitleStyle: subtitleStyle)

        backend.onStateChange = { [weak self] newState in
            self?.state = newState
        }

        backend.onTimeChange = { [weak self] info in
            self?.playbackInfo = info
        }

        backend.onPictureInPictureAvailable = { [weak self] in
            self?.isPictureInPictureAvailable = true
        }

        backend.onPictureInPictureChange = { [weak self] isActive in
            self?.isPictureInPictureActive = isActive
        }
    }

    // MARK: Video surface

    /// The view libVLC renders into. Place it behind Swiftfin's own controls.
    var videoView: some View {
        MediaEngineVideoView(backend: backend)
    }

    // MARK: Picture in Picture

    func startPictureInPicture() {
        backend.startPictureInPicture()
    }

    // MARK: Playback

    func load(_ configuration: MediaEngineConfiguration) {
        backend.load(configuration)
    }

    func play() {
        backend.play()
    }

    func pause() {
        backend.pause()
    }

    func stop() {
        backend.stop()
    }

    func setSeconds(_ seconds: Duration) {
        backend.setSeconds(seconds)
    }

    /// Skip forward, never past the end when a runtime is known.
    func jumpForward(_ seconds: Duration, runtime: Duration? = nil) {
        let target = playbackInfo.seconds + seconds

        guard let runtime else {
            backend.setSeconds(target)
            return
        }

        backend.setSeconds(min(target, runtime))
    }

    func jumpBackward(_ seconds: Duration) {
        backend.setSeconds(max(.zero, playbackInfo.seconds - seconds))
    }

    func setRate(_ rate: Float) {
        backend.setRate(rate)
    }

    // MARK: Tracks

    func selectAudioTrack(at index: Int) {
        backend.selectAudioTrack(at: index)
    }

    func selectSubtitleTrack(at index: Int?) {
        backend.selectSubtitleTrack(at: index)
    }

    // MARK: Presentation

    func setAudioOffset(_ offset: Duration) {
        backend.setAudioOffset(offset)
    }

    func setSubtitleOffset(_ offset: Duration) {
        backend.setSubtitleOffset(offset)
    }

    func setSubtitleStyle(_ style: MediaEngineSubtitleStyle) {
        backend.setSubtitleStyle(style)
    }

    func setAspectFill(_ isAspectFill: Bool) {
        backend.setAspectFill(isAspectFill)
    }
}

// MARK: - Video surface

/// Hosts the plain `UIView` libVLC draws into.
///
/// Deliberately empty of logic: on iOS and tvOS the engine renders into a bare
/// view, so this is a surface and nothing more. It names no VLCKit type.
private struct MediaEngineVideoView: UIViewRepresentable {

    let backend: VLCKitBackend

    // The view belongs to the engine's drawable rather than being made here:
    // VLCKit needs a PiP-capable drawable that outlives any one SwiftUI pass.
    func makeUIView(context: Context) -> UIView {
        backend.videoView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
