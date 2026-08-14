//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation

// [Downloads fork]

/// What a download needs from whatever actually moves the bytes.
///
/// This is a protocol, and it is the only part of the transfer layer that lives
/// in `Shared/`, for one narrow reason: `DownloadTask` is in `Shared/` and is
/// therefore compiled for tvOS, while the implementation is iOS-only. Depending
/// on a contract instead of on the implementation is what keeps `#if os(iOS)`
/// out of the base files entirely.
///
/// It also leaves Apple TV downloads as a matter of registering a second
/// implementation rather than a migration — without the folder layout claiming
/// they exist today, because they do not.
///
/// Deliberately says nothing about Jellyfin. A request is a URL, some headers
/// and a destination; the caller is what knows about items and servers. That
/// keeps this file a seam rather than a second copy of the download logic.
protocol MediaTransferring: AnyObject {

    /// Every transfer the layer knows about, keyed by item id, republished on
    /// each change.
    ///
    /// A snapshot rather than a stream of deltas because the layer's state
    /// survives the app being killed: a subscriber that starts late — including
    /// one in an entirely new process — has to be able to learn everything from
    /// the first value it receives.
    var transferStates: AnyPublisher<[String: MediaTransferState], Never> { get }

    /// Queue transfers.
    ///
    /// Plural from the very first version, and that is deliberate. The real unit
    /// of work is a season, not a file — a whole season is the reason background
    /// transfers are being built at all. Writing this as `enqueue(_ request:)`
    /// and adding batches later would mean rewriting the queue, the persistence
    /// and the progress reporting. Today every batch happens to have one element.
    func enqueue(_ requests: [MediaTransferRequest])

    /// Cancel transfers and discard whatever they had already written.
    func cancel(itemIDs: [String])

    /// Current state of one transfer, or `nil` if the layer has never seen it.
    func state(for itemID: String) -> MediaTransferState?
}

// MARK: - MediaTransferRequest

/// One file to move, and where to put it.
struct MediaTransferRequest: Codable, Equatable, Identifiable, Sendable {

    /// The item this media belongs to. Doubles as the identity of the transfer,
    /// because an item has exactly one media file.
    let itemID: String

    /// The batch this belongs to — a season, typically. `nil` for a lone item.
    ///
    /// Carried from the first version so that progress can be reported per batch
    /// ("4 of 12") without the queue having to be reshaped later.
    let groupID: String?

    let remoteURL: URL

    /// Authentication and anything else the server needs.
    ///
    /// Explicit because the transfer no longer goes through the Jellyfin SDK's
    /// client: a background session must be ours, so its headers must be too.
    let headers: [String: String]

    /// Folder the finished file is moved into.
    let destinationFolder: URL

    /// Filename without extension. The extension is not known until the response
    /// arrives, so it is resolved on completion from the MIME subtype.
    let filenameBase: String

    var id: String { itemID }
}

// MARK: - MediaTransferState

/// Where a transfer has got to.
enum MediaTransferState: Codable, Equatable, Sendable {

    case queued
    case transferring(fractionCompleted: Double)

    /// Finished, with the final on-disk location.
    case finished(URL)

    /// Failed, with a message rather than an `Error`.
    ///
    /// This state is written to disk so it can survive the app being killed, and
    /// `Error` is not `Codable`. The message is for the log and the UI; nothing
    /// branches on it.
    case failed(message: String)

    case cancelled

    /// Whether the layer is done with this transfer, one way or another.
    var isTerminal: Bool {
        switch self {
        case .finished, .failed, .cancelled:
            true
        case .queued, .transferring:
            false
        }
    }

    /// Progress in 0...1, or `nil` when there is nothing meaningful to show.
    var fractionCompleted: Double? {
        switch self {
        case let .transferring(fraction):
            fraction
        case .finished:
            1
        case .queued, .failed, .cancelled:
            nil
        }
    }
}
