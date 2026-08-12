//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Foundation

extension Container {

    var downloadStatusStore: Factory<DownloadStatusStore> {
        self { @MainActor in DownloadStatusStore() }.singleton
    }
}

/// In-memory cache of downloaded item IDs, so poster cells can show a
/// "downloaded" badge without doing a filesystem check on every render.
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/). Refreshed
/// from upstream's `DownloadManager.downloadedItems()` at launch and whenever a
/// download completes or is deleted (driven from `DownloadActionButton`).
@MainActor
final class DownloadStatusStore: ObservableObject {

    @Injected(\.downloadManager)
    private var downloadManager

    @Published
    private(set) var downloadedIDs: Set<String> = []

    init() {
        refresh()
    }

    /// Reload the set of downloaded item IDs from disk. Cheap and infrequent —
    /// only called at launch and on download completion/deletion, never per cell.
    func refresh() {
        downloadedIDs = Set(downloadManager.downloadedItems().compactMap(\.item.id))
    }

    func isDownloaded(_ id: String?) -> Bool {
        guard let id else { return false }
        return downloadedIDs.contains(id)
    }
}
