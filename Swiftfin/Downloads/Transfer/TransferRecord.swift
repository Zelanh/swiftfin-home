//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

// [Downloads fork]

/// One row of the transfer queue, as it is written to disk.
///
/// The queue has to survive the app being killed — that is the entire point of a
/// background session — so this is the durable form of a transfer, not the live
/// one. `URLSession` keeps the transfers themselves alive in its own daemon; what
/// it cannot keep is *why* each one exists, where its bytes belong, or how many
/// times it has already been retried. That is what this holds.
struct TransferRecord: Codable, Equatable, Identifiable {

    let request: MediaTransferRequest

    var state: MediaTransferState

    /// How many times this has been started, including the current attempt.
    ///
    /// Counted per record and never per batch: a season where episode 7 fails
    /// must not take the other eleven down with it, and must not consume their
    /// retries either.
    var attempts: Int

    /// When `state` last changed. Written to disk with the rest, so a queue
    /// restored in a new process can tell a transfer that stalled days ago from
    /// one that was progressing a second before the app died.
    var lastChanged: Date

    /// Identity is the item, matching ``MediaTransferRequest/itemID``: an item
    /// has one media file, so it has at most one transfer.
    var id: String { request.itemID }

    init(
        request: MediaTransferRequest,
        state: MediaTransferState = .queued,
        attempts: Int = 0,
        lastChanged: Date = .now
    ) {
        self.request = request
        self.state = state
        self.attempts = attempts
        self.lastChanged = lastChanged
    }

    // MARK: Reattachment
    //
    // Note what is deliberately *not* stored here: `URLSessionTask.taskIdentifier`.
    //
    // It looks like the obvious key for finding our records again after a relaunch,
    // and it is the wrong one — identifiers are only unique within a single session
    // and get reused once a task is gone, so a stale one can match a transfer that
    // has nothing to do with it. Instead each `URLSessionTask` carries the item id
    // in its `taskDescription`, which is ours to set, survives the app dying, and
    // means the same thing forever.

    /// The value to put in `URLSessionTask.taskDescription` so this record can be
    /// found again after a relaunch.
    var taskDescription: String { request.itemID }

    // MARK: Transitions

    /// Whether another attempt is allowed.
    ///
    /// Retries exist for transfers dropped by a flaky network, which is the
    /// common case on a phone. They are not a way to keep hammering a server that
    /// is answering "no" — hence a low ceiling.
    var canRetry: Bool {
        guard case .failed = state else { return false }
        return attempts < Self.maximumAttempts
    }

    static let maximumAttempts = 3

    mutating func update(_ newState: MediaTransferState) {
        state = newState
        lastChanged = .now
    }

    mutating func markStarted() {
        attempts += 1
        update(.transferring(fractionCompleted: 0))
    }
}
