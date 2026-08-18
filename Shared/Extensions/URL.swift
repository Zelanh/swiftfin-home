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

    static let jellyfinDocsBackup: URL = URL(string: "https://jellyfin.org/docs/general/administration/backup-and-restore/")!

    static let jellyfinDocsDevices: URL = URL(string: "https://jellyfin.org/docs/general/server/devices")!

    static let jellyfinDocsTasks: URL = URL(string: "https://jellyfin.org/docs/general/server/tasks")!

    static let jellyfinDocsUsers: URL = URL(string: "https://jellyfin.org/docs/general/server/users")!

    static let jellyfinDocsTroubleshooting: URL = URL(string: "https://jellyfin.org/docs/general/administration/troubleshooting")!

    static let jellyfinDocsManagingUsers: URL = URL(string: "https://jellyfin.org/docs/general/server/users/adding-managing-users")!

    // [Downloads fork] **Media** root — the actual video files, in the app's
    // Documents container so each download is browsable/deletable in the Files app
    // and iPhone Storage. Layout is `<id>/<Title>.<ext>`: iOS flattens folders in
    // its file list, so the user sees one nicely-named file per download and never
    // the internals. Excluded from iCloud backup (large, re-downloadable).
    static var swiftfinDownloads: URL {
        ensureDownloadsDirectory(
            FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    // [Downloads fork] **Metadata** root — the "tripas" (Item.json + artwork) per
    // download, in the app's *private* Application Support container so they're
    // never shown in Files / Settings. Keeping metadata here (not next to the
    // media) is what stops a user from deleting Item.json and orphaning a
    // multi-GB media file.
    static var swiftfinDownloadsMetadata: URL {
        ensureDownloadsDirectory(
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
        )
    }

    // [Downloads fork] Create the directory on first use and exclude it from iCloud backup.
    private static func ensureDownloadsDirectory(_ directory: URL) -> URL {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return directory }

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var mutable = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)

        return directory
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
