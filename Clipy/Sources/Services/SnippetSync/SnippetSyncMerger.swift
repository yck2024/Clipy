//
//  SnippetSyncMerger.swift
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

/// The outcome of reading the shared sync file, distinguishing "no file yet" (safe to treat as
/// empty and write to) from "a file exists but could not be read" (must never be treated as an
/// instruction to delete local data).
enum SnippetSyncRemoteReadResult {
    case notFound
    case success(SnippetSyncFile)
    case unreadable
}

/// The set of local database changes to apply and the file contents to write back, produced by
/// `SnippetSyncMerger.plan`. `fileToWrite` is `nil` when the remote file could not be read, in
/// which case no local changes are produced either.
struct SnippetSyncPlan: Equatable {
    var folderUpserts: [SnippetFolder] = []
    var folderDeletions: [SnippetFolder.ID] = []
    var snippetUpserts: [Snippet] = []
    var snippetDeletions: [Snippet.ID] = []
    var fileToWrite: SnippetSyncFile?

    var hasLocalChanges: Bool {
        !folderUpserts.isEmpty || !folderDeletions.isEmpty || !snippetUpserts.isEmpty || !snippetDeletions.isEmpty
    }
}

enum SnippetSyncMerger {
    /// Merges the current local snippet state with the shared sync file.
    ///
    /// - Parameters:
    ///   - localFolders: The folders currently in the local database.
    ///   - localSnippets: The snippets currently in the local database.
    ///   - previousLocalFolders: The folder ids/timestamps this device last wrote to the sync
    ///     file. `nil` on first enable, when there is no prior baseline to diff against, so a
    ///     folder missing from `localFolders` is never treated as a deletion.
    ///   - previousLocalSnippets: Same as `previousLocalFolders`, for snippets.
    ///   - remote: The result of reading the shared sync file.
    ///   - now: The current unix time, used to stamp newly discovered local deletions.
    static func plan(
        localFolders: [SnippetFolder],
        localSnippets: [Snippet],
        previousLocalFolders: [SnippetFolder]?,
        previousLocalSnippets: [Snippet]?,
        remote: SnippetSyncRemoteReadResult,
        now: Int
    ) -> SnippetSyncPlan {
        let remoteFile: SnippetSyncFile
        switch remote {
        case .unreadable:
            // The file exists but couldn't be read (I/O error, corrupt JSON, or an
            // iCloud placeholder still downloading). Treating it as empty would look like every
            // remote record was deleted, so skip this merge cycle entirely and keep local data untouched.
            return SnippetSyncPlan()
        case .notFound:
            remoteFile = .empty
        case let .success(file):
            remoteFile = file
        }

        let folderResult = mergeEntities(
            local: localFolders.map(SnippetSyncFolderRecord.init),
            previousLocal: previousLocalFolders.map { $0.map(SnippetSyncFolderRecord.init) },
            remoteRecords: remoteFile.folders,
            remoteTombstones: remoteFile.deletedFolders,
            now: now
        )

        let survivingFolderIDs = Set(folderResult.records.map(\.id))

        // A snippet whose folder no longer exists is implicitly deleted along with its folder
        // (mirroring the local database's ON DELETE CASCADE), regardless of what the remote file
        // or previous local state say about that snippet on its own.
        let remoteSnippetRecords = remoteFile.snippets.filter { survivingFolderIDs.contains($0.folderID) }
        let remoteSnippetTombstones = remoteFile.deletedSnippets
        let localSnippetRecords = localSnippets
            .filter { survivingFolderIDs.contains($0.folderID.rawValue) }
            .map(SnippetSyncSnippetRecord.init)
        let orphanedLocalSnippetIDs = localSnippets
            .filter { !survivingFolderIDs.contains($0.folderID.rawValue) }
            .map(\.id)

        let snippetResult = mergeEntities(
            local: localSnippetRecords,
            previousLocal: previousLocalSnippets.map { $0.map(SnippetSyncSnippetRecord.init) },
            remoteRecords: remoteSnippetRecords,
            remoteTombstones: remoteSnippetTombstones,
            now: now
        )

        let mergedFile = SnippetSyncFile(
            folders: folderResult.records,
            snippets: snippetResult.records,
            deletedFolders: folderResult.tombstones,
            deletedSnippets: snippetResult.tombstones
        )

        return SnippetSyncPlan(
            folderUpserts: folderResult.localUpserts.map(SnippetFolder.init),
            folderDeletions: folderResult.localDeletions.map(SnippetFolder.ID.init(rawValue:)),
            snippetUpserts: snippetResult.localUpserts.map(Snippet.init),
            snippetDeletions: (snippetResult.localDeletions + orphanedLocalSnippetIDs.map(\.rawValue))
                .map(Snippet.ID.init(rawValue:)),
            fileToWrite: mergedFile
        )
    }
}

