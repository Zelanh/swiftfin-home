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

/// The bookkeeping half of background transfers: what has been asked for, what is
/// running, what is next.
///
/// Deliberately owns no `URLSession` and starts nothing itself. It decides *what
/// should* be running and records what happened; ``BackgroundTransferService``
/// does the plumbing. Keeping the decisions away from the `URLSession` glue is
/// what makes the ordering, the concurrency limit and the retry policy readable
/// in one place instead of scattered through delegate callbacks.
///
/// `@MainActor` throughout, and that is a choice rather than an accident: the
/// session's delegate queue is set to the main queue, so every callback arrives
/// here already on the main actor, and the `@Published` updates SwiftUI needs
/// happen where SwiftUI needs them. Transfers are a handful of events per second
/// at worst — there is nothing here worth a second thread.
@MainActor
final class TransferQueue: ObservableObject {

    /// How many transfers run at once.
    ///
    /// Twelve episodes at once would saturate the connection and give every one
    /// of them a worse chance of finishing before the network changes. Two keeps
    /// the pipe busy while leaving the first item to finish soon — which matters,
    /// because the first episode of a season is the one somebody wants to watch
    /// while the rest arrive.
    static let maximumConcurrentTransfers = 2

    @Published
    private(set) var records: [TransferRecord] = []

    private let store: TransferStore

    init(store: TransferStore = TransferStore()) {
        self.store = store
        records = store.load()
    }

    // MARK: Reading

    var states: [String: MediaTransferState] {
        records.reduce(into: [:]) { result, record in
            result[record.id] = record.state
        }
    }

    func state(for itemID: String) -> MediaTransferState? {
        records.first { $0.id == itemID }?.state
    }

    func record(for itemID: String) -> TransferRecord? {
        records.first { $0.id == itemID }
    }

    /// Transfers that should be started now, in order, respecting the limit.
    ///
    /// First come, first served, which for a season means episode order — so the
    /// one somebody is most likely to watch first is also the one that finishes
    /// first.
    func recordsAwaitingStart() -> [TransferRecord] {
        // Explicit `where:` label rather than a trailing closure: `count` is also
        // a property on Collection, and the labelled form is what the rest of the
        // codebase uses.
        let running = records.count(where: { record in
            if case .transferring = record.state { return true }
            return false
        })

        let capacity = Self.maximumConcurrentTransfers - running
        guard capacity > 0 else { return [] }

        return records
            .filter { $0.state == .queued }
            .prefix(capacity)
            .map { $0 }
    }

    // MARK: Writing

    /// Add transfers, ignoring any item already known.
    ///
    /// Takes an array because a season is the real unit of work; see
    /// ``MediaTransferring/enqueue(_:)``.
    func enqueue(_ requests: [MediaTransferRequest]) {
        // A finished, failed or cancelled record is history, not a claim on the
        // item. Clear those out of the way before deduplicating, or asking for the
        // same item a second time is swallowed silently and no transfer ever
        // starts — which looks, from the app, like a download that ticks green and
        // does nothing. In-flight records are left alone, so asking twice while a
        // transfer is running is still the no-op it should be.
        let requested = Set(requests.map(\.itemID))
        records.removeAll { requested.contains($0.id) && $0.state.isTerminal }

        let known = Set(records.map(\.id))
        let new = requests
            .filter { !known.contains($0.itemID) }
            .map { TransferRecord(request: $0) }

        guard new.isNotEmpty else { return }

        records.append(contentsOf: new)
        persist()
    }

    func markStarted(_ itemID: String) {
        mutate(itemID) { $0.markStarted() }
    }

    /// Progress is held in memory and **not** written to disk.
    ///
    /// It arrives many times a second, and it is the one piece of state that does
    /// not need saving: the system keeps the transfer alive across app death, so
    /// a relaunch reads real progress back off the session rather than trusting a
    /// number frozen at the moment the app was killed.
    func updateProgress(_ itemID: String, fraction: Double) {
        guard let index = records.firstIndex(where: { $0.id == itemID }) else { return }
        records[index].update(.transferring(fractionCompleted: fraction))
    }

    func markFinished(_ itemID: String, at location: URL) {
        mutate(itemID) { $0.update(.finished(location)) }
    }

    /// Record a failure, and decide whether it is the last word.
    ///
    /// The retry decision lives here rather than in the caller so that "failed"
    /// means the same thing everywhere: a record put back to `.queued` will be
    /// picked up by the next call to ``recordsAwaitingStart()``, and one left as
    /// `.failed` will not. A phone loses its network constantly; most failures
    /// deserve another go, and a server that keeps saying no does not.
    func markFailed(_ itemID: String, message: String) {
        mutate(itemID) { record in
            record.update(.failed(message: message))

            if record.canRetry {
                record.update(.queued)
            }
        }
    }

    func cancel(itemIDs: [String]) {
        let cancelling = Set(itemIDs)
        guard records.contains(where: { cancelling.contains($0.id) }) else { return }

        for index in records.indices where cancelling.contains(records[index].id) {
            records[index].update(.cancelled)
        }

        persist()
    }

    /// Drop records the layer is finished with, so the queue does not grow without
    /// bound.
    ///
    /// Not automatic on completion: whoever asked for the transfer needs a chance
    /// to see that it finished and to move the file where it belongs first.
    func removeTerminal(_ itemIDs: [String]) {
        let removing = Set(itemIDs)
        let before = records.count

        records.removeAll { removing.contains($0.id) && $0.state.isTerminal }

        guard records.count != before else { return }

        if records.isEmpty {
            store.clear()
        } else {
            persist()
        }
    }

    // MARK: Internals

    /// Apply a change and write it down.
    ///
    /// Every transition except progress goes through here, which is what keeps the
    /// "persist on transitions, not on ticks" rule in one place instead of relying
    /// on each call site to remember it.
    private func mutate(_ itemID: String, _ change: (inout TransferRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == itemID }) else { return }

        change(&records[index])
        persist()
    }

    private func persist() {
        store.save(records)
    }
}
