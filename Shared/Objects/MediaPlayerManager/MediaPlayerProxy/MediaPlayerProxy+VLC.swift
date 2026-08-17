//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Defaults
import FactoryKit
import Foundation
import JellyfinAPI
import Logging
import SwiftUI

// [MobileVLC4 fork] Was VLCUI/MobileVLCKit 3; now drives MediaEnginePlayer,
// which owns the single VLCKit 4 engine. The class name is unchanged so the
// rest of the player — VideoPlayer.swift, the overlays, MediaPlayerManager —
// needs no edit.

class VLCMediaPlayerProxy: VideoMediaPlayerProxy,
    MediaPlayerOffsetConfigurable,
    MediaPlayerSubtitleConfigurable
{

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    let enginePlayer: MediaEnginePlayer = .init(
        subtitleStyle: Defaults[.VideoPlayer.Subtitle.configuration].asMediaEngineStyle
    )

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            subscribeToPlaybackItem(of: manager)
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    // MARK: - [MobileVLC4 fork] Starting playback is the model's job

    /// Replaced wholesale on every `manager` assignment, which drops the
    /// previous subscription — one listener per manager, never two.
    private var playbackItemCancellable: AnyCancellable?

    /// Telling the engine what to open used to be a view's responsibility — an
    /// `.onReceive` hanging off `enginePlayer.videoView`. That made playback
    /// depend on SwiftUI having built and laid out a drawing surface, and when
    /// it hadn't, the order was simply never given.
    ///
    /// Measured on 17 Aug 2026: the manager published `playbackItem` 105 ms
    /// after play was pressed (`PLAY · profile` 22:13:25.515 → `Playing new
    /// item` 22:13:25.620), and the view did not react for **92 seconds** —
    /// until the user gave up and left, whose teardown produced the one layout
    /// pass that built the view. Hence the load and the stop 45 ms apart in
    /// that trace, and hence "press Información and it plays": that gesture was
    /// only ever forcing a layout pass.
    ///
    /// `NowPlayableObserver` already listens to the same publisher this way.
    /// The proxy owns `enginePlayer`, so the proxy is where this belongs.
    ///
    /// The manager arrives as a parameter rather than being read back off
    /// `self`: isolation is not inherited by an extracted method, and the
    /// property is a main-actor-isolated protocol requirement.
    private func subscribeToPlaybackItem(of manager: MediaPlayerManager?) {
        playbackItemCancellable = manager?.$playbackItem
            .compactMap { $0 }
            .sink { playbackItem in
                // `MediaEnginePlayer` is `@MainActor`; the hop costs
                // microseconds and keeps both language modes happy.
                Task { @MainActor [weak self] in
                    self?.load(playbackItem)
                }
            }
    }

    @MainActor
    private func load(_ playbackItem: MediaPlayerItem) {
        Logger.swiftfin().notice(
            "PLAY · proxy.$playbackItem → load · \(playbackItem.baseItem.displayTitle)"
        )

        enginePlayer.load(engineConfiguration(for: playbackItem))
    }

    private func engineConfiguration(for item: MediaPlayerItem) -> MediaEngineConfiguration {
        let baseItem = item.baseItem
        let mediaSource = item.mediaSource

        var configuration = MediaEngineConfiguration(url: item.url)
        configuration.autoPlay = true

        let startSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))

        if !baseItem.isLiveStream {
            configuration.startSeconds = startSeconds

            let subtitleIndex = item.indexMap.playerIndex(for: item.selectedSubtitleStreamIndex) ?? -1
            configuration.subtitleTrackIndex = subtitleIndex < 0 ? nil : subtitleIndex

            if mediaSource.transcodingURL == nil {
                // A transcode carries one track, so only a direct play needs
                // an explicit choice.
                configuration.audioTrackIndex = item.indexMap.playerIndex(for: item.selectedAudioStreamIndex)
            }
        }

        configuration.subtitleStyle = Defaults[.VideoPlayer.Subtitle.configuration].asMediaEngineStyle
        configuration.rate = Defaults[.VideoPlayer.Playback.playbackRate]
        configuration.sidecars = item.subtitleStreams.sidecarSubtitles
            .compactMap(\.asMediaEngineSidecar)

        return configuration
    }

    func play() {
        enginePlayer.play()
    }

    func pause() {
        enginePlayer.pause()
    }

    func stop() {
        enginePlayer.stop()
    }

    func jumpForward(_ seconds: Duration) {
        enginePlayer.jumpForward(seconds, runtime: manager?.item.runtime)
    }

    func jumpBackward(_ seconds: Duration) {
        enginePlayer.jumpBackward(seconds)
    }

    func setRate(_ rate: Float) {
        enginePlayer.setRate(rate)
    }

    func setSeconds(_ seconds: Duration) {
        enginePlayer.setSeconds(seconds)
    }

    func setAudioStream(_ stream: MediaStream) {
        enginePlayer.selectAudioTrack(at: stream.index ?? -1)
    }

    func setSubtitleStream(_ stream: MediaStream) {
        // A negative index is how Jellyfin spells "no subtitles".
        let index = stream.index ?? -1
        enginePlayer.selectSubtitleTrack(at: index < 0 ? nil : index)
    }

    func setAspectFill(_ aspectFill: Bool) {
        enginePlayer.setAspectFill(aspectFill)
    }

    func setAudioOffset(_ seconds: Duration) {
        enginePlayer.setAudioOffset(seconds)
    }

    func setSubtitleOffset(_ seconds: Duration) {
        enginePlayer.setSubtitleOffset(seconds)
    }

    func setSubtitleConfiguration(_ configuration: SubtitleConfiguration) {
        enginePlayer.setSubtitleStyle(configuration.asMediaEngineStyle)
    }

    @ViewBuilder
    var videoPlayerBody: some View {
        VLCPlayerView()
            .environmentObject(enginePlayer)
    }
}

