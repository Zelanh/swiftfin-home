//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import SwiftUI

/// The Downloads tab's list (iOS).
///
/// Part of the isolated Downloads integration (Swiftfin/Downloads/). The base
/// `DownloadListView` loads its items once in the view-model `init`, so as the
/// persistent tab root it would only reflect changes after an app relaunch — a
/// just-finished download wouldn't appear, and a just-deleted one would linger
/// (image files gone, so it showed with no artwork). This view instead reloads
/// straight from disk every time it appears or its tab is (re)selected, and adds
/// native iOS swipe-to-delete.
///
/// Everything lives here; the only reuse of base code is the existing
/// `DownloadListView.DownloadTaskRow`, so the row (and its thumbnail styling)
/// stays a single source of truth.
struct DownloadsListView: View {

    @Injected(\.downloadManager)
    private var downloadManager

    @InjectedObject(\.downloadStatusStore)
    private var statusStore

    @TabItemSelected
    private var tabItemSelected

    @State
    private var items: [DownloadTask] = []

    var body: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(items) { task in
                        DownloadListView.DownloadTaskRow(downloadTask: task)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    delete(task)
                                } label: {
                                    Label(L10n.delete, systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(L10n.downloads)
        .backport
        .toolbarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onReceive(tabItemSelected) { _ in reload() }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 52))
            Text(L10n.noItems)
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Re-reads the downloaded items from disk. Cheap (a directory listing plus a
    /// small JSON decode per item) and idempotent, so it's safe to call on every
    /// appear / tab selection.
    private func reload() {
        items = downloadManager.downloadedItems()
    }

    private func delete(_ task: DownloadTask) {
        task.deleteRootFolder()
        downloadManager.remove(task: task)
        items.removeAll { $0.item == task.item }
        // Keep the "downloaded" poster badges elsewhere in sync.
        statusStore.refresh()
    }
}
