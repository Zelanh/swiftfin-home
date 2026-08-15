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

// [Downloads fork]

/// Hands the media file to the background transfer layer, when there is one.
///
/// Lives here rather than in `DownloadTask.swift` so the base file's share of
/// background downloads stays down to a branch and a stored property. It has to
/// be in `Shared/` all the same — `DownloadTask` is compiled for tvOS, so
/// anything it calls must be too — but it only ever speaks in terms of
/// ``MediaTransferring``, which on tvOS resolves to nothing at all.
extension DownloadTask {

    /// Jellyfin's download endpoint. Built by hand rather than through
    /// `Paths.getDownload` because a background session needs a plain
    /// `URLRequest`, and the SDK's request type is meant to be handed to its own
    /// client rather than taken apart.
    private var mediaDownloadPath: String? {
        guard let id = item.id else { return nil }
        return "/Items/\(id)/Download"
    }

    /// Start the media transfer in the background, returning whether it was taken.
    ///
    /// `false` means there is no transfer layer on this platform — or the request
    /// could not be built — and the caller should fall back to downloading in the
    /// foreground, which is what the app did before any of this existed.
    @MainActor
    func beginBackgroundMediaTransfer() -> Bool {

        guard let transferring = Container.shared.mediaTransferring() else { return false }

        guard let itemID = item.id,
              let path = mediaDownloadPath,
              let session = Container.shared.currentUserSession(),
              let url = session.client.url(path: path),
              let destinationFolder = item.downloadMediaFolder
        else { return false }

        let request = MediaTransferRequest(
            itemID: itemID,
            groupID: item.seasonID,
            remoteURL: url,
            headers: Self.authorizationHeaders(for: session),
            destinationFolder: destinationFolder,
            filenameBase: item.downloadMediaBaseName
        )

        observeTransfer(of: itemID, from: transferring)
        transferring.enqueue([request])

        return true
    }

    /// Mirror the transfer layer's view of this item onto ``DownloadTask/state``.
    ///
    /// The transfer outlives this object — and can outlive the whole process — so
    /// this is a view onto the queue rather than the other way round. Whatever the
    /// queue says, happened.
    @MainActor
    private func observeTransfer(of itemID: String, from transferring: any MediaTransferring) {
        transferObservation = transferring.transferStates
            .compactMap { $0[itemID] }
            .removeDuplicates()
            .sink { [weak self] transferState in
                guard let self else { return }

                switch transferState {
                case .queued:
                    state = .downloading(0)
                case let .transferring(fraction):
                    state = .downloading(fraction)
                case .finished:
                    state = .complete
                case let .failed(message):
                    state = .error(DownloadError.transferFailed(message))
                case .cancelled:
                    state = .cancelled
                }
            }
    }

    /// The `Authorization` header the Jellyfin SDK would have sent.
    ///
    /// A background session must be ours, so it does not go through the SDK's
    /// client and does not get the client's delegate to authenticate it. The shape
    /// is Jellyfin's `MediaBrowser` scheme; everything in it comes from the
    /// configuration the client was built with, so the two cannot drift apart
    /// without this failing to compile.
    private static func authorizationHeaders(for session: UserSession) -> [String: String] {
        let configuration = session.client.configuration

        let fields = [
            "DeviceId=\(configuration.deviceID)",
            "Device=\(configuration.deviceName)",
            "Client=\(configuration.client)",
            "Version=\(configuration.version)",
            "Token=\(session.user.accessToken)",
        ]

        return ["Authorization": "MediaBrowser \(fields.joined(separator: ", "))"]
    }
}
