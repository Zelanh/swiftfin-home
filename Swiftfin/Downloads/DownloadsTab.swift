//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

extension TabItem {

    /// Offline downloads tab (iOS). Backed by `DownloadsListView`, which reads the
    /// downloaded items straight from disk — so it works with no server
    /// connection, unlike the other content tabs — and, as the persistent tab
    /// root, reloads on every appear/selection and supports swipe-to-delete.
    ///
    /// Part of the isolated Downloads integration (Swiftfin/Downloads/). The only
    /// base touch is a one-line `[Downloads fork]` hook in `MainTabView` that adds
    /// this tab to the iPhone tab list.
    static var downloads: TabItem {
        TabItem(
            id: "downloads",
            title: L10n.downloads,
            systemImage: "arrow.down.circle.fill"
        ) {
            DownloadsListView()
        }
    }
}
