//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import SwiftUI

// [Downloads fork] [MobileVLC4 fork]

/// The offline player's single overflow menu.
///
/// Mirrors the online player's `ActionButtons` menu — one ellipsis, nested
/// submenus, checkmarks on the active choice — but is built from
/// ``MediaEnginePlayer`` alone, because downloaded playback deliberately never
/// touches `MediaPlayerManager`.
///
/// Two entries from the online menu are missing on purpose. Playback quality is
/// meaningless for a file already on disk: there is no server to renegotiate a
/// bitrate with. Auto play and next/previous need a queue, which offline
/// playback does not have.
struct UltimaPlayerMenu: View {

    @Default(.VideoPlayer.Playback.rates)
    private var rates: [Float]

    /// Held, not observed. `MediaEnginePlayer` republishes on every time update,
    /// and observing it here rebuilt the menu several times a second — visible
    /// as a faint flicker while it was open. The menu only ever *calls* the
    /// player; everything it displays arrives as a value below.
    let player: MediaEnginePlayer

    let audioTracks: [UltimaPlayerView.Track]
    let subtitleTracks: [UltimaPlayerView.Track]

    /// Passed in rather than read off `player`, so this view needs no observation.
    let isPictureInPictureAvailable: Bool

    @Binding
    var currentAudioIndex: Int?
    @Binding
    var currentSubtitleIndex: Int?
    @Binding
    var isAspectFill: Bool
    @Binding
    var rate: Float

    /// Keeps the overlay from auto-hiding while the menu is being used.
    let onInteraction: () -> Void

    var body: some View {
        Menu {
            aspectFillButton

            if isPictureInPictureAvailable {
                pictureInPictureButton
            }

            if audioTracks.count > 1 {
                audioMenu
            }

            if subtitleTracks.isNotEmpty {
                subtitleMenu
            }

            speedMenu
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuOrder(.fixed)
    }

    // MARK: Entries

    private var aspectFillButton: some View {
        Button {
            isAspectFill.toggle()
            player.setAspectFill(isAspectFill)
            onInteraction()
        } label: {
            Label(
                L10n.aspectFill,
                systemImage: isAspectFill
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right"
            )
        }
    }

    private var pictureInPictureButton: some View {
        Button {
            player.startPictureInPicture()
            onInteraction()
        } label: {
            Label(L10n.pictureInPicture, systemImage: "pip.enter")
        }
    }

    private var audioMenu: some View {
        Menu {
            ForEach(audioTracks) { track in
                Button {
                    player.selectAudioTrack(at: track.index)
                    currentAudioIndex = track.index
                    onInteraction()
                } label: {
                    label(track.title, isSelected: currentAudioIndex == track.index)
                }
            }
        } label: {
            Label(L10n.audio, systemImage: "speaker.wave.2")
        }
    }

    private var subtitleMenu: some View {
        Menu {
            // libVLC 3 published a synthetic "Disable" track; VLCKit 4 does not,
            // so the way to turn subtitles off has to be offered explicitly.
            Button {
                player.selectSubtitleTrack(at: nil)
                currentSubtitleIndex = nil
                onInteraction()
            } label: {
                label(L10n.none, isSelected: currentSubtitleIndex == nil)
            }

            ForEach(subtitleTracks) { track in
                Button {
                    player.selectSubtitleTrack(at: track.index)
                    currentSubtitleIndex = track.index
                    onInteraction()
                } label: {
                    label(track.title, isSelected: currentSubtitleIndex == track.index)
                }
            }
        } label: {
            Label(L10n.subtitles, systemImage: "captions.bubble")
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach(rates, id: \.self) { value in
                Button {
                    rate = value
                    player.setRate(value)
                    onInteraction()
                } label: {
                    // `.playbackRate` is the same format style the online menu
                    // uses, so both players spell "1.5x" identically.
                    if rate == value {
                        Label {
                            Text(value, format: .playbackRate)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(value, format: .playbackRate)
                    }
                }
            }
        } label: {
            Label(L10n.playbackSpeed, systemImage: "speedometer")
        }
    }

    /// A menu row that shows a checkmark when it is the active choice.
    @ViewBuilder
    private func label(_ title: String, isSelected: Bool) -> some View {
        if isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
