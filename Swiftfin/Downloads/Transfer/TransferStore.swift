//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging

// [Downloads fork]

/// Where the transfer queue lives between app launches.
///
/// A background transfer can finish — or fail — while the app is not running, and
/// `URLSession` will happily hand the result to a process that has forgotten why
/// it asked. This file is that memory.
///
/// **Progress is deliberately not persisted.** Saving on every progress callback
/// would mean writing JSON several times a second, and it would buy nothing: the
/// system keeps the transfer itself alive, so a relaunch re-reads real progress
/// from the session. Only transitions that cannot be recovered any other way —
/// queued, started, finished, failed, cancelled — are written.
final class TransferStore {

    private let logger = Logger.swiftfin()

    /// Bumped whenever the on-disk shape changes.
    ///
    /// This file outlives app versions, so a reader from the future will meet
    /// records written by the past. Versioning it costs one integer and turns an
    /// unreadable queue from a crash into a decision.
    private static let currentVersion = 1

    private struct Envelope: Codable {
        let version: Int
        let records: [TransferRecord]
    }

    private let fileURL: URL

    /// Kept out of the downloads metadata root on purpose.
    ///
    /// `DownloadManager.downloadedItems()` lists that directory and treats every
    /// entry as an item id. A queue file sitting there would be parsed as one —
    /// harmlessly, since it fails to decode and is dropped, but only by accident.
    /// Its own directory means the two never have to know about each other.
    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers", isDirectory: true)

        fileURL = root.appendingPathComponent("queue.json")

        createDirectoryIfNeeded(root)
    }

    // MARK: Reading

    /// The queue as last written, or empty if there is nothing readable.
    ///
    /// Never throws. A queue that cannot be read is a queue that has to be
    /// abandoned — there is no useful way for the app to refuse to start because
    /// a JSON file went bad — so every failure path logs and returns empty.
    func load() -> [TransferRecord] {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return []
        }

        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)

            guard envelope.version == Self.currentVersion else {
                logger.warning(
                    "Transfer queue written by version \(envelope.version), expected \(Self.currentVersion) — discarding"
                )
                return []
            }

            return envelope.records
        } catch {
            logger.error("Unable to read transfer queue: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: Writing

    /// Replace the stored queue.
    ///
    /// Written atomically, which matters more here than in most places: the app
    /// can be killed at any moment, and a half-written queue would be
    /// indistinguishable from a corrupt one on the next launch. `.atomic` writes
    /// to a temporary file and renames, so a reader sees either the old queue or
    /// the new one and never a torn mixture of both.
    func save(_ records: [TransferRecord]) {
        let envelope = Envelope(version: Self.currentVersion, records: records)

        do {
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Unable to write transfer queue: \(error.localizedDescription)")
        }
    }

    /// Forget everything. Used when the queue is emptied rather than updated.
    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Directory

    private func createDirectoryIfNeeded(_ directory: URL) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            // Excluded from iCloud backup deliberately. A queue restored onto a
            // different device would describe transfers that device never started
            // and files it does not have — worse than starting empty.
            var directory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            logger.error("Unable to create transfers directory: \(error.localizedDescription)")
        }
    }
}
