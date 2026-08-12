//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

/// Thin overlay mounted from `BaseItemDto.posterOverlay` that shows a
/// "downloaded" badge on a poster cell when the item is available offline.
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/). Reads the
/// in-memory `DownloadStatusStore` — no per-render disk I/O.
struct DownloadedBadgeOverlay: View {

    @InjectedObject(\.downloadStatusStore)
    private var store

    let item: BaseItemDto

    var body: some View {
        if store.isDownloaded(item.id) {
            DownloadedIndicator()
        }
    }
}

/// The badge itself: a small white down-arrow on a green disc, top-leading
/// (the built-in favorite/played indicators live in the trailing corners).
struct DownloadedIndicator: View {

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.green)
            .frame(width: 22, height: 22)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
