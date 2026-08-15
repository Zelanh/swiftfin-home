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

/// Thin overlay mounted from `BaseItemDto.posterOverlay` that says how much of an
/// item is available offline.
///
/// Three states, and which one applies depends on what is being drawn: an episode
/// or film is simply there or not, while a season or series can be half-owned and
/// says so — "3/10" — because that is the more useful thing to know at a glance.
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/). Reads the
/// in-memory `DownloadStatusStore`; the counts are dictionary lookups, so this
/// stays free of per-render disk I/O.
struct DownloadedBadgeOverlay: View {

    @InjectedObject(\.downloadStatusStore)
    private var store

    let item: BaseItemDto

    var body: some View {
        switch store.badgeState(for: item) {
        case .notDownloaded:
            EmptyView()
        case let .partial(downloaded, total):
            DownloadPartialIndicator(downloaded: downloaded, total: total)
        case .complete:
            DownloadedIndicator()
        }
    }
}

/// The partial badge: a count on a yellow capsule.
///
/// Same corner, same height and same shadow as the green one so a grid of posters
/// stays visually even whichever badge each cell happens to draw. Black on yellow
/// rather than white, which is the readable way round at this size.
struct DownloadPartialIndicator: View {

    let downloaded: Int
    let total: Int?

    /// Falls back to the bare count when the server did not report a total, which
    /// is honest about what is known and visibly different from a wrong ratio.
    private var label: String {
        guard let total else { return "\(downloaded)" }
        return "\(downloaded)/\(total)"
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(Color.yellow, in: Capsule())
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
