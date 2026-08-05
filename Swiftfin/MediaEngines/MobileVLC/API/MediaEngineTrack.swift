//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import CoreGraphics
import Foundation

// [MobileVLC4 fork]

/// One selectable audio or subtitle track, as the engine sees it.
///
/// `index` is the track's position in the engine's list for its own kind — the
/// same currency `MediaTrackIndexMap` already uses to bridge Jellyfin's stream
/// indexes to player indexes. libVLC 4 also gives every track a stable string
/// id; it is carried here because selecting by id is the only reliable way to
/// re-apply a choice across a track list that changed underneath us.
struct MediaEngineTrack: Hashable, Identifiable {

    /// Position within the engine's list of tracks of this kind.
    let index: Int

    /// The engine's own identifier for the track.
    let id: String

    /// Human-readable name, when the container provides one.
    let title: String?
}

/// A subtitle or audio file that lives beside the media rather than inside it.
///
/// Jellyfin calls these sidecar streams; libVLC calls them slaves.
struct MediaEngineSidecar: Hashable {

    enum Kind: Hashable {
        case subtitle
        case audio
    }

    let url: URL
    let kind: Kind

    /// Select this track as soon as it is added, overriding the container's own.
    let isEnforced: Bool
}

/// Everything the UI reads while playback is running.
///
/// Delivered on time updates so the player overlay, the scrubber and the
/// playback-information supplement all read from one snapshot.
struct MediaEnginePlaybackInfo {

    let seconds: Duration
    let videoSize: CGSize

    /// Frames the decoder threw away because it could not keep up.
    let droppedFrames: Int

    /// Frames that arrived damaged from the demuxer.
    let corruptedFrames: Int

    let audioTracks: [MediaEngineTrack]
    let subtitleTracks: [MediaEngineTrack]

    static let empty = MediaEnginePlaybackInfo(
        seconds: .zero,
        videoSize: .zero,
        droppedFrames: 0,
        corruptedFrames: 0,
        audioTracks: [],
        subtitleTracks: []
    )
}
