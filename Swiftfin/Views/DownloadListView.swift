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
        .toolbarTitleDisplayMode(.inline)
    }
}

extension DownloadListView {

    struct DownloadTaskRow: View {

        @Router
        private var router

        let downloadTask: DownloadTask

        // [Downloads fork] On-disk size of this download, computed once on appear.
        @State
        private var sizeText: String?

        var body: some View {
            Button {
                router.route(to: .downloadTask(downloadTask: downloadTask))
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    // [Downloads fork] Small landscape thumbnail at a FIXED size so
                    // every row's image is identical (some artwork is 16:9, some
                    // 4:3 or portrait — a width-only frame let them differ in
                    // height). Fill + clip to 110×62 crops each to the same box.
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
                    .aspectRatio(1.77, contentMode: .fill)
                    .frame(width: 110, height: 62)
                    .clipped()
                    .cornerRadius(6)
                    .subtleShadow()

                    VStack(alignment: .leading, spacing: 4) {
                        Text(downloadTask.item.displayTitle)
                            .foregroundColor(.primary)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)

                        // [Downloads fork] On-disk size of the download.
                        if let sizeText {
                            Text(sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical)

                    Spacer()
                }
            }
            .onAppear(perform: computeSize)
        }

        // [Downloads fork] Compute the on-disk size once, off the render path.
        private func computeSize() {
            guard sizeText == nil else { return }
            // [Downloads fork] Size of the media file (the metadata folder is tiny now).
            let bytes = downloadTask.item.downloadMediaFolder?.sizeOnDisk ?? -1
            guard bytes > 0 else { return }
            sizeText = Int64(bytes).formatted(.byteCount(style: .file))
        }
    }
}
