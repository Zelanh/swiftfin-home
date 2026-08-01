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

        var body: some View {
            // The manager republishes when a task is added/removed; live
            // progress and completion come from observing the task itself.
            if let task = downloadManager.downloads.first(where: { $0.item == item }) {
                ActiveDownloadButton(task: task)
            } else if downloadManager.task(for: item) != nil {
                DownloadedButton(item: item)
            } else {
                Button {
                    downloadManager.download(task: DownloadTask(item: item))
                } label: {
                    DownloadPill(systemImage: "arrow.down.circle")
                }
                .foregroundStyle(.primary, .secondary)
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
                   let manager = DownloadVideoPlayerManager.make(for: task)
                {
                    router.route(to: .videoPlayer(manager: manager))
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
