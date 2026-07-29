//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import GoogleCast
import JellyfinAPI
import SwiftUI

extension ItemView {

    /// Cast affordance shown on the item-detail page, alongside Played /
    /// Favorite / Trailer. Lets the user cast **without playing locally
    /// first**, which avoids the wasted second transcode the in-player Cast
    /// flow incurs.
    ///
    /// `ActionButtonHStack` only mounts this when a Cast device is available
    /// (or a session is already active), and it also drives device discovery.
    /// So this view doesn't gate its own visibility — when it exists, a device
    /// exists. It just renders the button, runs the quality picker, and once a
    /// Cast session starts hands the item to `CastManager.castFromDetail`.
    /// Playback is then driven by the native Cast controls (the in-app player
    /// is never opened — the deliberate "Option A" design).
    ///
    /// It reads the resolved playable item + media source from the same
    /// `ItemContentGroupProvider.mediaPlayerItemProvider` the Play button uses,
    /// so casting a series casts the next-up episode, exactly like local play.
    struct CastActionButton: View {

        @InjectedObject(\.castManager)
        private var castManager: CastManager

        @ObservedObject
        var provider: ItemContentGroupProvider

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
            guard let baseItem = provider.mediaPlayerItemProvider?.item,
                  let mediaSource = provider.mediaPlayerItemProvider?.mediaSource
            else { return nil }
            return (baseItem, mediaSource)
        }

        private var audioStreams: [MediaStream] {
            castTarget?.mediaSource.mediaStreams?.filter { $0.type == .audio } ?? []
        }

        // MARK: - Body

        var body: some View {
            Button {
                handleTap()
            } label: {
                materialLabel(
                    "Cast",
                    systemImage: castManager.isSessionActive ? "tv.fill" : "tv",
                    isHighlighted: castManager.isSessionActive,
                    tint: .jellyfinPurple
                )
            }
            .foregroundStyle(.primary, .secondary)
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
                    initialAudioStreamIndex: castTarget?.mediaSource.defaultAudioStreamIndex,
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

        // MARK: - Material label
        //
        // Mirrors `ActionButtonHStack.materialLabel` (iOS branch) so this pill
        // matches the Played / Favorite / Trailer neighbours. Kept local to
        // this file rather than reaching into the upstream (private) helper, so
        // the base hook in `ActionButtonHStack` stays a one-liner. `.iconOnly`,
        // font and button style are inherited from the parent HStack.
        @ViewBuilder
        private func materialLabel(
            _ title: String,
            systemImage: String,
            isHighlighted: Bool,
            tint: Color
        ) -> some View {
            let shape: RoundedRectangle = .rect(cornerRadius: 10, style: .circular)

            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .backport
            .glassEffect(
                .regular.selection(
                    tint: isHighlighted ? tint : .gray.opacity(0.3),
                    foregroundColor: .primary
                ),
                in: shape
            )
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
