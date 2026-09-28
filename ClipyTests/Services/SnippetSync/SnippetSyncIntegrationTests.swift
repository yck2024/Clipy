import AppKit
import Dependencies
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite(.serialized)
struct SnippetSyncIntegrationTests {
    @Test
    func firstEnableUnionsExistingRecordsAcrossTwoRepositories() throws {
        let setup = try SyncTestDevices()
        defer { setup.cleanUp() }

        let folderA = try #require(setup.repositoryA.insertFolders([("A", [("one", "from A")])]))[0]
        let folderB = try #require(setup.repositoryB.insertFolders([("B", [("two", "from B")])]))[0]
        setup.serviceA.synchronizeForTesting(at: setup.shared)
        setup.serviceB.synchronizeForTesting(at: setup.shared)
        setup.serviceA.synchronizeForTesting(at: setup.shared)

        let recordsA = setup.repositoryA.fetchFolderDetails().flatMap(\.snippets).map(\.content).sorted()
        let recordsB = setup.repositoryB.fetchFolderDetails().flatMap(\.snippets).map(\.content).sorted()
        #expect(recordsA == ["from A", "from B"])
        #expect(recordsB == recordsA)
        #expect(setup.repositoryA.fetchFolderDetails().contains { $0.folder.id == folderA.folder.id })
        #expect(setup.repositoryB.fetchFolderDetails().contains { $0.folder.id == folderB.folder.id })
    }

    @Test
    func equalTimestampConflictingEditsConvergeAcrossTwoRepositories() throws {
        let setup = try SyncTestDevices()
        defer { setup.cleanUp() }
        let folderID = SnippetFolder.ID(rawValue: UUID())
        let snippetID = Snippet.ID(rawValue: UUID())
        let folder = SnippetFolder(id: folderID, title: "Shared", index: 0, isEnabled: true, updatedAt: 100)
        let snippetA = Snippet(id: snippetID, folderID: folderID, title: "Snippet", content: "A", index: 0, isEnabled: true, updatedAt: 500)
        let snippetB = Snippet(id: snippetID, folderID: folderID, title: "Snippet", content: "B", index: 0, isEnabled: true, updatedAt: 500)
        setup.repositoryA.applySyncChanges(folderUpserts: [folder], folderDeletions: [], snippetUpserts: [snippetA], snippetDeletions: [])
        setup.repositoryB.applySyncChanges(folderUpserts: [folder], folderDeletions: [], snippetUpserts: [snippetB], snippetDeletions: [])

        setup.serviceA.synchronizeForTesting(at: setup.shared)
        setup.serviceB.synchronizeForTesting(at: setup.shared)
        setup.serviceA.synchronizeForTesting(at: setup.shared)
        setup.repositoryA.applySyncChanges(folderUpserts: [], folderDeletions: [], snippetUpserts: [snippetA], snippetDeletions: [])
        setup.repositoryB.applySyncChanges(folderUpserts: [], folderDeletions: [], snippetUpserts: [snippetB], snippetDeletions: [])
        setup.serviceA.synchronizeForTesting(at: setup.shared)
        setup.serviceB.synchronizeForTesting(at: setup.shared)
        setup.serviceA.synchronizeForTesting(at: setup.shared)

        let contentA = try #require(setup.repositoryA.fetchSnippet(id: snippetID)).content
        let contentB = try #require(setup.repositoryB.fetchSnippet(id: snippetID)).content
        #expect(contentA == contentB)
        #expect(contentA == "B")
    }

    @Test
    func olderDeletionTombstoneDoesNotDeleteNewerLiveSnippet() throws {
        let setup = try SyncTestDevices()
        defer { setup.cleanUp() }
        let folderID = SnippetFolder.ID(rawValue: UUID())
        let snippetID = Snippet.ID(rawValue: UUID())
        let folder = SnippetFolder(id: folderID, title: "Shared", index: 0, isEnabled: true, updatedAt: 100)
        let liveSnippet = Snippet(id: snippetID, folderID: folderID, title: "Live", content: "keep", index: 0, isEnabled: true, updatedAt: 200)
        setup.repositoryB.applySyncChanges(folderUpserts: [folder], folderDeletions: [], snippetUpserts: [liveSnippet], snippetDeletions: [])
        let remote = SnippetSyncFile(
            folders: [SnippetSyncFolderRecord(folder)], snippets: [], deletedFolders: [],
            deletedSnippets: [SnippetSyncTombstone(id: snippetID.rawValue, deletedAt: 100)]
        )
        #expect(SnippetSyncFileStore().write(remote, to: setup.syncFileURL))

        setup.serviceB.synchronizeForTesting(at: setup.shared)

        #expect(setup.repositoryB.fetchSnippet(id: snippetID) == liveSnippet)
        let synced = try #require(SnippetSyncFileStore().read(at: setup.syncFileURL).file)
        #expect(synced.snippets.map(\.content) == ["keep"])
        #expect(synced.deletedSnippets.isEmpty)
    }

