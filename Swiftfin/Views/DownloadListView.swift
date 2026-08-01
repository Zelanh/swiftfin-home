//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI

struct DownloadListView: View {

    @ObservedObject
    var viewModel: DownloadListViewModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            ForEach(viewModel.items) { item in
                DownloadTaskRow(downloadTask: item)
            }
        }
        .navigationTitle(L10n.downloads)
        .backport
        .toolbarTitleDisplayMode(.inline)
    }
}

extension DownloadListView {

    struct DownloadTaskRow: View {

        @Router
        private var router

        let downloadTask: DownloadTask

        var body: some View {
            Button {
                router.route(to: .downloadTask(downloadTask: downloadTask))
            } label: {
                HStack(alignment: .bottom) {
                    // [Downloads fork] Small, aspect-correct landscape thumbnail.
                    // Upstream's sizing modifier was commented out (it used a
                    // stale `posterStyle` API), so the image filled the whole row.
                    // Try "Backdrop" first: episodes only save that still, movies
                    // save both — so every row shows an intelligible image.
                    ImageView([
                        downloadTask.getImageURL(name: "Backdrop"),
                        downloadTask.getImageURL(name: "Primary"),
                    ])
                    .failure {
                        Color.secondary
                            .opacity(0.8)
                    }
                    .posterStyle(.landscape)
                    .subtleShadow()
                    .frame(width: 110)

                    VStack(alignment: .leading) {
                        Text(downloadTask.item.displayTitle)
                            .foregroundColor(.primary)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical)

                    Spacer()
                }
            }
        }
    }
}
