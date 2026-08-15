//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import FactoryKit
import Files
import Foundation
import Get
import JellyfinAPI
import Logging

// TODO: Only move items if entire download successful
// TODO: Better state for which stage of downloading

class DownloadTask: NSObject, ObservableObject {

    enum DownloadError: Error {

        case notEnoughStorage

        // [Downloads fork] A background transfer reports failure as a message
        // rather than an `Error`, because its state is written to disk.
        case transferFailed(String)

        var localizedDescription: String {
            switch self {
            case .notEnoughStorage:
                "Not enough storage"
            case let .transferFailed(message):
                message
            }
        }
    }

    enum State {

        case cancelled
        case complete
        case downloading(Double)
        case error(Error)
        case ready
    }

    private let logger = Logger.swiftfin()
    @Injected(\.currentUserSession)
    private var userSession: UserSession?

    @Published
    var state: State = .ready

    private var downloadTask: Task<Void, Never>?

    // [Downloads fork] Kept alive while a background transfer mirrors its state
    // onto this task. Not `private`: the subscription is set up in
    // `DownloadTask+MediaTransfer.swift`, and Swift's `private` does not reach
    // across files.
    var transferObservation: AnyCancellable?

    let item: BaseItemDto

    var imagesFolder: URL? {
        item.downloadFolder?.appendingPathComponent("Images")
    }

    var metadataFolder: URL? {
        item.downloadFolder?.appendingPathComponent("Metadata")
    }

    init(item: BaseItemDto) {
        self.item = item
    }

    func createFolder() throws {
        guard let downloadFolder = item.downloadFolder else { return }
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
    }

    func download() {

        let task = Task {

            deleteRootFolder()

            // [Downloads fork] Metadata is written *first* now, where it used to
            // come last. A background transfer can finish with this process dead,
            // and `saveMetadata()` would then never run — leaving a multi-gigabyte
            // file on disk with no `Item.json` beside it. That is the one file
            // `parseDownloadItem` needs to list a download, so the media would be
            // invisible in the app and undeletable from it.
            //
            // Writing it up front costs nothing and means whatever survives a kill
            // is always interpretable. The artwork follows, being small and quick.
            saveMetadata()

            await downloadBackdropImage()
            await downloadPrimaryImage()

            // [Downloads fork] Hand the media itself to the background transfer
            // layer where one exists. It reports progress and completion by
            // driving `state` from its own queue, so there is nothing to await
            // and nothing more to do here.
            let handedOff = await MainActor.run { beginBackgroundMediaTransfer() }
            if handedOff { return }

            // Foreground fallback — the original path, still used anywhere no
            // transfer layer is registered.
            do {
                try await downloadMedia()
            } catch {
                await MainActor.run {
                    self.state = .error(error)

                    Container.shared.downloadManager.reset()
                }
                return
            }

            await MainActor.run {
                self.state = .complete
            }
        }

        self.downloadTask = task
    }

    func cancel() {
        self.downloadTask?.cancel()
        self.state = .cancelled

        logger.trace("Cancelled download for: \(item.displayTitle)")
    }

    func deleteRootFolder() {
        // [Downloads fork] Remove both halves of the download: the media file in
        // Documents and the "tripas" (Item.json + artwork) in Application Support.
        if let mediaFolder = item.downloadMediaFolder {
            try? FileManager.default.removeItem(at: mediaFolder)
        }
        if let downloadFolder = item.downloadFolder {
            try? FileManager.default.removeItem(at: downloadFolder)
        }
    }

    func encodeMetadata() -> Data {
        try! JSONEncoder().encode(item)
    }

