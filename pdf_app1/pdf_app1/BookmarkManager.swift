//
//  BookmarkManager.swift
//  PDFViewer
//
//  Stores per-document bookmarked page indices.
//

import Combine
import Foundation

final class BookmarkManager: ObservableObject {
    @Published private(set) var bookmarks: [Int] = []

    private var documentID: String?
    private let keyPrefix = "PDFBookmarks:"

    func setDocumentID(_ id: String?) {
        documentID = id
        load()
    }

    func isBookmarked(_ pageIndex: Int) -> Bool {
        bookmarks.contains(pageIndex)
    }

    func toggle(_ pageIndex: Int) {
        if let idx = bookmarks.firstIndex(of: pageIndex) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.append(pageIndex)
        }
        bookmarks.sort()
        save()
    }

    func clear() {
        bookmarks.removeAll()
        save()
    }

    private func storageKey() -> String? {
        guard let documentID else { return nil }
        return keyPrefix + documentID
    }

    private func load() {
        guard let key = storageKey(),
              let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Int].self, from: data) else {
            bookmarks = []
            return
        }
        bookmarks = decoded.sorted()
    }

    private func save() {
        guard let key = storageKey() else { return }
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