// MARK: - Generic entity merge

private protocol SnippetSyncEntityRecord: Equatable {
    var id: UUID { get }
    var updatedAt: Int { get }
    var canonicalContent: String { get }
}

extension SnippetSyncFolderRecord: SnippetSyncEntityRecord {
    var canonicalContent: String {
        [title, String(index), isEnabled ? "1" : "0"].map(canonicalComponent).joined()
    }
}

extension SnippetSyncSnippetRecord: SnippetSyncEntityRecord {
    var canonicalContent: String {
        [folderID.uuidString, title, content, String(index), isEnabled ? "1" : "0"].map(canonicalComponent).joined()
    }
}

private func canonicalComponent(_ value: String) -> String {
    "\(value.utf8.count):\(value)"
}

private struct EntityMergeResult<Record> {
    var records: [Record]
    var tombstones: [SnippetSyncTombstone]
    var localUpserts: [Record]
    var localDeletions: [UUID]
}

private struct MergeCandidate<Record> {
    let timestamp: Int
    let isDeleted: Bool
    let record: Record?
    let tombstone: SnippetSyncTombstone?
}

/// Merges one entity type (folders, or snippets) by id: the version with the newest timestamp
/// wins, whether that version is a live record or a tombstone. Ties prefer the live record, so a
/// simultaneous edit and delete never destroys data by accident.
private func mergeEntities<Record: SnippetSyncEntityRecord>(
    local: [Record],
    previousLocal: [Record]?,
    remoteRecords: [Record],
    remoteTombstones: [SnippetSyncTombstone],
    now: Int
) -> EntityMergeResult<Record> {
    let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
    let remoteByID = Dictionary(uniqueKeysWithValues: remoteRecords.map { ($0.id, $0) })
    let remoteTombstoneByID = Dictionary(uniqueKeysWithValues: remoteTombstones.map { ($0.id, $0) })

    // A local deletion is only detectable relative to a known prior baseline: an id this device
    // previously synced but no longer has locally. Without a baseline (first enable), nothing is
    // considered locally deleted, so first enable only ever adds records, never removes them.
    var localTombstoneByID = [UUID: SnippetSyncTombstone]()
    if let previousLocal {
        let previousIDs = Set(previousLocal.map(\.id))
        let currentIDs = Set(localByID.keys)
        for id in previousIDs.subtracting(currentIDs) {
            localTombstoneByID[id] = SnippetSyncTombstone(id: id, deletedAt: now)
        }
    }

    let allIDs = Set(localByID.keys)
        .union(remoteByID.keys)
        .union(remoteTombstoneByID.keys)
        .union(localTombstoneByID.keys)

    var records = [Record]()
    var tombstones = [SnippetSyncTombstone]()
    var localUpserts = [Record]()
    var localDeletions = [UUID]()

    // Stable ordering keeps independently merged files byte-identical across Macs. Without it,
    // differing Set iteration order can make file presenters rewrite each other's output forever.
    for id in allIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
        var candidates = [MergeCandidate<Record>]()
        if let record = localByID[id] {
            candidates.append(MergeCandidate(timestamp: record.updatedAt, isDeleted: false, record: record, tombstone: nil))
        }
        if let record = remoteByID[id] {
            candidates.append(MergeCandidate(timestamp: record.updatedAt, isDeleted: false, record: record, tombstone: nil))
        }
        if let tombstone = remoteTombstoneByID[id] {
            candidates.append(MergeCandidate(timestamp: tombstone.deletedAt, isDeleted: true, record: nil, tombstone: tombstone))
        }
        if let tombstone = localTombstoneByID[id] {
            candidates.append(MergeCandidate(timestamp: tombstone.deletedAt, isDeleted: true, record: nil, tombstone: tombstone))
        }

        var winner = candidates[0]
        for candidate in candidates.dropFirst() {
            if candidate.timestamp > winner.timestamp {
                winner = candidate
            } else if candidate.timestamp == winner.timestamp {
                if winner.isDeleted, !candidate.isDeleted {
                    winner = candidate
                } else if !winner.isDeleted, !candidate.isDeleted,
                          let candidateRecord = candidate.record,
                          let winnerRecord = winner.record,
                          candidateRecord.canonicalContent > winnerRecord.canonicalContent {
                    winner = candidate
                }
            }
        }

        if winner.isDeleted, let tombstone = winner.tombstone {
            tombstones.append(tombstone)
            if localByID[id] != nil {
                localDeletions.append(id)
            }
        } else if let record = winner.record {
            records.append(record)
            if localByID[id] != record {
                localUpserts.append(record)
            }
        }
    }

    return EntityMergeResult(records: records, tombstones: tombstones, localUpserts: localUpserts, localDeletions: localDeletions)
}