    private func downloadMedia() async throws {

        guard let userSession else { throw UserSessionError.missingCurrentSession }
        // [Downloads fork] Media goes to Documents/<id>/<Title>.<ext> — user-visible
        // and named — not next to the metadata.
        guard let mediaFolder = item.downloadMediaFolder, let itemID = item.id else { return }

        let request = Paths.getDownload(itemID: itemID)
        let response = try await userSession.client.download(for: request, delegate: self)

        let subtype = response.response.mimeSubtype
        let mediaExtension = subtype == nil ? "" : ".\(subtype!)"
        let mediaFilename = "\(item.downloadMediaBaseName)\(mediaExtension)"

        do {
            try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)

            try FileManager.default.moveItem(
                at: response.value,
                to: mediaFolder.appendingPathComponent(mediaFilename)
            )
        } catch {
            logger.error("Error downloading media for: \(item.displayTitle) with error: \(error.localizedDescription)")
            // [Downloads fork] surface the failure instead of silently "completing"
            // with no media file on disk (was the cause of play/delete doing nothing).
            throw error
        }
    }

    private func downloadBackdropImage() async {

        guard let userSession else { return }
        guard let type = item.type else { return }

        let imageURL: URL

        // TODO: move to BaseItemDto
        switch type {
        case .movie, .series:
            guard let url = item.imageSource(.backdrop, environment: ImageSourceOptions(maxWidth: 600)).url else { return }
            imageURL = url
        case .episode:
            guard let url = item.imageSource(.primary, environment: ImageSourceOptions(maxWidth: 600)).url else { return }
            imageURL = url
        default:
            return
        }

        guard let response = try? await userSession.client.download(
            for: .init(url: imageURL).withResponse(URL.self),
            delegate: self
        ) else { return }

        let filename = getImageFilename(from: response, secondary: "Backdrop")
        saveImage(from: response, filename: filename)
    }

    private func downloadPrimaryImage() async {

        guard let userSession else { return }
        guard let type = item.type else { return }

        let imageURL: URL

        switch type {
        case .movie, .series:
            guard let url = item.imageSource(.primary, environment: ImageSourceOptions(maxWidth: 300)).url else { return }
            imageURL = url
        default:
            return
        }

        guard let response = try? await userSession.client.download(
            for: .init(url: imageURL).withResponse(URL.self),
            delegate: self
        ) else { return }

        let filename = getImageFilename(from: response, secondary: "Primary")
        saveImage(from: response, filename: filename)
    }

    private func saveImage(from response: Response<URL>?, filename: String) {

        guard let response, let imagesFolder else { return }

        do {
            try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

            try FileManager.default.moveItem(
                at: response.value,
                to: imagesFolder.appendingPathComponent(filename)
            )
        } catch {
            logger.error("Error saving image: \(error.localizedDescription)")
        }
    }

    private func getImageFilename(from response: Response<URL>, secondary: String) -> String {

        if let suggestedFilename = response.response.suggestedFilename {
            return suggestedFilename
        } else {
            let imageExtension = response.response.mimeSubtype ?? "png"
            return "\(secondary).\(imageExtension)"
        }
    }

    private func saveMetadata() {
        guard let metadataFolder else { return }

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = .prettyPrinted

        let itemJsonData = try! jsonEncoder.encode(item)
        let itemJson = String(data: itemJsonData, encoding: .utf8)
        let itemFileURL = metadataFolder.appendingPathComponent("Item.json")

        do {
            try FileManager.default.createDirectory(at: metadataFolder, withIntermediateDirectories: true)

            try itemJson?.write(to: itemFileURL, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Error saving item metadata: \(error.localizedDescription)")
        }
    }

    func getImageURL(name: String) -> URL? {
        do {
            guard let imagesFolder else { return nil }
            let images = try FileManager.default.contentsOfDirectory(atPath: imagesFolder.path)

            guard let imageFilename = images.first(where: { $0.starts(with: name) }) else { return nil }

            return imagesFolder.appendingPathComponent(imageFilename)
        } catch {
            return nil
        }
    }

    func getMediaURL() -> URL? {
        // [Downloads fork] The media is the single title-named file in the Documents
        // media folder; skip hidden files (e.g. .DS_Store). Returns nil if the user
        // deleted the media from the Files app / iPhone Storage.
        guard let mediaFolder = item.downloadMediaFolder,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: mediaFolder.path),
              let mediaFilename = contents.first(where: { !$0.hasPrefix(".") })
        else { return nil }

        return mediaFolder.appendingPathComponent(mediaFilename)
    }
}

// MARK: URLSessionDownloadDelegate

extension DownloadTask: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        DispatchQueue.main.async {
            self.state = .downloading(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard let error else { return }

        DispatchQueue.main.async {
            self.state = .error(error)

            Container.shared.downloadManager.reset()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        DispatchQueue.main.async {
            self.state = .error(error)

            Container.shared.downloadManager.reset()
        }
    }
}

extension DownloadTask: Identifiable {

    var id: String {
        item.id!
    }
}