    @Test
    func duplicateIDJsonKeepsNewestRecordsWithoutCrashing() throws {
        let setup = try SyncTestDevices()
        defer { setup.cleanUp() }
        let folderID = UUID()
        let snippetID = UUID()
        let json = """
        {
          "folders": [
            {"id":"\(folderID)","title":"old","index":0,"isEnabled":true,"updatedAt":500},
            {"id":"\(folderID)","title":"new","index":0,"isEnabled":true,"updatedAt":700}
          ],
          "snippets": [
            {"id":"\(snippetID)","folderID":"\(folderID)","title":"old","content":"old","index":0,"isEnabled":true,"updatedAt":500},
            {"id":"\(snippetID)","folderID":"\(folderID)","title":"new","content":"new","index":0,"isEnabled":true,"updatedAt":700}
          ],
          "deletedFolders": [], "deletedSnippets": []
        }
        """
        try Data(json.utf8).write(to: setup.syncFileURL)

        setup.serviceB.synchronizeForTesting(at: setup.shared)

        let details = setup.repositoryB.fetchFolderDetails()
        #expect(details.map { $0.folder.title } == ["new"])
        #expect(details.flatMap(\.snippets).map(\.content) == ["new"])
        let file = try #require(SnippetSyncFileStore().read(at: setup.syncFileURL).file)
        #expect(file.folders.map(\.title) == ["new"])
        #expect(file.snippets.map(\.content) == ["new"])
    }

    @Test
    func syncingLeavesClipboardHistoryRowsUnchanged() throws {
        let setup = try SyncTestDevices()
        defer { setup.cleanUp() }
        try seedClipboardHistory(in: setup.databaseA, id: "device-a")
        try seedClipboardHistory(in: setup.databaseB, id: "device-b")
        let beforeA = try historyRows(in: setup.databaseA)
        let beforeB = try historyRows(in: setup.databaseB)
        _ = setup.repositoryA.insertFolders([("A", [("one", "snippet A")])])
        _ = setup.repositoryB.insertFolders([("B", [("two", "snippet B")])])

        setup.serviceA.synchronizeForTesting(at: setup.shared)
        setup.serviceB.synchronizeForTesting(at: setup.shared)
        setup.serviceA.synchronizeForTesting(at: setup.shared)

        #expect(try historyRows(in: setup.databaseA) == beforeA)
        #expect(try historyRows(in: setup.databaseB) == beforeB)
    }
}

@MainActor
private final class SyncTestDevices {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let shared: URL
    let databaseA: any DatabaseWriter
    let databaseB: any DatabaseWriter
    let repositoryA: SnippetRepository
    let repositoryB: SnippetRepository
    let serviceA: SnippetSyncService
    let serviceB: SnippetSyncService

    var syncFileURL: URL { shared.appendingPathComponent(SnippetSyncFileStore.fileName) }

    init() throws {
        shared = root.appending(path: "shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let databaseA = try makeDatabase(at: root.appending(path: "device-a.sqlite"))
        let databaseB = try makeDatabase(at: root.appending(path: "device-b.sqlite"))
        let repositoryA = withDependencies { $0.defaultDatabase = databaseA } operation: { SnippetRepository() }
        let repositoryB = withDependencies { $0.defaultDatabase = databaseB } operation: { SnippetRepository() }
        self.databaseA = databaseA
        self.databaseB = databaseB
        self.repositoryA = repositoryA
        self.repositoryB = repositoryB
        serviceA = withDependencies { $0.snippetRepository = repositoryA } operation: { SnippetSyncService() }
        serviceB = withDependencies { $0.snippetRepository = repositoryB } operation: { SnippetSyncService() }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private func makeDatabase(at url: URL) throws -> any DatabaseWriter {
    let database = try SQLiteData.defaultDatabase(path: url.path, configuration: Configuration())
    var migrator = DatabaseMigrator()
    migrator.registerMigration()
    try migrator.migrate(database)
    return database
}

private func seedClipboardHistory(in database: any DatabaseWriter, id: String) throws {
    try database.write { database in
        try PasteboardHistory.insert {
            PasteboardHistory(
                id: PasteboardHistory.ID(rawValue: id), title: "history-\(id)", ocrText: "ocr-\(id)",
                pasteboardTypes: [.string], createdAt: 10, updateAt: 11, deviceID: id
            )
        }.execute(database)
    }
}

private func historyRows(in database: any DatabaseWriter) throws -> [PasteboardHistory] {
    try database.read { database in try PasteboardHistory.all.fetchAll(database) }
}

private extension SnippetSyncRemoteReadResult {
    var file: SnippetSyncFile? {
        guard case let .success(file) = self else { return nil }
        return file
    }
}
