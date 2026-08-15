//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import FactoryKit
import Foundation
import JellyfinAPI

/// How much of an item is on disk, as a poster badge needs to say it.
///
/// Deliberately not called `.none` in the empty case: `DownloadBadgeState.none`
/// collides with `Optional.none` in pattern matching often enough to be worth
/// avoiding outright.
enum DownloadBadgeState: Equatable {

    case notDownloaded

    /// Some, but not all.
    ///
    /// `total` is `nil` when the server did not say how many there are — the badge
    /// then shows the bare count rather than claiming a completeness it has no way
    /// to know. It also makes a missing `ItemFields` request visible on screen
    /// instead of silently hiding the badge.
    case partial(downloaded: Int, total: Int?)

    case complete
}

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

    /// How many episodes of each season are on disk, keyed by season id.
    @Published
    private(set) var downloadedCountBySeason: [String: Int] = [:]

    /// How many episodes of each series are on disk, keyed by series id.
    @Published
    private(set) var downloadedCountBySeries: [String: Int] = [:]

    private var cancellables = Set<AnyCancellable>()

    init() {
        refresh()

        // A background transfer can finish with no download button on screen, or
        // with the app not running at all, so the button-driven refreshes cannot
        // be the only ones. Watching the transfer layer is what makes a download
        // appear the moment it lands rather than at the next launch.
        //
        // Hopping through `Task { @MainActor }` because a Combine `sink` closure
        // carries no isolation of its own, and `refresh()` is main-actor bound.
        Container.shared.mediaTransferring()?.transferStates
            .map { states in Set(states.filter { $0.value.isTerminal }.keys) }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &cancellables)
    }

    /// Reload the set of downloaded item IDs from disk. Cheap and infrequent —
    /// only called at launch and on download completion/deletion, never per cell.
    func refresh() {
        let items = downloadManager.downloadedItems().map(\.item)

        downloadedIDs = Set(items.compactMap(\.id))

        // The numerator of the badge, and it costs nothing extra: the episodes
        // already carry the ids of the season and series they belong to, so this
        // is the same crawl grouped two more ways.
        downloadedCountBySeason = items.compactMap(\.seasonID)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        downloadedCountBySeries = items.compactMap(\.seriesID)
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    }

    func isDownloaded(_ id: String?) -> Bool {
        guard let id else { return false }
        return downloadedIDs.contains(id)
    }

    /// What the poster badge should show for this item.
    ///
    /// The join: the numerator comes from disk, the denominator from the server's
    /// own count on the item being drawn. Neither half is stored, so neither can
    /// go stale — a season gains an episode on the server and the badge is right
    /// on the next fetch, with nothing to invalidate.
    ///
    /// Every type other than season and series keeps exactly the old behaviour, so
    /// nothing that has a badge today can change.
    func badgeState(for item: BaseItemDto) -> DownloadBadgeState {
        guard let id = item.id else { return .notDownloaded }

        switch item.type {
        case .season:
            return badgeState(downloaded: downloadedCountBySeason[id] ?? 0, total: item.childCount)
        case .series:
            return badgeState(downloaded: downloadedCountBySeries[id] ?? 0, total: item.recursiveItemCount)
        default:
            return downloadedIDs.contains(id) ? .complete : .notDownloaded
        }
    }

    /// `downloaded >= total` rather than `==` on purpose: the counts come from two
    /// different places and a series can lose an episode on the server while its
    /// file stays on the phone. Complete is the honest reading of that, and it
    /// avoids a badge stuck at 11/10.
    private func badgeState(downloaded: Int, total: Int?) -> DownloadBadgeState {
        guard downloaded > 0 else { return .notDownloaded }
        guard let total, total > 0 else { return .partial(downloaded: downloaded, total: nil) }

        return downloaded >= total ? .complete : .partial(downloaded: downloaded, total: total)
    }
}
