//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import UIKit

// [MobileVLC4 fork]

/// How subtitles are drawn.
///
/// Only ``size`` maps to a live property in VLCKit 4
/// (`currentSubTitleFontScale`). Font and colour were per-playback settings in
/// libVLC 3 but are engine-creation options in 4, so the backend applies them
/// when it builds its library instance and cannot change them mid-item. That
/// limitation is recorded here rather than hidden, because it is a real
/// regression against what the VLCUI-based player could do.
struct MediaEngineSubtitleStyle: Hashable {

    let fontName: String
    let color: UIColor

    /// Relative scale, where 1.0 is the engine's default size.
    let size: Double
}

/// Everything needed to start one item.
///
/// Built by the adapters from a `MediaPlayerItem`; the engine never sees a
/// Jellyfin type.
struct MediaEngineConfiguration {

    let url: URL

    /// Begin playing as soon as the media is loaded.
    var autoPlay: Bool = true

    /// Where to resume from.
    var startSeconds: Duration = .zero

    /// Playback speed, where 1.0 is normal.
    var rate: Float = 1.0

    /// Audio track to select once tracks are known, or `nil` to let the engine
    /// pick. Transcoded streams carry a single track, so they pass `nil`.
    var audioTrackIndex: Int?

    /// Subtitle track to select once tracks are known, or `nil` for none.
    var subtitleTrackIndex: Int?

    var subtitleStyle: MediaEngineSubtitleStyle?

    /// Subtitle or audio files to attach alongside the media.
    var sidecars: [MediaEngineSidecar] = []

    init(url: URL) {
        self.url = url
    }
}
