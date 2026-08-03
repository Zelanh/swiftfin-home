//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import JellyfinAPI
import SwiftUI

extension NavigationRoute {

    @MainActor
    static var downloadList: NavigationRoute {
        NavigationRoute(
            id: "downloadList"
        ) {
            #if os(iOS)
            DownloadListView(viewModel: .init())
            #else
            EmptyView()
            #endif
        }
    }

    #if os(iOS)
    static func downloadTask(downloadTask: DownloadTask) -> NavigationRoute {
        NavigationRoute(
            id: "downloadTask",
            style: .sheet
        ) {
            DownloadTaskView(downloadTask: downloadTask)
        }
    }

    // [Downloads fork] Offline playback goes through our own self-contained player
    // (Swiftfin/Downloads/UltimaPlayer/), not the base `MediaPlayerManager` route,
    // so it's isolated from the base player and free of its per-launch leak.
    static func downloadPlayer(
        url: URL,
        title: String,
        runtimeSeconds: Double,
        itemID: String?
    ) -> NavigationRoute {
        NavigationRoute(
            id: "downloadPlayer",
            style: .fullscreen
        ) {
            UltimaPlayerView(
                url: url,
                title: title,
                runtimeSeconds: runtimeSeconds,
                itemID: itemID
            )
        }
    }

    // [experiment/swiftvlc-player] Experimental offline player on the SwiftVLC
    // engine (iOS 18+). Spike only — see UltimaFinPlayerView.
    @available(iOS 18.0, *)
    static func ultimaFinPlayer(
        url: URL,
        title: String
    ) -> NavigationRoute {
        NavigationRoute(
            id: "ultimaFinPlayer",
            style: .fullscreen
        ) {
            UltimaFinPlayerView(url: url, title: title)
        }
    }
    #endif
}
