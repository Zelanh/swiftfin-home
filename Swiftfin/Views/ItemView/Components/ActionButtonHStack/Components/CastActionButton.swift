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
    /// in-player Cast flow incurs.
    ///
    /// `ActionButtonHStack` only mounts this when a Cast device is available
    /// (or a session is already active), and it also drives device discovery.
    /// So this view doesn't gate its own visibility — when it exists, a device
    /// exists. It just renders the button, runs the quality picker, and once a
    /// Cast session starts hands the item to `CastManager.castFromDetail`.
    /// Playback is then driven by the native Cast controls (the in-app player
    /// is never opened — the deliberate "Option A" design).
    struct CastActionButton: View {

        @InjectedObject(\.castManager)
        private var castManager: CastManager

        @ObservedObject
        var viewModel: ItemViewModel

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

        // MARK: - Body

        var body: some View {
            Button("Cast", systemImage: castManager.isSessionActive ? "tv.fill" : "tv") {
                handleTap()
            }
            .disabled(castTarget == nil)
            .onDisappear {
                // Drop any un-consumed cast intent if the user navigates away
                // after confirming but before a session started (e.g. they
                // cancelled the device dialog), so a stale intent can't later
                // cast the wrong item.
                awaitingSessionForCast = false
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
    }
}
