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
/// persistent tab root it would only reflect changes after an app relaunch. This
/// view instead reloads straight from disk every time it appears or its tab is
/// (re)selected, adds native iOS swipe-to-delete, an "in progress" section with
/// live progress bars for active downloads, and a total-size header.
///
/// The only reuse of base code is the existing `DownloadListView.DownloadTaskRow`
/// for finished items, so the row (and its thumbnail styling) stays a single
/// source of truth.
struct DownloadsListView: View {

    @InjectedObject(\.downloadManager)
    private var downloadManager

    @InjectedObject(\.downloadStatusStore)
    private var statusStore

    @TabItemSelected
    private var tabItemSelected

    // Finished downloads, read from disk.
    @State
    private var items: [DownloadTask] = []

    // Total on-disk size of everything under our downloads directory.
    @State
    private var totalBytes: Int = 0

    /// In-progress downloads, straight from the shared manager (`@Published`, so
    /// this view re-renders as they're added/removed). Per-download progress is
    /// observed inside `ActiveDownloadRow`.
    private var activeDownloads: [DownloadTask] {
        downloadManager.downloads.filter { task in
            switch task.state {
            case .downloading, .ready:
                return true
            default:
                return false
            }
        }
    }

    var body: some View {
        Group {
            if items.isEmpty, activeDownloads.isEmpty {
                emptyState
            } else {
                List {
                    if activeDownloads.isNotEmpty {
                        Section(L10n.inProgress) {
                            ForEach(activeDownloads) { task in
                                ActiveDownloadRow(task: task, onFinished: reload)
                            }
                        }
                    }

                    Section {
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
                    } header: {
                        if totalBytes > 0 {
                            Text("\(L10n.size): \(Int64(totalBytes).formatted(.byteCount(style: .file)))")
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

    /// Re-reads finished items and the total size from disk. Cheap and
    /// idempotent, so it's safe to call on every appear / tab selection / when an
    /// active download finishes.
    private func reload() {
        items = downloadManager.downloadedItems()
        totalBytes = max(0, URL.swiftfinDownloads.sizeOnDisk)
    }

    private func delete(_ task: DownloadTask) {
        task.deleteRootFolder()
        downloadManager.remove(task: task)
        items.removeAll { $0.item.id == task.item.id }
        statusStore.refresh()
        totalBytes = max(0, URL.swiftfinDownloads.sizeOnDisk)
    }
}

// MARK: - Active download row (live progress)

private struct ActiveDownloadRow: View {

    @Injected(\.downloadManager)
    private var downloadManager

    @ObservedObject
    var task: DownloadTask

    /// Called once the download leaves the in-progress states (finished, failed,
    /// or cancelled) so the parent can reload and move it into the finished list.
    let onFinished: () -> Void

    private var progress: Double {
        if case let .downloading(value) = task.state {
            return value
        }
        return 0
    }

    private var isTerminal: Bool {
        switch task.state {
        case .complete, .error, .cancelled:
            return true
        default:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ImageView([
                task.getImageURL(name: "Backdrop"),
                task.getImageURL(name: "Primary"),
            ])
            .failure {
                Color.secondary.opacity(0.8)
            }
            .posterStyle(.landscape)
            .frame(width: 88)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.item.displayTitle)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                Text(progress > 0 ? progress.formatted(.percent.precision(.fractionLength(0))) : L10n.inProgress)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                downloadManager.cancel(task: task)
            } label: {
                Image(systemName: "stop.circle")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .backport
        .onChange(of: isTerminal) { _, terminal in
            if terminal { onFinished() }
        }
    }
}
