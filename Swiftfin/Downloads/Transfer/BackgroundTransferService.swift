//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import Logging

// [Downloads fork]

/// Moves media files with a background `URLSession`, so a season keeps arriving
/// while the phone is in a pocket.
///
/// The session belongs to the system, not to this object. Transfers outlive the
/// app: they continue while it is suspended, and they can finish after it has
/// been killed outright, at which point iOS relaunches it just to deliver the
/// news. That single fact is why none of this could be an `async` function —
/// there is no `await` left to return to in a process that did not exist when the
/// download started.
///
/// **Isolation is split deliberately, and the split is load-bearing.** The type
/// is not `@MainActor` as a whole because `URLSession` calls its delegate on its
/// own queue. The `MediaTransferring` surface and every touch of ``TransferQueue``
/// are main-actor; the delegate callbacks are `nonisolated` and do the least
/// possible before hopping. See ``urlSession(_:downloadTask:didFinishDownloadingTo:)``
/// for the one place where hopping first would lose the file.
final class BackgroundTransferService: NSObject {

    /// Must never change: on relaunch, this string is how the system hands back
    /// transfers started by a previous life of the app. A new identifier means a
    /// new, empty session, and the old transfers become unreachable — still
    /// running, still writing, with nobody listening.
    static let sessionIdentifier = "org.jellyfin.swiftfin.downloads.background"

    private let logger = Logger.swiftfin()

    @MainActor
    private let queue: TransferQueue

    @MainActor
    private let statesSubject = CurrentValueSubject<[String: MediaTransferState], Never>([:])

    private var cancellables = Set<AnyCancellable>()

    /// Handed over by the app delegate when iOS wakes the app to report that a
    /// background session has events to deliver, and called once they are all in.
    ///
    /// Not optional politeness: the system gives the app a short window to finish
    /// up, and failing to call this is how an app gets counted as unresponsive.
    @MainActor
    var backgroundCompletionHandler: (() -> Void)?

    /// Where a finished file is parked before it is filed away properly.
    ///
    /// See ``urlSession(_:downloadTask:didFinishDownloadingTo:)`` — this exists so
    /// the delegate can rescue the file without needing to know its destination.
    private static var stagingDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)

        // Not discretionary: somebody pressed download and is watching a progress
        // bar. Letting iOS defer these to a convenient moment is right for a
        // prefetch and wrong for a request — it would look like nothing happened.
        configuration.isDiscretionary = false

        // Ask the system to relaunch the app when everything is done, rather than
        // waiting for somebody to open it.
        configuration.sessionSendsLaunchEvents = true

        // The delegate queue is the main queue on purpose: it puts the callbacks
        // where the queue's `@Published` updates have to happen anyway, and there
        // is nothing here heavy enough to deserve a thread of its own. The file
        // move in `didFinishDownloadingTo` is a rename within the app container.
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    /// The queue is passed in, and has no default value.
    ///
    /// It began as `init(queue: TransferQueue = TransferQueue())`, which does not
    /// compile. A default argument expression is evaluated at the call site in a
    /// nonisolated context and does *not* inherit the isolation of the initializer
    /// it belongs to, however that initializer is annotated — so the main-actor
    /// `TransferQueue()` is unreachable from there.
    ///
    /// The caller builds it instead. That works because a stored property's
    /// initial value *is* evaluated in the isolation of its enclosing type, and
    /// the only caller is a `@MainActor` app delegate.
    @MainActor
    init(queue: TransferQueue) {
        self.queue = queue
        super.init()

        queue.$records
            .map { records in
                records.reduce(into: [String: MediaTransferState]()) { result, record in
                    result[record.id] = record.state
                }
            }
            .sink { [weak self] states in
                self?.statesSubject.send(states)
            }
            .store(in: &cancellables)

        createStagingDirectoryIfNeeded()
    }

    // MARK: Relaunch

    /// Reconnect the queue to transfers that outlived the last run.
    ///
    /// Call once at startup. Creating the session with the same identifier is what
    /// adopts the running transfers; this then reconciles what the system says is
    /// in flight against what was written down, in both directions:
    ///
    /// - a task the system is still running gets its record marked as transferring
    ///   again, because the record may have been saved as merely queued
    /// - a record that thinks it is transferring but has no task behind it is put
    ///   back in the queue, because the transfer died with the process
    ///
    /// Matching is by `taskDescription`, never by `taskIdentifier` — see the note
    /// in ``TransferRecord``.
    @MainActor
    func reattach() {
        // `getAllTasks` rather than the `allTasks` async property: this codebase
        // has no precedent for the latter, and a background session's inventory
        // is not worth an API that cannot be checked against anything here.
        session.getAllTasks { [weak self] tasks in
            let liveIDs = Set(tasks.compactMap(\.taskDescription))

            Task { @MainActor in
                self?.reconcile(againstLiveTransfers: liveIDs)
            }
        }
    }

    @MainActor
    private func reconcile(againstLiveTransfers liveIDs: Set<String>) {
        for record in queue.records {
            switch record.state {
            case .transferring where !liveIDs.contains(record.id):
                logger.notice("Transfer for \(record.id) did not survive relaunch — requeueing")
                queue.markFailed(record.id, message: "Interrupted by app termination")

            case .queued where liveIDs.contains(record.id):
                // Started before, never recorded as such: adopt it rather than
                // start a second transfer for the same file.
                queue.markStarted(record.id)

            default:
                break
            }
        }

        startPendingTransfers()
    }

    // MARK: Starting work

    /// Start as many queued transfers as the concurrency limit allows.
    @MainActor
    private func startPendingTransfers() {
        for record in queue.recordsAwaitingStart() {
            start(record)
        }
    }

    @MainActor
    private func start(_ record: TransferRecord) {
        var request = URLRequest(url: record.request.remoteURL)

        for (field, value) in record.request.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let task = session.downloadTask(with: request)

        // The only durable link between a system task and our bookkeeping.
        task.taskDescription = record.taskDescription

        queue.markStarted(record.id)
        task.resume()

        logger.notice("Started transfer for \(record.id), attempt \(record.attempts + 1)")
    }

    // MARK: Filing a finished download

    /// Move a rescued file to where it actually belongs.
    ///
    /// Runs on the main actor, after the delegate has already saved the file from
    /// deletion by parking it in staging.
    @MainActor
    private func fileStagedDownload(for itemID: String, mimeSubtype: String?) {
        guard let record = queue.record(for: itemID) else {
            logger.error("Finished transfer for \(itemID) has no record — discarding")
            try? FileManager.default.removeItem(at: Self.stagingURL(for: itemID))
            return
        }

        let staged = Self.stagingURL(for: itemID)
        let folder = record.request.destinationFolder
        let filename = mimeSubtype.map { "\(record.request.filenameBase).\($0)" }
            ?? record.request.filenameBase
        let destination = folder.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            // A retry can find the previous attempt's remains in place.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }

            try FileManager.default.moveItem(at: staged, to: destination)

            queue.markFinished(itemID, at: destination)
            logger.notice("Filed transfer for \(itemID)")
        } catch {
            logger.error("Unable to file transfer for \(itemID): \(error.localizedDescription)")
            queue.markFailed(itemID, message: error.localizedDescription)
        }

        startPendingTransfers()
    }

    private static func stagingURL(for itemID: String) -> URL {
        stagingDirectory.appendingPathComponent(itemID)
    }

    private func createStagingDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(
            at: Self.stagingDirectory,
            withIntermediateDirectories: true
        )
    }
}

