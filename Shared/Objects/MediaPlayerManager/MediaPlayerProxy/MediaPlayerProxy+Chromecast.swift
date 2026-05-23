//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Factory
import GoogleCast
import JellyfinAPI
import SwiftUI

@MainActor
class ChromecastMediaPlayerProxy: VideoMediaPlayerProxy {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    let videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

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

    @Injected(\.castManager)
    private var castManager: CastManager

    private var cancellables: Set<AnyCancellable> = []

    init() {
        setupObservers()
    }

    private func setupObservers() {
        castManager.$castPlayerState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .buffering, .loading:
                    self.isBuffering.value = true
                case .playing:
                    self.isBuffering.value = false
                    self.manager?.setPlaybackRequestStatus(status: .playing)
                case .paused, .idle:
                    self.isBuffering.value = false
                    self.manager?.setPlaybackRequestStatus(status: .paused)
                default:
                    break
                }
            }
            .store(in: &cancellables)

        castManager.$currentCastPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] position in
                self?.manager?.seconds = .seconds(position)
            }
            .store(in: &cancellables)
    }

    // MARK: - MediaPlayerProxy

    func play() {
        castManager.play()
    }

    func pause() {
        castManager.pause()
    }

    func stop() {
        // Pause Cast without ending the session — session lifecycle is owned by CastManager.
        castManager.pause()
    }

    func jumpForward(_ seconds: Duration) {
        castManager.seek(by: seconds.seconds)
    }

    func jumpBackward(_ seconds: Duration) {
        castManager.seek(by: -seconds.seconds)
    }

    func setRate(_ rate: Float) {
        castManager.setPlaybackRate(rate)
    }

    func setSeconds(_ seconds: Duration) {
        castManager.seekTo(seconds.seconds)
    }

    // MARK: - VideoMediaPlayerProxy

    func setAudioStream(_ stream: MediaStream) {
        // TODO: reload media with updated audioStreamIndex in customData
    }

    func setSubtitleStream(_ stream: MediaStream) {
        // TODO: reload media with updated subtitleStreamIndex in customData
    }

    func setAspectFill(_ aspectFill: Bool) {}

    @ViewBuilder
    var videoPlayerBody: some View {
        CastingView()
    }
}

// MARK: - CastingView

/// Full-screen view shown on the iOS device while video plays on a Cast receiver.
private struct CastingView: View {

    @Injected(\.castManager)
    private var castManager: CastManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "tv.and.mediabox")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse)

                VStack(spacing: 6) {
                    Text(L10n.casting)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)

                    if let deviceName = castManager.connectedDeviceName {
                        Text(deviceName)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
    }
}
