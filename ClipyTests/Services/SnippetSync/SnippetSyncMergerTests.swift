//
//  SnippetSyncMergerTests.swift
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
import Testing
@testable import Clipy

struct SnippetSyncMergerTests {
    private let folderID = SnippetFolder.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let otherFolderID = SnippetFolder.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private let snippetID = Snippet.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!)

    @Test
    func firstEnableMergesLocalAndRemoteWithoutDeletingEitherSide() throws {
        let localFolder = folder(id: folderID, title: "Local Folder", updatedAt: 100)
        let localSnippet = snippet(id: snippetID, folderID: folderID, title: "Local Snippet", updatedAt: 100)

        let remoteFolder = folderRecord(id: otherFolderID.rawValue, title: "Remote Folder", updatedAt: 50)

        let plan = SnippetSyncMerger.plan(
            localFolders: [localFolder],
            localSnippets: [localSnippet],
            previousLocalFolders: nil,
            previousLocalSnippets: nil,
            remote: .success(SnippetSyncFile(folders: [remoteFolder], snippets: [], deletedFolders: [], deletedSnippets: [])),
            now: 1_000
        )

        // The remote-only folder is added locally, and the local-only folder/snippet are kept
        // (and end up written to the file); nothing is deleted on a first enable.
        #expect(plan.folderUpserts.map(\.id) == [otherFolderID])
        #expect(plan.snippetUpserts.isEmpty)
        #expect(plan.folderDeletions.isEmpty)
        #expect(plan.snippetDeletions.isEmpty)

        let file = try #require(plan.fileToWrite)
        #expect(Set(file.folders.map(\.id)) == [folderID.rawValue, otherFolderID.rawValue])
        #expect(file.snippets.map(\.id) == [snippetID.rawValue])
        #expect(file.deletedFolders.isEmpty)
        #expect(file.deletedSnippets.isEmpty)
    }

    @Test
    func notFoundFileIsTreatedAsEmptyAndLocalStateIsWrittenOut() throws {
        let localFolder = folder(id: folderID, title: "Folder", updatedAt: 100)

        let plan = SnippetSyncMerger.plan(
            localFolders: [localFolder],
            localSnippets: [],
            previousLocalFolders: nil,
            previousLocalSnippets: nil,
            remote: .notFound,
            now: 1_000
        )

        #expect(plan.folderUpserts.isEmpty)
        #expect(plan.folderDeletions.isEmpty)
        #expect(try #require(plan.fileToWrite).folders == [folderRecord(id: folderID.rawValue, title: "Folder", updatedAt: 100)])
    }

    @Test
    func conflictingEditsAreResolvedByNewestUpdatedAt() throws {
        let localFolder = folder(id: folderID, title: "Local Title", updatedAt: 100)
        let remoteFolder = folderRecord(id: folderID.rawValue, title: "Remote Title", updatedAt: 200)

        let plan = SnippetSyncMerger.plan(
            localFolders: [localFolder],
            localSnippets: [],
            previousLocalFolders: [localFolder],
            previousLocalSnippets: [],
            remote: .success(SnippetSyncFile(folders: [remoteFolder], snippets: [], deletedFolders: [], deletedSnippets: [])),
            now: 1_000
        )

        // The remote edit is newer, so it wins and gets applied locally.
        #expect(plan.folderUpserts.map(\.title) == ["Remote Title"])
        #expect(try #require(plan.fileToWrite).folders.map(\.title) == ["Remote Title"])
    }

    @Test
    func localEditNewerThanRemoteWinsWithoutRewritingLocalDatabase() throws {
        let localFolder = folder(id: folderID, title: "Local Title", updatedAt: 200)
        let remoteFolder = folderRecord(id: folderID.rawValue, title: "Remote Title", updatedAt: 100)

        let plan = SnippetSyncMerger.plan(
            localFolders: [localFolder],
            localSnippets: [],
            previousLocalFolders: [localFolder],
            previousLocalSnippets: [],
            remote: .success(SnippetSyncFile(folders: [remoteFolder], snippets: [], deletedFolders: [], deletedSnippets: [])),
            now: 1_000
        )

        // The local edit already reflects the winner, so there's nothing new to apply locally,
        // but the file still needs to be updated to carry the newer local title.
        #expect(plan.folderUpserts.isEmpty)
        #expect(try #require(plan.fileToWrite).folders.map(\.title) == ["Local Title"])
    }

    @Test
    func remoteTombstoneNewerThanLocalEditDeletesLocalFolderAndItsSnippets() throws {
        let localFolder = folder(id: folderID, title: "Folder", updatedAt: 100)
        let localSnippet = snippet(id: snippetID, folderID: folderID, title: "Snippet", updatedAt: 150)
        let tombstone = SnippetSyncTombstone(id: folderID.rawValue, deletedAt: 200)

        let plan = SnippetSyncMerger.plan(
            localFolders: [localFolder],
            localSnippets: [localSnippet],
            previousLocalFolders: [localFolder],
            previousLocalSnippets: [localSnippet],
            remote: .success(SnippetSyncFile(folders: [], snippets: [], deletedFolders: [tombstone], deletedSnippets: [])),
            now: 1_000
        )

        #expect(plan.folderDeletions == [folderID])
        // The snippet is cascade-deleted with its folder even though the tombstone never
        // mentions the snippet directly and the snippet's own edit is newer than the tombstone.
        #expect(plan.snippetDeletions == [snippetID])

        let file = try #require(plan.fileToWrite)
        #expect(file.folders.isEmpty)
        #expect(file.snippets.isEmpty)
        #expect(file.deletedFolders == [tombstone])
    }

    @Test
    func remoteTombstoneOlderThanLocalEditLosesToTheEdit() throws {
        let localFolder = folder(id: folderID, title: "Folder", updatedAt: 200)
        let tombstone = SnippetSyncTombstone(id: folderID.rawValue, deletedAt: 100)

        let plan = SnippetSyncMerger.plan(
            localFolders: [localFolder],
            localSnippets: [],
            previousLocalFolders: [localFolder],
            previousLocalSnippets: [],
            remote: .success(SnippetSyncFile(folders: [], snippets: [], deletedFolders: [tombstone], deletedSnippets: [])),
            now: 1_000
        )

        #expect(plan.folderDeletions.isEmpty)
        #expect(try #require(plan.fileToWrite).folders.map(\.id) == [folderID.rawValue])
        #expect(try #require(plan.fileToWrite).deletedFolders.isEmpty)
    }

    @Test
    func localDeletionSinceLastSyncProducesATombstoneForOtherDevices() throws {
        let remoteFolder = folderRecord(id: folderID.rawValue, title: "Folder", updatedAt: 100)

        let plan = SnippetSyncMerger.plan(
            localFolders: [],
            localSnippets: [],
            previousLocalFolders: [folder(id: folderID, title: "Folder", updatedAt: 100)],
            previousLocalSnippets: [],
            remote: .success(SnippetSyncFile(folders: [remoteFolder], snippets: [], deletedFolders: [], deletedSnippets: [])),
            now: 1_000
        )

        // Already gone locally, so there's nothing left to delete locally...
        #expect(plan.folderDeletions.isEmpty)
        // ...but the file needs a tombstone so other Macs delete their copy too.
        let file = try #require(plan.fileToWrite)
        #expect(file.folders.isEmpty)
        #expect(file.deletedFolders == [SnippetSyncTombstone(id: folderID.rawValue, deletedAt: 1_000)])
    }

    @Test
    func unreadableFileProducesNoChangesAndLeavesLocalDataUntouched() {
        let localFolder = folder(id: folderID, title: "Folder", updatedAt: 100)
        let localSnippet = snippet(id: snippetID, folderID: folderID, title: "Snippet", updatedAt: 100)

        let plan = SnippetSyncMerger.plan(
            localFolders: [localFolder],
            localSnippets: [localSnippet],
            previousLocalFolders: [localFolder],
            previousLocalSnippets: [localSnippet],
            remote: .unreadable,
            now: 1_000
        )

        #expect(plan == SnippetSyncPlan())
        #expect(!plan.hasLocalChanges)
        #expect(plan.fileToWrite == nil)
    }
}

private extension SnippetSyncMergerTests {
    func folder(id: SnippetFolder.ID, title: String, updatedAt: Int) -> SnippetFolder {
        SnippetFolder(id: id, title: title, index: 0, isEnabled: true, updatedAt: updatedAt)
    }

    func snippet(id: Snippet.ID, folderID: SnippetFolder.ID, title: String, updatedAt: Int) -> Snippet {
        Snippet(id: id, folderID: folderID, title: title, content: "content", index: 0, isEnabled: true, updatedAt: updatedAt)
    }

    func folderRecord(id: UUID, title: String, updatedAt: Int) -> SnippetSyncFolderRecord {
        SnippetSyncFolderRecord(id: id, title: title, index: 0, isEnabled: true, updatedAt: updatedAt)
    }
}
