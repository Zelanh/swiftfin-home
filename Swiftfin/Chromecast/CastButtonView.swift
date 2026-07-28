//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
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

    /// Foreground/background tracking — used to refresh discovery when the
    /// user comes back to Swiftfin after visiting (e.g.) Google Home, which
    /// is exactly when the iOS Bonjour cache becomes warm.
    @Environment(\.scenePhase)
    private var scenePhase

    @State
    private var showingQualityPicker = false

    /// Latched at `onConfirm` time and read back from `.sheet(onDismiss:)`
    /// so we present the native cast dialog AFTER the picker sheet has
    /// fully animated out — instead of guessing with `asyncAfter`. See
    /// the `.sheet` modifier below for the full reasoning.
    @State
    private var shouldPresentCastDialogAfterDismiss = false

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
            refreshDiscovery()
        }
        .onChange(of: scenePhase) { newPhase in
            // The classic "Google Home trick" the user reported: opening the
            // Home app warms the iOS Bonjour cache, then returning to Swiftfin
            // makes the Cast button suddenly appear. By re-scanning on every
            // .active transition we make that warming happen automatically.
            if newPhase == .active {
                refreshDiscovery()
            }
        }
        // Surface cast-load failures on-device: with a sideloaded build we
        // have no console, so this alert is our only window into why a cast
        // silently does nothing.
        .alert(
            "Cast",
            isPresented: Binding(
                get: { castManager.lastLoadError != nil },
                set: { if !$0 { castManager.clearLoadError() } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(castManager.lastLoadError ?? "")
        }
        .sheet(
            isPresented: $showingQualityPicker,
            onDismiss: {
                // `onDismiss` fires AFTER SwiftUI has fully animated the
                // sheet out — which is exactly the moment when
                // `presentCastDialog()` can safely take over the
                // foreground without colliding with the sheet's
                // dismissal animation. Using this event instead of an
                // `asyncAfter(0.4)` makes the flow robust to:
                //   - iOS version changes to sheet animation duration
                //   - slow devices where 0.4s is not enough
                //   - users with Reduce Motion or VoiceOver enabled
                //   - any future SwiftUI re-architecture of `.sheet`
                // The latched bool distinguishes confirm (present dialog)
                // from cancel (do nothing).
                if shouldPresentCastDialogAfterDismiss {
                    shouldPresentCastDialogAfterDismiss = false
                    _ = GCKCastContext.sharedInstance().presentCastDialog()
                }
            }
        ) {
            // `handleTap` only flips this on when `playbackItem` is present, so
            // the optional unwrap is just a defensive guard.
            if let item = manager.playbackItem {
                CastQualityPickerView(
                    audioStreams: item.audioStreams,
                    initialAudioStreamIndex: item.selectedAudioStreamIndex,
                    onConfirm: { bitrate, audioIndex in
                        castManager.pendingBitrate = bitrate
                        castManager.pendingAudioStreamIndex = audioIndex
                        // Latch the intent; the actual cast-dialog
                        // presentation happens from the sheet's
                        // `onDismiss` so we wait for the real animation
                        // end instead of guessing with a timer.
                        shouldPresentCastDialogAfterDismiss = true
                        showingQualityPicker = false
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

    /// Force a fresh device-discovery scan.
    ///
    /// A bare `startDiscovery()` on a cold app launch frequently fails to
    /// find devices because iOS's mDNS/Bonjour stack is lazy: if no app has
    /// recently triggered a scan, the OS doesn't bother to respond promptly.
    /// The classic symptom (reported by users): the Cast button stays hidden
    /// until you open Google Home — which warms the cache — and then comes
    /// back to Swiftfin, at which point the button magically appears.
    ///
    /// Combining `stopDiscovery()` with a short delay before `startDiscovery()`
    /// is a more aggressive kick that has proven reliable in the field.
    private func refreshDiscovery() {
        let mgr = GCKCastContext.sharedInstance().discoveryManager
        mgr.stopDiscovery()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            mgr.startDiscovery()
        }
    }
}
