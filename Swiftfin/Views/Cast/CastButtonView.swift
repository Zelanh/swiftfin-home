//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Factory
import GoogleCast
import SwiftUI

/// The Cast affordance shown in the playback overlay.
///
/// Unlike the bare `GCKUICastButton` from the SDK, this button intercepts the
/// first tap to show a quality picker (audio + max bitrate) BEFORE handing off
/// to the native Cast device picker. Mirrors the flow that other Jellyfin
/// clients (Streamyfin, jellyfin-web with custom controls) use.
///
/// When a Cast session is already active, tapping just re-opens the native
/// dialog so the user can disconnect.
struct CastButtonView: View {

    var tintColor: Color = .white

    @InjectedObject(\.castManager)
    private var castManager: CastManager

    @InjectedObject(\.mediaPlayerManager)
    private var manager: MediaPlayerManager

    @State
    private var showingQualityPicker = false

    var body: some View {
        Button(action: handleTap) {
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tintColor)
                .frame(width: 28, height: 28)
        }
        // Match `GCKUICastButton`'s behaviour: hide when no devices are around.
        .opacity(castManager.hasAvailableDevices || castManager.isSessionActive ? 1 : 0)
        .disabled(!(castManager.hasAvailableDevices || castManager.isSessionActive))
        .onAppear {
            // Belt-and-braces: kick discovery on every appearance. The SDK's
            // `startDiscovery()` is idempotent, so calling it again is free.
            GCKCastContext.sharedInstance().discoveryManager.startDiscovery()
        }
        .sheet(isPresented: $showingQualityPicker) {
            // `handleTap` only flips this on when `playbackItem` is present, so
            // the optional unwrap is just a defensive guard.
            if let item = manager.playbackItem {
                CastQualityPickerView(
                    item: item,
                    onConfirm: { bitrate, audioIndex in
                        castManager.pendingMaxBitrate = bitrate
                        castManager.pendingAudioStreamIndex = audioIndex
                        showingQualityPicker = false
                        // Give the sheet a moment to dismiss before the
                        // native cast dialog tries to present.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            _ = GCKCastContext.sharedInstance().presentCastDialog()
                        }
                    },
                    onCancel: {
                        showingQualityPicker = false
                    }
                )
            }
        }
    }

    private var iconName: String {
        castManager.isSessionActive ? "tv.fill" : "tv"
    }

    private func handleTap() {
        if castManager.isSessionActive {
            // Already casting — open the native dialog so the user can stop
            // or switch device. No quality picker (re-load would need a stop
            // + restart roundtrip we don't support yet).
            _ = GCKCastContext.sharedInstance().presentCastDialog()
        } else if manager.playbackItem != nil {
            // Standard path: show picker, then native dialog on confirm.
            showingQualityPicker = true
        } else {
            // Edge: button somehow visible without an item loaded. Skip the
            // picker and go straight to the native dialog with defaults.
            _ = GCKCastContext.sharedInstance().presentCastDialog()
        }
    }
}
