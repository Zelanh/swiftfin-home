//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import JellyfinAPI
import SwiftUI

/// Sheet shown before a Cast session starts, so the user can pick the audio
/// track and the maximum bitrate. Mirrors the flow used by other Jellyfin
/// clients like Streamyfin.
///
/// The bitrate tiers are sourced directly from Swiftfin's `PlaybackBitrate`
/// enum so this picker shows exactly the same labels (and the same `.auto`
/// behaviour) as the global Settings → Playback Quality picker. The chosen
/// tier acts as a per-Cast override; the audio override is per-cast only
/// and not persisted.
///
/// On confirm, the chosen values are passed back via `onConfirm` and the
/// caller is responsible for kicking off the actual Cast device picker.
struct CastQualityPickerView: View {

    /// Audio tracks to offer. Decoupled from `MediaPlayerItem` so the picker
    /// works both from the in-player flow (which has a built item) and from
    /// the item-detail page (which only has a `MediaSourceInfo`, and must not
    /// trigger a transcode negotiation just to show the sheet).
    let audioStreams: [MediaStream]
    let onConfirm: (_ bitrate: PlaybackBitrate, _ audioStreamIndex: Int?) -> Void
    let onCancel: () -> Void

    @State
    private var selectedBitrate: PlaybackBitrate

    @State
    private var selectedAudioIndex: Int?

    init(
        audioStreams: [MediaStream],
        initialAudioStreamIndex: Int?,
        onConfirm: @escaping (PlaybackBitrate, Int?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.audioStreams = audioStreams
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // Pre-select what the user picked last time (persisted via Defaults)
        // and the audio they already had selected.
        self._selectedBitrate = .init(initialValue: Defaults[.castBitrate])
        self._selectedAudioIndex = .init(initialValue: initialAudioStreamIndex)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                if !audioStreams.isEmpty {
                    audioSection
                }
                bitrateSection
            }
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel", action: onCancel)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Cast")
                .font(.headline)
            Spacer()
            Button("Start") {
                // Persist for next time and hand control back to the caller.
                Defaults[.castBitrate] = selectedBitrate
                onConfirm(selectedBitrate, selectedAudioIndex)
            }
            .fontWeight(.semibold)
        }
        .padding()
    }

    private var audioSection: some View {
        Section(header: Text("Audio")) {
            Picker("Audio track", selection: $selectedAudioIndex) {
                ForEach(audioStreams, id: \.index) { stream in
                    Text(stream.displayTitle ?? "Audio \(stream.index ?? 0)")
                        .tag(stream.index as Int?)
                }
            }
        }
    }

    private var bitrateSection: some View {
        Section(
            header: Text("Maximum bitrate"),
            footer: Text(
                "Lower bitrates make Cast more reliable on weak WiFi and " +
                    "avoid stutter on HDR sources. Pick higher only if your " +
                    "network is solid. \"Auto\" runs a quick speed test on the " +
                    "next cast."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        ) {
            // Explicit Button rows instead of `Picker(.inline)`:
            // SwiftUI's inline picker style with an Int tag has been
            // observed to desync the visual checkmark from the bound
            // @State value. Driving the assignment manually from each
            // Button removes the ambiguity — the row that's drawn
            // checked is exactly the one whose value is in @State.
            ForEach(PlaybackBitrate.allCases, id: \.rawValue) { option in
                Button {
                    selectedBitrate = option
                } label: {
                    HStack {
                        Text(option.displayTitle)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedBitrate == option {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
