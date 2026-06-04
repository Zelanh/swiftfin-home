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
/// On confirm, the chosen values are passed back via `onConfirm` and the
/// caller is responsible for kicking off the actual Cast device picker.
struct CastQualityPickerView: View {

    let item: MediaPlayerItem
    let onConfirm: (_ maxBitrate: Int, _ audioStreamIndex: Int?) -> Void
    let onCancel: () -> Void

    @State
    private var selectedBitrate: Int

    @State
    private var selectedAudioIndex: Int?

    init(
        item: MediaPlayerItem,
        onConfirm: @escaping (Int, Int?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // Pre-select what the user picked last time (persisted via Defaults)
        // and the audio they already had selected for local playback.
        self._selectedBitrate = .init(initialValue: Defaults[.castMaxBitrate])
        self._selectedAudioIndex = .init(initialValue: item.selectedAudioStreamIndex)
    }

    // MARK: - Bitrate options

    /// Pairs of (bits/sec, human label). `0` is the sentinel for "no cap".
    private static let bitrateOptions: [(bps: Int, label: String)] = [
        (1_500_000, "1.5 Mbps · 480p"),
        (3_000_000, "3 Mbps · 720p"),
        (5_000_000, "5 Mbps · 720p HQ"),
        (8_000_000, "8 Mbps · 1080p"),
        (12_000_000, "12 Mbps · 1080p HQ"),
        (20_000_000, "20 Mbps · 4K"),
        (0, "Unlimited"),
    ]

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                if !item.audioStreams.isEmpty {
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
                Defaults[.castMaxBitrate] = selectedBitrate
                onConfirm(selectedBitrate, selectedAudioIndex)
            }
            .fontWeight(.semibold)
        }
        .padding()
    }

    private var audioSection: some View {
        Section(header: Text("Audio")) {
            Picker("Audio track", selection: $selectedAudioIndex) {
                ForEach(item.audioStreams, id: \.index) { stream in
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
                    "network is solid."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        ) {
            Picker("Quality", selection: $selectedBitrate) {
                ForEach(Self.bitrateOptions, id: \.bps) { option in
                    Text(option.label).tag(option.bps)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}
