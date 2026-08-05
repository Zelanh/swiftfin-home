//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

// [MobileVLC4 fork]

/// The playback states Swiftfin reacts to, independent of any VLC type.
///
/// This is deliberately *not* a mirror of `VLCMediaPlayerState`. libVLC 4
/// removed the `Buffering`, `ESAdded` and `Ended` states that libVLC 3 had,
/// leaving `Opening / Playing / Paused / Stopping / Stopped / Error`. Two of
/// the three removed states still matter to us, so the backend synthesises
/// them and the rest of the app keeps the vocabulary it already speaks:
///
/// - ``buffering`` comes from libVLC 4's separate buffering-progress callback
///   rather than from a state.
/// - ``ended`` is derived from `Stopping`: in libVLC 4 reaching the end of a
///   media *is* the beginning of a stop. What distinguishes "it finished" from
///   "we stopped it" is not the playback position — it is whether we asked. The
///   backend tracks that intent and reports ``stopped`` for a stop it
///   requested, ``ended`` for one it did not.
///
/// Keeping ``ended`` alive here is the whole point of owning the boundary:
/// `MediaPlayerManager` still gets the event that drives "play next episode",
/// and never learns that libVLC changed its mind about state machines.
enum MediaEngineState: Hashable {

    /// The media is being opened; no frames yet.
    case opening

    /// Playback is stalled while the buffer refills.
    case buffering

    case playing

    case paused

    /// Playback stopped because *we* asked it to.
    case stopped

    /// Playback reached the end of the media on its own.
    ///
    /// This is the signal that advances a series to the next episode.
    case ended

    /// The engine failed and cannot continue.
    case error
}

extension MediaEngineState {

    /// Whether this state means no more frames are coming, for any reason.
    var isTerminal: Bool {
        switch self {
        case .stopped, .ended, .error:
            true
        case .opening, .buffering, .playing, .paused:
            false
        }
    }
}
