//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import SwiftUI
import Transmission

struct VideoPlayer: View {

    @Environment(\.presentationCoordinator)
    private var presentationCoordinator

    @InjectedObject(\.mediaPlayerManager)
    private var manager: MediaPlayerManager

    @InjectedObject(\.castManager)
    private var castManager: CastManager

    @LazyState
    private var vlcProxy: VLCMediaPlayerProxy

    /// Non-nil only while a Cast session is active.
    @State
    private var castProxy: ChromecastMediaPlayerProxy? = nil

    @Router
    private var router

    // TODO: move audio/subtitle offset to container state?
    @State
    private var audioOffset: Duration = .zero
    @State
    private var isBeingDismissedByTransition = false

    // TODO: move behavior to `PlaybackProgress`
    @State
    private var scrubbingStartDate: Date? = nil
    @State
    private var subtitleOffset: Duration = .zero

    @StateObject
    private var containerState: VideoPlayerContainerState = .init()

    init() {
        self._vlcProxy = .init(wrappedValue: VLCMediaPlayerProxy())
    }

    // MARK: - Active proxy

    private var activeProxy: any VideoMediaPlayerProxy {
        if let castProxy, castManager.isSessionActive {
            return castProxy
        }
        return vlcProxy
    }

    // MARK: - Views

    @ViewBuilder
    private var containerView: some View {
        VideoPlayerContainerView(
            containerState: containerState,
            manager: manager
        ) {
            activeProxy.videoPlayerBody
                .eraseToAnyView()
        } playbackControls: {
            PlaybackControls()
        }
        .onAppear {
            manager.proxy = vlcProxy
            manager.start()
        }
    }

    var body: some View {
        containerView
            .prefersStatusBarHidden(!containerState.isPresentingOverlay)
            // MARK: Cast session activation
            .backport
            .onChange(of: castManager.isSessionActive) { _, isActive in
                if isActive {
                    let newProxy = ChromecastMediaPlayerProxy()
                    castProxy = newProxy
                    manager.proxy = newProxy

                    // Pause local VLC — its view will also be removed from the tree
                    vlcProxy.pause()

                    if let item = manager.playbackItem {
                        castManager.load(item: item)
                    }
                } else {
                    // Restore VLC and attempt to resume near where Cast left off
                    castProxy = nil
                    manager.proxy = vlcProxy

                    if let resumeAt = castManager.castEndedPosition {
                        Task { @MainActor in
                            // Give VLC a moment to re-enter the view tree before seeking.
                            try? await Task.sleep(for: .milliseconds(800))
                            vlcProxy.setSeconds(resumeAt)
                        }
                    }
                }
            }
            // MARK: Existing audio / subtitle offset
            .backport
            .onChange(of: audioOffset) { _, newValue in
                if let proxy = activeProxy as? MediaPlayerOffsetConfigurable {
                    proxy.setAudioOffset(newValue)
                }
            }
            .backport
            .onChange(of: containerState.isAspectFilled) { _, newValue in
                UIView.animate(withDuration: 0.2) {
                    activeProxy.setAspectFill(newValue)
                }
            }
            .backport
            .onChange(of: containerState.isScrubbing) { _, newValue in
                if newValue { scrubbingStartDate = .now }

                guard let scrubbingStartDate else { return }
                let scrubbingDelta = Date.now.timeIntervalSince(scrubbingStartDate)
                let secondsDelta = abs(manager.seconds - containerState.scrubbedSeconds.value)

                guard secondsDelta >= .seconds(1), scrubbingDelta >= 0.1 else { return }

                let scrubbedSeconds = containerState.scrubbedSeconds.value
                manager.seconds = scrubbedSeconds
                activeProxy.setSeconds(scrubbedSeconds)
            }
            .backport
            .onChange(of: subtitleOffset) { _, newValue in
                if let proxy = activeProxy as? MediaPlayerOffsetConfigurable {
                    proxy.setSubtitleOffset(newValue)
                }
            }
            .preference(
                key: PresentationControllerShouldDismissPreferenceKey.self,
                value: containerState.presentationControllerShouldDismiss
            )
            .backport
            .onChange(of: presentationCoordinator.isPresented) { _, isPresented in
                guard !isPresented else { return }
                isBeingDismissedByTransition = true

                // End the Cast session when the player is dismissed.
                if castManager.isSessionActive {
                    castManager.endSession()
                }

                manager.stop()
            }
            .onReceive(manager.$playbackItem) { newItem in
                containerState.isAspectFilled = false
                audioOffset = .zero
                subtitleOffset = .zero

                // TODO: move to container view
                containerState.scrubbedSeconds.value = newItem?.baseItem.startSeconds ?? .zero

                // If Cast is active when the next queue item starts, load it on Cast too.
                if castManager.isSessionActive, let item = newItem {
                    castManager.load(item: item)
                }
            }
            .onReceive(manager.$state) { newState in
                if newState == .stopped, !isBeingDismissedByTransition {
                    router.dismiss()
                }
            }
            .alert(
                L10n.error,
                isPresented: .constant(manager.error != nil)
            ) {
                Button(L10n.close, role: .cancel) {
                    Container.shared.mediaPlayerManager.reset()
                    router.dismiss()
                }
            } message: {
                Text(L10n.unableToLoadThisItem)
            }
    }
}
