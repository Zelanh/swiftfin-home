//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import Files
import Foundation
import JellyfinAPI
import Logging

extension Container {
    var downloadManager: Factory<DownloadManager> {
        self { DownloadManager() }.shared
    }
}

class DownloadManager: ObservableObject {

    private let logger = Logger.swiftfin()

    @Published
    private(set) var downloads: [DownloadTask] = []

    func clearTmp() {
        do {
            try Folder(path: URL.temporaryDirectory.path).files.delete()

            logger.trace("Cleared tmp directory")
        } catch {
            logger.error("Unable to clear tmp directory: \(error.localizedDescription)")
        }
    }

    // [Downloads fork] Every lookup below matches on `item.id`, never on the item
    // itself. A `BaseItemDto` carries userData — favourite, played, playback
    // position — which the server refreshes and playback mutates, so two values
    // describing the same item routinely compare unequal. `task(for:)` already
    // worked this way; the three below did not, and that is what left completed
    // and deleted tasks stranded in `downloads`.

    func download(task: DownloadTask) {
        guard !downloads.contains(where: { $0.item.id == task.item.id }) else { return }

        downloads.append(task)

        task.download()
    }

    func task(for item: BaseItemDto) -> DownloadTask? {
        // [Downloads fork] Match in-flight downloads by id (userData like Favorite
        // mutates the item, which would otherwise unmatch a full-equality check).
        if let currentlyDownloading = downloads.first(where: { $0.item.id == item.id }) {
            return currentlyDownloading
        }

        // [Downloads fork] On disk, "downloaded" means the media file is actually
        // present — not just the metadata (the user can delete media from Files).
        guard let id = item.id, let task = parseDownloadItem(with: id) else { return nil }

        guard task.getMediaURL() != nil else {
            task.deleteRootFolder() // stale metadata with no media → clean up
            return nil
        }

        return task
    }

    func cancel(task: DownloadTask) {
        guard downloads.contains(where: { $0.item.id == task.item.id }) else { return }

        task.cancel()

        remove(task: task)
    }

    /// Drop a task from the in-flight list.
    ///
    /// Safe to call with a task parsed from disk rather than the live one — which
    /// is exactly what deleting a finished download does — because the match is
    /// by id.
    func remove(task: DownloadTask) {
        downloads.removeAll(where: { $0.item.id == task.item.id })
    }

    // [Downloads fork] Called from `DownloadTask`'s error paths (download failure /
    // invalidated session) to recover the manager: drop any task that ended in
    // error or was cancelled — otherwise the `guard !downloads.contains` in
    // `download(task:)` would block re-downloading the same item — and clear the
    // temp directory of the partial file.
    func reset() {
        downloads.removeAll { task in
            switch task.state {
            case .error, .cancelled:
                return true
            default:
                return false
            }
        }

        clearTmp()
    }

    func downloadedItems() -> [DownloadTask] {
        migrateToSplitStorageIfNeeded()

        // [Downloads fork] Downloads are identified by their metadata folders in the
        // private root. The media in Documents can be deleted by the user (Files /
        // iPhone Storage), so reconcile: drop — and clean up the stale metadata of —
        // any download whose media file is gone.
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: URL.swiftfinDownloadsMetadata.path) else {
            return []
        }

        // [Downloads fork] "No media file" no longer means "abandoned". Metadata is
        // now written before the media is fetched, and a background transfer can
        // take minutes, so between those two points a perfectly healthy download
        // looks exactly like a deleted one. Deleting it here destroyed the very
        // `Item.json` the finished transfer needed to become visible.
        let pendingTransfers = Container.shared.mediaTransferring()?.pendingTransferIDs ?? []

        return ids.compactMap { id in
            guard let task = parseDownloadItem(with: id) else { return nil }
            guard task.getMediaURL() != nil else {
                // Still garbage-collect genuinely abandoned metadata — media
                // deleted from Files or iPhone Storage, with nothing on its way.
                if !pendingTransfers.contains(id) {
                    task.deleteRootFolder()
                }
                return nil
            }
            return task
        }
    }

    private func parseDownloadItem(with id: String) -> DownloadTask? {
        // [Downloads fork] Metadata lives in the private Application Support root.
        let itemMetadataFile = URL.swiftfinDownloadsMetadata
            .appendingPathComponent(id)
            .appendingPathComponent("Metadata")
            .appendingPathComponent("Item.json")

        guard let itemMetadataData = FileManager.default.contents(atPath: itemMetadataFile.path) else { return nil }

        guard let offlineItem = try? JSONDecoder().decode(BaseItemDto.self, from: itemMetadataData) else { return nil }

        let task = DownloadTask(item: offlineItem)
        task.state = .complete
        return task
    }

    // [Downloads fork] One-time migration from the old single-folder layout
    // (Documents/Downloads/<id>/{Media.<ext>, Images/, Metadata/}) to the split
    // layout: the media stays in Documents renamed to "<Title>.<ext>", and the
    // tripas (Item.json + artwork) move to the private Application Support root.
    // Idempotent — a folder without a "Metadata" subfolder is already migrated —
    // and best-effort. A folder with no decodable Item.json is left untouched.
    private func migrateToSplitStorageIfNeeded() {
        let fileManager = FileManager.default
        let mediaRoot = URL.swiftfinDownloads
        let metadataRoot = URL.swiftfinDownloadsMetadata

        guard let entries = try? fileManager.contentsOfDirectory(atPath: mediaRoot.path) else { return }

        for id in entries {
            let itemFolder = mediaRoot.appendingPathComponent(id)

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: itemFolder.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }

            let oldMetadataFolder = itemFolder.appendingPathComponent("Metadata")
            guard fileManager.fileExists(atPath: oldMetadataFolder.path) else { continue }

            guard let data = fileManager.contents(atPath: oldMetadataFolder.appendingPathComponent("Item.json").path),
                  let item = try? JSONDecoder().decode(BaseItemDto.self, from: data)
            else { continue }

            // 1. Rename the media file in place to "<Title>.<ext>". The media file
            // is the only entry that isn't one of the known subfolders (note that
            // "Metadata" also starts with "Media", so a prefix match is unsafe).
            if let contents = try? fileManager.contentsOfDirectory(atPath: itemFolder.path),
               let mediaName = contents.first(where: { $0 != "Metadata" && $0 != "Images" && !$0.hasPrefix(".") })
            {
                let fileExtension = (mediaName as NSString).pathExtension
                let newName = fileExtension.isEmpty
                    ? item.downloadMediaBaseName
                    : "\(item.downloadMediaBaseName).\(fileExtension)"
                let destination = itemFolder.appendingPathComponent(newName)

                if newName != mediaName, !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.moveItem(at: itemFolder.appendingPathComponent(mediaName), to: destination)
                }
            }

            // 2. Move the tripas to the private metadata root.
            let newMetadataFolder = metadataRoot.appendingPathComponent(id)
            try? fileManager.createDirectory(at: newMetadataFolder, withIntermediateDirectories: true)

            for subfolder in ["Metadata", "Images"] {
                let source = itemFolder.appendingPathComponent(subfolder)
                let destination = newMetadataFolder.appendingPathComponent(subfolder)
                guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path)
                else { continue }
                try? fileManager.moveItem(at: source, to: destination)
            }
        }
    }
}