// MARK: - MediaTransferring

extension BackgroundTransferService: MediaTransferring {

    var transferStates: AnyPublisher<[String: MediaTransferState], Never> {
        statesSubject.eraseToAnyPublisher()
    }

    func enqueue(_ requests: [MediaTransferRequest]) {
        queue.enqueue(requests)
        startPendingTransfers()
    }

    func cancel(itemIDs: [String]) {
        let cancelling = Set(itemIDs)

        // Cancel the records first so nothing restarts them in the window between
        // asking the session to stop and the session getting round to it.
        queue.cancel(itemIDs: itemIDs)

        session.getAllTasks { [weak self] tasks in
            for task in tasks {
                guard let id = task.taskDescription, cancelling.contains(id) else { continue }
                task.cancel()
            }

            Task { @MainActor in
                for id in itemIDs {
                    try? FileManager.default.removeItem(at: Self.stagingURL(for: id))
                }

                self?.startPendingTransfers()
            }
        }
    }

    func state(for itemID: String) -> MediaTransferState? {
        queue.state(for: itemID)
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundTransferService: URLSessionDownloadDelegate {

    /// Rescue the finished file, then do the bookkeeping.
    ///
    /// **The move has to happen before this function returns.** `location` points
    /// into a temporary directory that `URLSession` deletes the moment the
    /// delegate hands control back, so hopping to the main actor first — the
    /// pattern every other callback here uses — would reliably lose a file that
    /// had already been fully downloaded.
    ///
    /// Hence staging. The destination lives in a record on the main actor and
    /// cannot be read from here, but `taskDescription` gives the item id
    /// synchronously, and that is enough to park the file under a name we can
    /// find again a moment later.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let itemID = downloadTask.taskDescription else { return }

        let staged = Self.stagingURL(for: itemID)

        // `mimeSubtype` is Swiftfin's own extension on `URLResponse`, so no cast
        // to `HTTPURLResponse` is needed to reach it.
        let mimeSubtype = downloadTask.response?.mimeSubtype

        do {
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            Task { @MainActor in
                self.logger.error("Unable to stage finished transfer \(itemID): \(error.localizedDescription)")
                self.queue.markFailed(itemID, message: error.localizedDescription)
                self.startPendingTransfers()
            }
            return
        }

        Task { @MainActor in
            self.fileStagedDownload(for: itemID, mimeSubtype: mimeSubtype)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let itemID = downloadTask.taskDescription else { return }

        // A server that does not send a length reports -1 here. Publishing
        // `totalBytesWritten / -1` would drive the progress bar backwards.
        guard totalBytesExpectedToWrite > 0 else { return }

        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)

        Task { @MainActor in
            self.queue.updateProgress(itemID, fraction: fraction)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Success arrives through `didFinishDownloadingTo`; this only has to deal
        // with the unhappy path.
        guard let error, let itemID = task.taskDescription else { return }

        // A cancellation is something we asked for, and the record already says so.
        if (error as NSError).code == NSURLErrorCancelled { return }

        Task { @MainActor in
            self.logger.error("Transfer for \(itemID) failed: \(error.localizedDescription)")
            self.queue.markFailed(itemID, message: error.localizedDescription)
            self.startPendingTransfers()
        }
    }

    /// Every event from this session has been delivered.
    ///
    /// Calling the stored handler is what tells iOS the app is done and its
    /// snapshot can be taken. Skipping it gets the app treated as unresponsive.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