extension VLCMediaPlayerProxy {

    struct VLCPlayerView: View {

        @Default(.VideoPlayer.Subtitle.configuration)
        private var subtitleConfiguration

        @EnvironmentObject
        private var containerState: VideoPlayerContainerState
        @EnvironmentObject
        private var manager: MediaPlayerManager
        @EnvironmentObject
        private var enginePlayer: MediaEnginePlayer

        private var isScrubbing: Bool {
            containerState.isScrubbing
        }

        // MARK: [MobileVLC4 fork] Temporary instrumentation

        /// Kept out of `body` deliberately. String interpolation inside a
        /// `ViewBuilder` closure is charged to the body's type-checking budget,
        /// and two of these were enough to blow it: *"the compiler is unable to
        /// type-check this expression in reasonable time"*. Logging from a plain
        /// method costs the body nothing.
        ///
        /// Note what is *not* here: the view's size. `MediaEnginePlayer.videoView`
        /// is `some View`, the SwiftUI facade — not the `UIView` libVLC draws
        /// into, which is the backend's and stays private to it. The size that
        /// matters is the one libVLC reads, and the backend already reports it on
        /// every `engine.load` and every state change.
        ///
        /// The moment SwiftUI actually builds the drawing surface. Compare it
        /// against `PLAY · proxy.$playbackItem → load`: the gap between them is
        /// how long the picture lagged the audio, and it no longer gates
        /// playback either way.
        private func logSurfaceAppeared() {
            Logger.swiftfin().notice(
                "PLAY · surface appeared · engine \(enginePlayer.state)"
            )
        }

        /// Opening Info or Episodes shrinks the video to a strip, and for a long
        /// time that gesture was the only thing that got a stuck playback moving.
        ///
        /// Read the first two traces backwards and the reason is plain: both
        /// `engine.load`s reported `bounds 430x340`, the strip — so a supplement
        /// was already open *before* the engine ever loaded. The gesture was
        /// never resizing anything into working order; it was forcing the body
        /// to re-evaluate, which is what created the view that carried the
        /// subscription. Hence the shape above, where the subscription no longer
        /// depends on the view existing.
        ///
        /// Now that this lives outside the branch it records openings too, so a
        /// green run is one where `engine.load` arrives with no supplement line
        /// before it at all.
        private func logSupplement(_ supplement: String?) {
            Logger.swiftfin().notice(
                "PLAY · supplement \(supplement ?? "cerrado") · engine \(enginePlayer.state)"
            )
        }

