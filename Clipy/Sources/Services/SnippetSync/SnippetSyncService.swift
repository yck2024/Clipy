//
//  SnippetSyncService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Shunsuke Furubayashi on 2026/09/28.
//
//  Copyright © 2015-2026 Clipy Project.
//

import Combine
import Dependencies
import Foundation
import Sharing

/// Coordinates the opt-in "sync snippets through a folder" feature: watches the local database
/// and the shared sync file for changes, merges them through `SnippetSyncMerger`, and applies the
/// result to both sides. Disabled by default; only snippets and snippet folders are affected,
/// never clipboard history.
final class SnippetSyncService {
    @Dependency(\.snippetRepository)
    private var snippetRepository
    @Dependency(\.mainQueue)
    private var mainQueue

    private let fileStore = SnippetSyncFileStore()
    private var filePresenter: SnippetSyncFilePresenter?
    private var configurationCancellable: AnyCancellable?
    private var localObservationCancellable: AnyCancellable?
    private var syncTriggerCancellable: AnyCancellable?
    private let syncTrigger = PassthroughSubject<Void, Never>()

    private var currentFolderURL: URL?
    private var previousLocalFolders: [SnippetFolder]?
    private var previousLocalSnippets: [Snippet]?
    private var lastWrittenFile: SnippetSyncFile?

    @Shared(.isSnippetSyncEnabled)
    private var isSnippetSyncEnabled
    @Shared(.snippetSyncFolderPath)
    private var snippetSyncFolderPath

    func start() {
        syncTriggerCancellable = syncTrigger
            .debounce(for: .seconds(1), scheduler: mainQueue)
            .sink { [weak self] in
                self?.syncNow()
            }

        configurationCancellable = Publishers.CombineLatest(
            $isSnippetSyncEnabled.changes(includingInitialValue: true),
            $snippetSyncFolderPath.changes(includingInitialValue: true)
        )
        .receive(on: mainQueue)
        .sink { [weak self] isEnabled, folderPath in
            self?.reconfigure(isEnabled: isEnabled, folderPath: folderPath)
        }
    }

    deinit {
        filePresenter?.stop()
    }
}

private extension SnippetSyncService {
    func reconfigure(isEnabled: Bool, folderPath: String?) {
        stopWatching()

        guard isEnabled, let folderPath, !folderPath.isEmpty else {
            currentFolderURL = nil
            return
        }

        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        currentFolderURL = folderURL
        // Reset the baseline: we don't know yet whether the last state we wrote for this folder
        // (if any) still reflects reality, so the next merge treats this as a first enable and
        // only adds records rather than risk inventing deletions.
        previousLocalFolders = nil
        previousLocalSnippets = nil
        lastWrittenFile = nil

        localObservationCancellable = snippetRepository.observeFolderDetails()
            .dropFirst()
            .receive(on: mainQueue)
            .sink { [weak self] _ in
                self?.syncTrigger.send(())
            }

        filePresenter = SnippetSyncFilePresenter(url: syncFileURL(in: folderURL)) { [weak self] in
            self?.syncTrigger.send(())
        }

        syncTrigger.send(())
    }

    func stopWatching() {
        localObservationCancellable = nil
        filePresenter?.stop()
        filePresenter = nil
    }

    func syncNow() {
        guard let folderURL = currentFolderURL else { return }
        let url = syncFileURL(in: folderURL)

        let details = snippetRepository.fetchFolderDetails()
        let localFolders = details.map(\.folder)
        let localSnippets = details.flatMap(\.snippets)

        let plan = SnippetSyncMerger.plan(
            localFolders: localFolders,
            localSnippets: localSnippets,
            previousLocalFolders: previousLocalFolders,
            previousLocalSnippets: previousLocalSnippets,
            remote: fileStore.read(at: url),
            now: Int(Date().timeIntervalSince1970)
        )

        guard let fileToWrite = plan.fileToWrite else {
            // Unreadable file: keep the existing baseline and local data untouched, and try
            // again on the next local change or file-change notification.
            return
        }

        if plan.hasLocalChanges {
            snippetRepository.applySyncChanges(
                folderUpserts: plan.folderUpserts,
                folderDeletions: plan.folderDeletions,
                snippetUpserts: plan.snippetUpserts,
                snippetDeletions: plan.snippetDeletions
            )
        }

        if fileToWrite != lastWrittenFile {
            fileStore.write(fileToWrite, to: url)
            lastWrittenFile = fileToWrite
        }

        previousLocalFolders = fileToWrite.folders.map(SnippetFolder.init)
        previousLocalSnippets = fileToWrite.snippets.map(Snippet.init)
    }

    func syncFileURL(in folderURL: URL) -> URL {
        folderURL.appendingPathComponent(SnippetSyncFileStore.fileName)
    }
}

extension DependencyValues {
    var snippetSyncService: SnippetSyncService {
        get { self[SnippetSyncServiceKey.self] }
        set { self[SnippetSyncServiceKey.self] = newValue }
    }

    private enum SnippetSyncServiceKey: DependencyKey {
        static let liveValue = SnippetSyncService()
    }
}
