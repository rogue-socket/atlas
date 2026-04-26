import Foundation
import XCTest

@testable import pdf_app1

final class ProjectsManagerTests: XCTestCase {
    func testCreateProjectDedupesNameCaseInsensitive() throws {
        let dir = try makeTempDirectory()
        let storageURL = dir.appendingPathComponent("projects.json")
        let bookmarker = URLDataBookmarker()

        let manager = ProjectsManager(storageURL: storageURL, bookmarker: bookmarker)
        manager.createProject(name: "Work", urls: [])
        manager.createProject(name: "work", urls: [])

        XCTAssertEqual(manager.projects.count, 2)
        XCTAssertEqual(manager.projects[0].name, "work (2)")
        XCTAssertEqual(manager.projects[1].name, "Work")
    }

    func testRenameProjectDedupesNameCaseInsensitive() throws {
        let dir = try makeTempDirectory()
        let storageURL = dir.appendingPathComponent("projects.json")
        let bookmarker = URLDataBookmarker()

        let manager = ProjectsManager(storageURL: storageURL, bookmarker: bookmarker)
        manager.createProject(name: "A", urls: [])
        manager.createProject(name: "B", urls: [])

        let aID = manager.projects[1].id
        manager.renameProject(aID, name: "b")

        XCTAssertEqual(manager.projects.first(where: { $0.id == aID })?.name, "b (2)")
    }

    func testPersistsAndLoadsProjects() throws {
        let dir = try makeTempDirectory()
        let storageURL = dir.appendingPathComponent("projects.json")
        let bookmarker = URLDataBookmarker()

        do {
            let manager = ProjectsManager(storageURL: storageURL, bookmarker: bookmarker)
            manager.createProject(name: "Alpha", urls: [])
            manager.createProject(name: "Beta", urls: [])

            let exp = expectation(description: "Wait for debounced save")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { exp.fulfill() }
            wait(for: [exp], timeout: 2.0)
        }

        let reloaded = ProjectsManager(storageURL: storageURL, bookmarker: bookmarker)
        let exp2 = expectation(description: "Wait for async load")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp2.fulfill() }
        wait(for: [exp2], timeout: 2.0)

        XCTAssertEqual(reloaded.projects.map { $0.name }.sorted(), ["Alpha", "Beta"].sorted())
    }
}