        var body: some View {
            // [MobileVLC4 fork] The `if` gates the *drawing surface*, never the
            // subscription. That distinction is the whole bug this shape fixes.
            //
            // Both the load trigger and the supplement trace used to hang off
            // `enginePlayer.videoView`, i.e. inside the branch. While the guard
            // was false that view did not exist, so neither did its modifiers,
            // so nothing was listening when the manager published `playbackItem`
            // ninety milliseconds after play was pressed. The value arrived to an
            // empty room.
            //
            // What eventually opened the guard was a re-render caused by some
            // *other* dependency this view observes — `containerState` — which
            // changes when a supplement is opened. That, and not the resize, is
            // the entire mechanism behind "press Información and it plays":
            // measured at 17.6 s once and about three minutes another time,
            // both ending 0.2 s after the load finally fired.
            //
            // Subscribing from the ZStack instead means the listener exists from
            // the first render, whether or not there is anything to draw yet.
            ZStack {
                if manager.playbackItem != nil, manager.state != .stopped {
                    enginePlayer.videoView
                }
            }
            // Everything below is behaviour, not drawing, so none of it belongs
            // inside the branch. `onChange(of: enginePlayer.state)` is the second
            // casualty of the old shape: while there was no surface, nobody
            // relayed the engine's state back to the manager either.
            .onChange(of: enginePlayer.playbackInfo) { _, info in
                handle(info)
            }
            .onChange(of: enginePlayer.state) { _, state in
                handle(state)
            }
            // The load no longer lives here at all — see
            // `subscribeToPlaybackItem()` on the proxy. This only records when
            // the surface finally exists, which is the number still unexplained:
            // if it appears at t≈0 the view was fine all along and something
            // else was swallowing the publish; if it appears late, playback is
            // now already running by then and only the picture was waiting.
            .onAppear {
                logSurfaceAppeared()
            }
            .onChange(of: containerState.selectedSupplement?.id) { _, supplement in
                logSupplement(supplement)
            }
            .onChange(of: manager.rate) {
                enginePlayer.setRate(manager.rate)
            }
            .onChange(of: subtitleConfiguration) {
                enginePlayer.setSubtitleStyle(subtitleConfiguration.asMediaEngineStyle)
            }
        }

        private func handle(_ info: MediaEnginePlaybackInfo) {
            if !isScrubbing {
                containerState.scrubbedSeconds.value = info.seconds
            }

            manager.seconds = info.seconds

            if let proxy = manager.proxy as? any VideoMediaPlayerProxy {
                proxy.videoSize.value = info.videoSize
                proxy.droppedFrames.value = info.droppedFrames
                proxy.corruptedFrames.value = info.corruptedFrames
            }
        }

        private func handle(_ state: MediaEngineState) {
            manager.logger.trace("Engine state updated: \(String(describing: state))")

            switch state {
            case .opening,
                 .buffering:
                manager.proxy?.isBuffering.value = true
            case .ended:
                // Live streams report an ending they do not mean.
                guard manager.playbackItem?.baseItem.isLiveStream == false else { return }
                manager.proxy?.isBuffering.value = false
                manager.ended()
            case .stopped:
                // Ignored: MediaPlayerManager drives stopping, and reacting to
                // the echo of its own command would fight it.
                break
            case .error:
                manager.proxy?.isBuffering.value = false
                manager.error(ErrorMessage("VLC player is unable to perform playback"))
            case .playing:
                manager.proxy?.isBuffering.value = false
                manager.setPlaybackRequestStatus(status: .playing)

                let tracks = enginePlayer.playbackInfo.subtitleTracks
                    .map { (index: $0.index, title: $0.title ?? "") }
                manager.playbackItem?.getSubtitleIndexes(subtitleTracks: tracks)
            case .paused:
                manager.setPlaybackRequestStatus(status: .paused)
            }
        }
    }
}

// MARK: - Jellyfin bridging

extension SubtitleConfiguration {

    /// The engine's view of this configuration.
    var asMediaEngineStyle: MediaEngineSubtitleStyle {
        MediaEngineSubtitleStyle(
            fontName: fontName,
            color: color.uiColor,
            size: 25 - Double(size)
        )
    }
}

extension MediaStream {

    /// A sidecar subtitle resolved against the current server session.
    ///
    /// Lives here rather than on the Jellyfin model: the server's stream shape
    /// is Jellyfin's business, and turning it into something an engine can open
    /// is the adapter's.
    var asMediaEngineSidecar: MediaEngineSidecar? {
        guard let deliveryURL, let client = Container.shared.currentUserSession()?.client else { return nil }

        let deliveryPath = deliveryURL.removingFirst(if: client.configuration.url.absoluteString.last == "/")
        guard let url = client.url(path: deliveryPath) else { return nil }

        return MediaEngineSidecar(
            url: url,
            kind: .subtitle,
            isEnforced: false
        )
    }
}
