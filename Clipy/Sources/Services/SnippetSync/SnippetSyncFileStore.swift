//
//  SnippetSyncFileStore.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Shunsuke Furubayashi on 2026/09/28.
//
//  Copyright © 2015-2026 Clipy Project.
//

import Foundation

/// Reads and writes the shared `SnippetSyncFile` on disk, coordinating access through
/// `NSFileCoordinator` so reads and writes are safe to interleave with a cloud-storage provider's
/// own syncing and with other processes (including Clipy on another Mac writing the same file).
/// The chosen folder can be iCloud Drive or a third-party File Provider location such as Google
/// Drive or Dropbox under `~/Library/CloudStorage`; both surface the same ubiquitous-item resource
/// values and coordinated-access contract, so no provider-specific handling is needed.
struct SnippetSyncFileStore {
    static let fileName = "Clipy Snippets.json"

    private let fileCoordinator = NSFileCoordinator()

    func read(at url: URL) -> SnippetSyncRemoteReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notFound
        }

        if let downloadingStatus = ubiquitousDownloadingStatus(of: url), downloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return .unreadable
        }

        var coordinationError: NSError?
        var data: Data?
        fileCoordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            data = try? Data(contentsOf: coordinatedURL)
        }

        guard coordinationError == nil, let data else {
            return .unreadable
        }

        guard let file = try? JSONDecoder().decode(SnippetSyncFile.self, from: data) else {
            return .unreadable
        }

        return .success(file)
    }

    @discardableResult
    func write(_ file: SnippetSyncFile, to url: URL) -> Bool {
        guard let data = try? JSONEncoder.snippetSync.encode(file) else { return false }

        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var coordinationError: NSError?
        var succeeded = false
        fileCoordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinationError) { coordinatedURL in
            let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporaryURL, options: .atomic)
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    _ = try FileManager.default.replaceItemAt(coordinatedURL, withItemAt: temporaryURL)
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: coordinatedURL)
                }
                succeeded = true
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        return coordinationError == nil && succeeded
    }
}

private extension SnippetSyncFileStore {
    /// `nil` when the URL isn't a ubiquitous item at all (a plain local folder), in which case
    /// there is no placeholder-download concern. Files synced by iCloud Drive or by a
    /// third-party File Provider extension (Google Drive, Dropbox, OneDrive, etc.) both report
    /// through this same resource value.
    func ubiquitousDownloadingStatus(of url: URL) -> URLUbiquitousItemDownloadingStatus? {
        guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
              let status = values.ubiquitousItemDownloadingStatus else {
            return nil
        }
        return status
    }
}

private extension JSONEncoder {
    static let snippetSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
