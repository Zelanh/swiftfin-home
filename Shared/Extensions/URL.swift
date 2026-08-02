//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

extension URL {

    init?(string: String?) {
        guard let string else { return nil }
        self.init(string: string)
    }

    static let swiftfinGithub: URL = URL(string: "https://github.com/jellyfin/Swiftfin")!

    static let swiftfinGithubLicense: URL = URL(string: "https://github.com/jellyfin/Swiftfin/blob/main/LICENSE.md")!

    static let swiftfinGithubIssues: URL = URL(string: "https://github.com/jellyfin/Swiftfin/issues")!

    static let jellyfinDocsDevices: URL = URL(string: "https://jellyfin.org/docs/general/server/devices")!

    static let jellyfinDocsTasks: URL = URL(string: "https://jellyfin.org/docs/general/server/tasks")!

    static let jellyfinDocsUsers: URL = URL(string: "https://jellyfin.org/docs/general/server/users")!

    static let jellyfinDocsTroubleshooting: URL = URL(string: "https://jellyfin.org/docs/general/administration/troubleshooting")!

    static let jellyfinDocsManagingUsers: URL = URL(string: "https://jellyfin.org/docs/general/server/users/adding-managing-users")!

    // [Downloads fork] Our own persistent, private downloads directory, in the
    // app's **Documents** container so it's browsable in the Files app (the iOS
    // target already sets `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).
    // Replaces Apple's `URL.downloadsDirectory` (an unreliable location for
    // app-managed persistent downloads on iOS). Created on first use and excluded
    // from iCloud backup (the media is large and re-downloadable). Downloads that
    // predate this move lived under Application Support and are migrated over on
    // first access.
    static var swiftfinDownloads: URL {
        let fileManager = FileManager.default

        let directory = fileManager
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)

        let existed = fileManager.fileExists(atPath: directory.path)

        Self.migrateLegacyDownloadsIfNeeded(to: directory)

        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if !existed {
            var mutableDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableDirectory.setResourceValues(values)
        }

        return directory
    }

    // [Downloads fork] One-time move of downloads from the previous Application
    // Support location to Documents. Idempotent and best-effort: once the legacy
    // folder is gone (or was never there) this returns immediately.
    private static func migrateLegacyDownloadsIfNeeded(to newDirectory: URL) {
        let fileManager = FileManager.default

        let legacy = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)

        guard fileManager.fileExists(atPath: legacy.path) else { return }

        try? fileManager.createDirectory(at: newDirectory, withIntermediateDirectories: true)

        let contents = (try? fileManager.contentsOfDirectory(atPath: legacy.path)) ?? []
        for name in contents {
            let source = legacy.appendingPathComponent(name)
            let destination = newDirectory.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try? fileManager.moveItem(at: source, to: destination)
        }

        try? fileManager.removeItem(at: legacy)
    }

    func isDirectoryAndReachable() throws -> Bool {
        guard try resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            return false
        }
        return try checkResourceIsReachable()
    }

    func directoryTotalAllocatedSize(includingSubfolders: Bool = false) throws -> Int? {
        guard try isDirectoryAndReachable() else { return nil }

        if includingSubfolders {
            guard let urls = FileManager.default.enumerator(at: self, includingPropertiesForKeys: nil)?.allObjects as? [URL]
            else { return nil }
            return try urls.lazy.reduce(0) {
                try ($1.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0) + $0
            }
        }

        return try FileManager.default.contentsOfDirectory(at: self, includingPropertiesForKeys: nil).lazy.reduce(0) {
            try (
                $1.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    .totalFileAllocatedSize ?? 0
            ) + $0
        }
    }

    // doesn't have `?` but doesn't matter
    var pathAndQuery: String? {
        path + (query ?? "")
    }

    var sizeOnDisk: Int {
        do {
            guard let size = try directoryTotalAllocatedSize(includingSubfolders: true) else { return -1 }
            return size
        } catch {
            return -1
        }
    }

    var components: URLComponents? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)
    }

    var normalizedServerConnectionURL: URL? {
        guard var components else { return nil }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if components.path.isNotEmpty {
            components.path = components.path.trimmingSuffix("/")
        }

        return components.url
    }
}
