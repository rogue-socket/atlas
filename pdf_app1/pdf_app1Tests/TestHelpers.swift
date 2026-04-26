import Foundation
import XCTest

@testable import pdf_app1

final class URLDataBookmarker: ProjectBookmarking, RecentFilesBookmarking {
    func createBookmark(for url: URL) -> Data? {
        url.absoluteString.data(using: .utf8)
    }

    func resolveBookmark(_ data: Data, isStale: inout Bool) -> URL? {
        isStale = false
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: str)
    }

    func refreshBookmark(for url: URL) -> Data? {
        createBookmark(for: url)
    }
}

func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
