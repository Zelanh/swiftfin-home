//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI

/// Builds a `MediaPlayerManager` that plays a downloaded item **offline**, from
/// the local media file, with no server negotiation.
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/). This is
/// the piece upstream left unbuilt (the commented `DownloadVideoPlayerManager`
/// reference). It reuses the normal player pipeline: a `MediaPlayerItemProvider`
/// whose resolver returns a `MediaPlayerItem` pointing at the on-disk file
/// (`getMediaURL()`) with the streams from the saved `Item.json` metadata.
/// Since there's no `transcodingURL`, the item direct-plays — VLCKit reads the
/// local file natively.
enum DownloadVideoPlayerManager {

    /// Returns `nil` if the media file is missing on disk.
    ///
    /// `@MainActor` because `MediaPlayerManager` (and `MediaPlayerItem`) are
    /// main-actor isolated; called from SwiftUI button actions, which are too.
    @MainActor
    static func make(for task: DownloadTask) -> MediaPlayerManager? {
        guard let url = task.getMediaURL() else { return nil }

        let item = task.item
        let mediaSource = item.mediaSources?.first ?? MediaSourceInfo()

        // Capture only Sendable values (the local URL) — DownloadTask itself is
        // not Sendable, so we don't reach back into it from the resolver.
        let provider = MediaPlayerItemProvider(
            item: item,
            mediaSource: mediaSource
        ) { baseItem, _ in
            let source = baseItem.mediaSources?.first ?? MediaSourceInfo()
            // MediaPlayerItem is @MainActor — hop to main to build it, exactly
            // like the online resolver awaits MediaPlayerItem.build.
            return await MediaPlayerItem(
                baseItem: baseItem,
                mediaSource: source,
                playSessionID: "offline-\(baseItem.id ?? UUID().uuidString)",
                url: url,
                deviceProfile: DeviceProfile()
            )
        }

        return MediaPlayerManager(provider: provider)
    }
}
