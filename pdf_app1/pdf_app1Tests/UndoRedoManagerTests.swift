import XCTest
import PDFKit

@testable import pdf_app1

final class UndoRedoManagerTests: XCTestCase {
    func testUndoRedoStackTogglesAvailability() {
        let manager = UndoRedoManager()
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)

        let page = PDFPage()
        let annotation = PDFAnnotation(bounds: .init(x: 0, y: 0, width: 10, height: 10), forType: .highlight, withProperties: nil)
        manager.addOperation(.add(annotation: annotation, page: page))

        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)

        _ = manager.undo()
        XCTAssertFalse(manager.canUndo)
        XCTAssertTrue(manager.canRedo)

        _ = manager.redo()
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
    }
}
