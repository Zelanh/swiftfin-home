//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import SwiftUI
import Transmission

struct VideoPlayer: View {

    @Environment(\.presentationCoordinator)
    private var presentationCoordinator

    @InjectedObject(\.mediaPlayerManager)
    private var manager: MediaPlayerManager

    #if os(iOS)
    // [Chromecast fork] Cast session + the proxy used while it's active. See
    // `activeProxy` and the "Cast session activation" onChange below.
    @InjectedObject(\.castManager)
    private var castManager: CastManager

    /// Non-nil only while a Cast session is active.
    @State
    private var castProxy: ChromecastMediaPlayerProxy? = nil
    #endif

    @LazyState
    private var proxy: any VideoMediaPlayerProxy

    @Router
    private var router

    // TODO: move audio/subtitle offset to container state?
    @State
    private var audioOffset: Duration = .zero
    @State
    private var isBeingDismissedByTransition = false

    // TODO: move behavior to `PlaybackProgress`?
    @State
    private var scrubbingStartTime: CFTimeInterval? = nil
    @State
    private var subtitleOffset: Duration = .zero

    @StateObject
    private var containerState: VideoPlayerContainerState = .init()

    init() {
        self._proxy = .init(wrappedValue: VLCMediaPlayerProxy())
    }

    // [Chromecast fork] The proxy currently driving the on-screen body and the
    // overlay's direct seek/aspect/offset calls. Routes to the Cast proxy while
    // a session is active (so the overlay controls the TV and the body shows
    // "Casting to …"); otherwise the normal local proxy.
    private var activeProxy: any VideoMediaPlayerProxy {
        #if os(iOS)
        if let castProxy, castManager.isSessionActive {
            return castProxy
        }
        #endif
        return proxy
    }

    var body: some View {
        VideoPlayerContainerView(
            containerState: containerState,
            manager: manager
        ) {
            activeProxy.videoPlayerBody // [Chromecast fork] was `proxy`
                .eraseToAnyView()
        } playbackControls: {
            PlaybackControls()
        }
        .onAppear {
            manager.proxy = proxy
            manager.start()
        }
        .prefersStatusBarHidden(!containerState.isPresentingOverlay)
        #if os(iOS)
        // [Chromecast fork] Cast session activation: swap the manager's proxy
        // to Cast, pause local VLC, and mirror the current item onto the
        // receiver. On end, restore VLC and resume near where Cast left off.
        .onChange(of: castManager.isSessionActive) { _, isActive in
            if isActive {
                let newProxy = ChromecastMediaPlayerProxy()
                castProxy = newProxy
                manager.proxy = newProxy

                // Pause local VLC — its view is also removed from the tree.
                proxy.pause()

                if let item = manager.playbackItem {
                    castManager.load(item: item)
                }
            } else {
                castProxy = nil
                manager.proxy = proxy

                if let resumeAt = castManager.castEndedPosition {
                    Task { @MainActor in
                        // Give VLC a moment to re-enter the tree before seeking.
                        try? await Task.sleep(for: .milliseconds(800))
                        proxy.setSeconds(resumeAt)
                    }
                }
            }
        }
        #endif
        .onChange(of: audioOffset) {
            if let proxy = activeProxy as? MediaPlayerOffsetConfigurable { // [Chromecast fork] activeProxy
                proxy.setAudioOffset(audioOffset)
            }
        }
        .onChange(of: containerState.isAspectFilled) {
            UIView.animate(withDuration: 0.2) {
                activeProxy.setAspectFill(containerState.isAspectFilled) // [Chromecast fork] activeProxy
            }
        }
        .onChange(of: containerState.isScrubbing) {
            if containerState.isScrubbing {
                scrubbingStartTime = CACurrentMediaTime()
            }

            guard let scrubbingStartTime else { return }
            let scrubbingDelta = CACurrentMediaTime() - scrubbingStartTime
            let secondsDelta = abs(manager.seconds - containerState.scrubbedSeconds.value)

            guard secondsDelta >= .seconds(1), scrubbingDelta >= 0.1 else { return }

            let scrubbedSeconds = containerState.scrubbedSeconds.value
            manager.seconds = scrubbedSeconds
            activeProxy.setSeconds(scrubbedSeconds) // [Chromecast fork] activeProxy
        }
        .onChange(of: subtitleOffset) {
            if let proxy = activeProxy as? MediaPlayerOffsetConfigurable { // [Chromecast fork] activeProxy
                proxy.setSubtitleOffset(subtitleOffset)
            }
        }
        .preference(
            key: PresentationControllerShouldDismissPreferenceKey.self,
            value: containerState.presentationControllerShouldDismiss
        )
        .onChange(of: presentationCoordinator.isPresented) {
            guard !presentationCoordinator.isPresented else { return }
            isBeingDismissedByTransition = true

            #if os(iOS)
            // [Chromecast fork] End the Cast session when the player is dismissed.
            if castManager.isSessionActive {
                castManager.endSession()
            }
            #endif

            manager.stop()
        }
        .onReceive(manager.$playbackItem) { newItem in
            containerState.isAspectFilled = false
            audioOffset = .zero
            subtitleOffset = .zero

            // TODO: move to container view
            containerState.scrubbedSeconds.value = newItem?.baseItem.startSeconds ?? .zero

            #if os(iOS)
            // [Chromecast fork] If Cast is active when the next queue item
            // starts, load it on the receiver too.
            if castManager.isSessionActive, let item = newItem {
                castManager.load(item: item)
            }
            #endif
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
