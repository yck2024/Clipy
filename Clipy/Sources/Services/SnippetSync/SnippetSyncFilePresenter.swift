//
//  SnippetSyncFilePresenter.swift
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

/// Watches the shared sync file for changes made by other processes (Clipy on another Mac, or a
/// cloud-storage provider finishing a download) via `NSFileCoordinator`'s presenter mechanism,
/// which is the robust way to observe a coordinated document regardless of whether it's stored in
/// iCloud Drive or in a third-party File Provider location such as Google Drive or Dropbox.
final class SnippetSyncFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        self.presentedItemURL = url
        self.onChange = onChange
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedItemDidChange() {
        onChange()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
}
