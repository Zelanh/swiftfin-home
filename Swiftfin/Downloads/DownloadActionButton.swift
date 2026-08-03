//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Defaults
import FactoryKit
import JellyfinAPI
import SwiftUI

extension ItemView {

    /// Download affordance on the item-detail action row, next to Played /
    /// Favorite / Cast. Reuses upstream's `DownloadManager` + `DownloadTask`
    /// engine — this view only drives the button UI (idle → downloading →
    /// downloaded) and matches the neighbouring pills' style.
    ///
    /// Part of the isolated Downloads integration (Swiftfin/Downloads/). Only
    /// mounted for single downloadable items (movies, episodes); the parent
    /// `ActionButtonHStack` gates on item type.
    struct DownloadActionButton: View {

        @InjectedObject(\.downloadManager)
        private var downloadManager

        @ObservedObject
        var provider: ItemContentGroupProvider

        private var item: BaseItemDto { provider.item }

        // Pre-flight storage check (A1): warn before starting a download that
        // won't fit, instead of failing silently part-way through the transfer.
        @State
        private var showStorageWarning = false
        @State
        private var storageNeeded = 0
        @State
        private var storageAvailable = 0

        // Wi-Fi-only guard (B5): warn instead of downloading on cellular.
        @State
        private var showCellularWarning = false

        var body: some View {
            Group {
                // The manager republishes when a task is added/removed; live
                // progress and completion come from observing the task itself.
                //
                // Match the active task by `id`, NOT by full `BaseItemDto` equality:
                // toggling Favorite/Played mutates `userData`, so `provider.item`
                // becomes `!=` the in-flight task's item. With full equality that
                // unmatched a download mid-progress and briefly flashed the idle
                // "download" button (looked like it would re-download). `id` is stable.
                if let task = downloadManager.downloads.first(where: { $0.item.id == item.id }) {
                    ActiveDownloadButton(task: task)
                } else if downloadManager.task(for: item) != nil {
                    DownloadedButton(item: item)
                } else {
                    Button {
                        startDownload()
                    } label: {
                        DownloadPill(systemImage: "arrow.down.circle")
                    }
                    .foregroundStyle(.primary, .secondary)
                }
            }
            .alert(L10n.notEnoughStorage, isPresented: $showStorageWarning) {
                Button(L10n.ok, role: .cancel) {}
            } message: {
                Text("\(Int64(storageNeeded).formatted(.byteCount(style: .file))) / \(Int64(storageAvailable).formatted(.byteCount(style: .file)))")
            }
            .alert(L10n.downloadOverWifiOnly, isPresented: $showCellularWarning) {
                Button(L10n.ok, role: .cancel) {}
            }
        }

        /// Starts the download after two guards:
        ///
        /// 1. Storage — if the item's reported size clearly won't fit in the
        ///    volume's available capacity, warn instead. Unknown size (0) or
        ///    unreadable capacity (-1) don't block.
        /// 2. Wi-Fi only — if that setting is on and we're on cellular, warn
        ///    instead. The connection check is async, hence the `Task`.
        private func startDownload() {
            let needed = item.mediaSources?.first?.size ?? 0
            let available = FileManager.default.availableStorage

            if needed > 0, available >= 0, needed > available {
                storageNeeded = needed
                storageAvailable = available
                showStorageWarning = true
                return
            }

            guard Defaults[.downloadOverWifiOnly] else {
                downloadManager.download(task: DownloadTask(item: item))
                return
            }

            Task { @MainActor in
                let context = await NetworkConnectionContext.current()
                if context.interface == .cellular {
                    showCellularWarning = true
                } else {
                    downloadManager.download(task: DownloadTask(item: item))
                }
            }
        }
    }
}

// MARK: - Active download (downloading / just-completed)

private struct ActiveDownloadButton: View {

    @Injected(\.downloadManager)
    private var downloadManager

    @ObservedObject
    var task: DownloadTask

    var body: some View {
        switch task.state {
        case let .downloading(progress):
            Button {
                downloadManager.cancel(task: task)
            } label: {
                DownloadPill(systemImage: "stop.circle", isHighlighted: true, tint: .orange, badge: "\(Int(progress * 100))%")
            }
            .foregroundStyle(.primary, .secondary)
        case .complete:
            DownloadedButton(item: task.item)
        case .error:
            Button {
                downloadManager.download(task: task)
            } label: {
                DownloadPill(systemImage: "arrow.clockwise.circle", isHighlighted: true, tint: .red)
            }
            .foregroundStyle(.primary, .secondary)
        case .ready, .cancelled:
            Button {
                downloadManager.download(task: task)
            } label: {
                DownloadPill(systemImage: "arrow.down.circle")
            }
            .foregroundStyle(.primary, .secondary)
        }
    }
}

// MARK: - Downloaded (on disk) — tap to delete

private struct DownloadedButton: View {

    @Injected(\.downloadManager)
    private var downloadManager

    @Injected(\.downloadStatusStore)
    private var statusStore

    @Router
    private var router

    let item: BaseItemDto

    var body: some View {
        Menu {
            Button(L10n.play) {
                if let task = downloadManager.task(for: item),
                   let url = task.getMediaURL()
                {
                    router.route(
                        to: .downloadPlayer(
                            url: url,
                            title: task.item.displayTitle,
                            runtimeSeconds: task.item.runtime.map { Double($0.components.seconds) } ?? 0
                        )
                    )
                }
            }

            Button(role: .destructive) {
                if let task = downloadManager.task(for: item) {
                    task.deleteRootFolder()
                    downloadManager.remove(task: task)
                }
                statusStore.refresh()
            } label: {
                Text(L10n.delete)
            }
        } label: {
            DownloadPill(systemImage: "checkmark.circle.fill", isHighlighted: true, tint: .green)
        }
        .foregroundStyle(.primary, .secondary)
        .onAppear { statusStore.refresh() }
    }
}

// MARK: - Pill (mirrors ActionButtonHStack.materialLabel, iOS branch)

private struct DownloadPill: View {

    let systemImage: String
    var isHighlighted: Bool = false
    var tint: Color = .blue
    var badge: String? = nil

    var body: some View {
        let shape: RoundedRectangle = .rect(cornerRadius: 10, style: .circular)

        Label {
            Text(L10n.download)
        } icon: {
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .monospacedDigit()
            } else {
                Image(systemName: systemImage)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .backport
        .glassEffect(
            .regular.selection(
                tint: isHighlighted ? tint : .gray.opacity(0.3),
                foregroundColor: .primary
            ),
            in: shape
        )
    }
}
