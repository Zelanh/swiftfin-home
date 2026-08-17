//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

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
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

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

        var body: some View {
            if let playbackItem = manager.playbackItem, manager.state != .stopped {
                enginePlayer.videoView
                    // [MobileVLC4 fork] There is deliberately no `.onAppear` load
                    // here, though there was one.
                    //
                    // `manager.$playbackItem` is `@Published`, and a `@Published`
                    // publisher replays its current value to every new subscriber.
                    // The `onReceive` below therefore fires the moment this view
                    // appears — so an `onAppear` load on top of it opened the
                    // medium twice, the second `player.media` assignment landing
                    // while the first was still opening, and the engine settling
                    // into a state where it never requested the stream at all.
                    //
                    // Measured, not inferred: with both in place the server logged
                    // no request for fifty-six seconds after play was pressed, and
                    // then started the moment the Info panel was opened — a
                    // re-render producing one load that nothing raced.
                    .onChange(of: enginePlayer.playbackInfo) { _, info in
                        handle(info)
                    }
                    .onChange(of: enginePlayer.state) { _, state in
                        handle(state)
                    }
                    .onReceive(manager.$playbackItem) { playbackItem in
                        guard let playbackItem else { return }

                        // [MobileVLC4 fork] Temporary. The single entry point into
                        // the engine — one of these per playback, and no more.
                        Logger.swiftfin().notice(
                            "PLAY · view.onReceive → load · \(playbackItem.baseItem.displayTitle) · " +
                                "view \(Int(enginePlayer.videoView.bounds.width))x" +
                                "\(Int(enginePlayer.videoView.bounds.height))"
                        )

                        enginePlayer.load(engineConfiguration(for: playbackItem))
                    }
                    // [MobileVLC4 fork] Temporary. Opening Info or Episodes shrinks
                    // the video to a strip, and for a long time that gesture was
                    // the only thing that got a stuck playback moving. This records
                    // what actually changes when it happens, so the coincidence can
                    // be told apart from the cause.
                    .onChange(of: containerState.selectedSupplement?.id) { _, supplement in
                        Logger.swiftfin().notice(
                            "PLAY · supplement \(supplement ?? "cerrado") · " +
                                "view \(Int(enginePlayer.videoView.bounds.width))x" +
                                "\(Int(enginePlayer.videoView.bounds.height)) · " +
                                "engine \(String(describing: enginePlayer.state))"
                        )
                    }
                    .onChange(of: manager.rate) {
                        enginePlayer.setRate(manager.rate)
                    }
                    .onChange(of: subtitleConfiguration) {
                        enginePlayer.setSubtitleStyle(subtitleConfiguration.asMediaEngineStyle)
                    }
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
