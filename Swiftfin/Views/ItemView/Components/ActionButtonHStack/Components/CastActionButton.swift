//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import GoogleCast
import JellyfinAPI
import SwiftUI

extension ItemView {

    /// Cast affordance shown on the item-detail page, alongside Played /
    /// Favorite / Version / Trailer. Lets the user cast **without playing
    /// locally first**, which avoids the wasted second transcode the
    /// in-player Cast flow incurs (local playback fires one transcode, then
    /// casting fires another).
    ///
    /// Flow: tap → quality picker sheet → native device dialog → once a Cast
    /// session starts, hand the item to `CastManager.castFromDetail`. Playback
    /// is then driven by the native Cast controls (the in-app player is never
    /// opened — this is the deliberate "Option A" design).
    ///
    /// Always mounted (even when no Cast device is around) so its discovery
    /// kick runs and the button can appear without the user having to open
    /// Google Home first — matching the in-player `CastButtonView` behaviour.
    /// When no device is available it collapses to zero size.
    struct CastActionButton: View {

        @InjectedObject(\.castManager)
        private var castManager: CastManager

        @ObservedObject
        var viewModel: ItemViewModel

        @Environment(\.scenePhase)
        private var scenePhase

        @State
        private var showingQualityPicker = false

        /// Latched at picker-confirm time, read from `.sheet(onDismiss:)` so
        /// the native cast dialog is presented after the sheet has fully
        /// animated out (same robustness trick as `CastButtonView`).
        @State
        private var shouldPresentCastDialogAfterDismiss = false

        /// Set when the user confirms a cast from this page; read on the next
        /// `isSessionActive` transition so we only cast in response to *our*
        /// device-dialog interaction, not to some unrelated session start.
        @State
        private var awaitingSessionForCast = false

        // MARK: - Derived

        private var castTarget: (baseItem: BaseItemDto, mediaSource: MediaSourceInfo)? {
            guard let baseItem = viewModel.playButtonItem,
                  let mediaSource = viewModel.selectedMediaSource
            else { return nil }
            return (baseItem, mediaSource)
        }

        private var audioStreams: [MediaStream] {
            viewModel.selectedMediaSource?.mediaStreams?.filter { $0.type == .audio } ?? []
        }

        private var isVisible: Bool {
            (castManager.hasAvailableDevices || castManager.isSessionActive) && castTarget != nil
        }

        // MARK: - Body

        var body: some View {
            content
                .onAppear(perform: refreshDiscovery)
                .onDisappear {
                    // Drop any un-consumed cast intent if the user navigates
                    // away after confirming but before a session started
                    // (e.g. they cancelled the device dialog). Prevents a
                    // stale intent from later casting the wrong item.
                    awaitingSessionForCast = false
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active { refreshDiscovery() }
                }
                .onChange(of: castManager.isSessionActive) { isActive in
                    guard isActive, awaitingSessionForCast else { return }
                    awaitingSessionForCast = false
                    if let target = castTarget {
                        castManager.castFromDetail(
                            baseItem: target.baseItem,
                            mediaSource: target.mediaSource
                        )
                    }
                }
                .sheet(isPresented: $showingQualityPicker, onDismiss: presentCastDialogIfConfirmed) {
                    CastQualityPickerView(
                        audioStreams: audioStreams,
                        initialAudioStreamIndex: viewModel.selectedMediaSource?.defaultAudioStreamIndex,
                        onConfirm: { bitrate, audioIndex in
                            castManager.pendingBitrate = bitrate
                            castManager.pendingAudioStreamIndex = audioIndex
                            shouldPresentCastDialogAfterDismiss = true
                            awaitingSessionForCast = true
                            showingQualityPicker = false
                        },
                        onCancel: {
                            showingQualityPicker = false
                        }
                    )
                }
        }

        @ViewBuilder
        private var content: some View {
            if isVisible {
                Button("Cast", systemImage: castManager.isSessionActive ? "tv.fill" : "tv") {
                    handleTap()
                }
                .frame(maxWidth: .infinity)
            } else {
                // Zero-size placeholder keeps this view mounted (so discovery
                // and session observation keep running) without taking a slot
                // in the action row when no Cast device is available.
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }

        // MARK: - Actions

        private func handleTap() {
            if castManager.isSessionActive {
                // Already casting — open the native dialog (stop / switch).
                _ = GCKCastContext.sharedInstance().presentCastDialog()
            } else {
                showingQualityPicker = true
            }
        }

        private func presentCastDialogIfConfirmed() {
            guard shouldPresentCastDialogAfterDismiss else { return }
            shouldPresentCastDialogAfterDismiss = false
            _ = GCKCastContext.sharedInstance().presentCastDialog()
        }

        /// Same aggressive discovery kick as `CastButtonView`: iOS's mDNS is
        /// lazy on cold start, so a stop/start cycle wakes it up and the
        /// button appears without needing to open Google Home first.
        private func refreshDiscovery() {
            let manager = GCKCastContext.sharedInstance().discoveryManager
            manager.stopDiscovery()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                manager.startDiscovery()
            }
        }
    }
}
