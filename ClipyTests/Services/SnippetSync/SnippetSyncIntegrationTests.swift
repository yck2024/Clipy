import Dependencies
import Foundation
import SQLiteData
import Testing
@testable import Clipy

@MainActor
@Suite(.serialized)
struct SnippetSyncIntegrationTests {
    @Test
    func twoRepositoriesConvergeThroughSharedSyncFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let shared = root.appending(path: "shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let databaseA = try makeDatabase(at: root.appending(path: "device-a.sqlite"))
        let databaseB = try makeDatabase(at: root.appending(path: "device-b.sqlite"))
        let repositoryA = withDependencies { $0.defaultDatabase = databaseA } operation: { SnippetRepository() }
        let repositoryB = withDependencies { $0.defaultDatabase = databaseB } operation: { SnippetRepository() }
        let serviceA = withDependencies { $0.snippetRepository = repositoryA } operation: { SnippetSyncService() }
        let serviceB = withDependencies { $0.snippetRepository = repositoryB } operation: { SnippetSyncService() }

        let folderA = try #require(repositoryA.insertFolders([("A", [("one", "from A")])]))[0]
        let folderB = try #require(repositoryB.insertFolders([("B", [("two", "from B")])]))[0]
        serviceA.synchronizeForTesting(at: shared)
        serviceB.synchronizeForTesting(at: shared)
        serviceA.synchronizeForTesting(at: shared)

        let recordsA = repositoryA.fetchFolderDetails().flatMap(\.snippets).map(\.content).sorted()
        let recordsB = repositoryB.fetchFolderDetails().flatMap(\.snippets).map(\.content).sorted()
        #expect(recordsA == ["from A", "from B"])
        #expect(recordsB == recordsA)
        #expect(repositoryA.fetchFolderDetails().contains { $0.folder.id == folderA.folder.id })
        #expect(repositoryB.fetchFolderDetails().contains { $0.folder.id == folderB.folder.id })
    }
}

private func makeDatabase(at url: URL) throws -> any DatabaseWriter {
    var configuration = Configuration()
    let database = try SQLiteData.defaultDatabase(path: url.absoluteString, configuration: configuration)
    var migrator = DatabaseMigrator()
    migrator.registerMigration()
    try migrator.migrate(database)
    return database
}
