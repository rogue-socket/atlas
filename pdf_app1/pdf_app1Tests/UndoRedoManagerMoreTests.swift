import XCTest
import AppKit
import PDFKit
@testable import pdf_app1

/// Extends `UndoRedoManagerTests.swift` to cover:
///   - max-stack-size cap (50 entries; oldest dropped)
///   - clear() empties both stacks
///   - new operations after an undo wipe the redo stack
///   - executeUndo / executeRedo apply each operation kind correctly
final class UndoRedoManagerMoreTests: XCTestCase {

    private func newAnnotation() -> PDFAnnotation {
        PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
                      forType: .highlight, withProperties: nil)
    }

    private func newPage() -> PDFPage { PDFPage() }

    // MARK: - Stack-size cap

    func test_addOperation_capsStackAtFifty() {
        let m = UndoRedoManager()
        let page = newPage()
        for _ in 0..<60 {
            m.addOperation(.add(annotation: newAnnotation(), page: page))
        }
        // Pop all 50 undos to confirm the cap.
        var popped = 0
        while m.canUndo {
            _ = m.undo()
            popped += 1
            if popped > 100 { break }
        }
        XCTAssertEqual(popped, 50, "Stack must cap at 50 operations")
    }

    // MARK: - addOperation clears redo

    func test_addOperation_clearsRedoStack() {
        let m = UndoRedoManager()
        let page = newPage()

        m.addOperation(.add(annotation: newAnnotation(), page: page))
        _ = m.undo()
        XCTAssertTrue(m.canRedo)

        // New operation must wipe redo.
        m.addOperation(.add(annotation: newAnnotation(), page: page))
        XCTAssertFalse(m.canRedo)
    }

    // MARK: - clear()

    func test_clear_emptiesBothStacks() {
        let m = UndoRedoManager()
        let page = newPage()
        m.addOperation(.add(annotation: newAnnotation(), page: page))
        _ = m.undo()
        XCTAssertTrue(m.canRedo)

        m.clear()
        XCTAssertFalse(m.canUndo)
        XCTAssertFalse(m.canRedo)
    }

    // MARK: - executeUndo / executeRedo

    func test_executeAdd_addsAnnotationOnRedoAndRemovesOnUndo() {
        let m = UndoRedoManager()
        let page = newPage()
        let ann = newAnnotation()

        m.executeRedo(.add(annotation: ann, page: page))
        XCTAssertTrue(page.annotations.contains { $0 === ann })

        m.executeUndo(.add(annotation: ann, page: page))
        XCTAssertFalse(page.annotations.contains { $0 === ann })
    }

    func test_executeRemove_inversesAdd() {
        let m = UndoRedoManager()
        let page = newPage()
        let ann = newAnnotation()
        page.addAnnotation(ann)

        m.executeRedo(.remove(annotation: ann, page: page))
        XCTAssertFalse(page.annotations.contains { $0 === ann })

        m.executeUndo(.remove(annotation: ann, page: page))
        XCTAssertTrue(page.annotations.contains { $0 === ann })
    }

    func test_executeModifyBounds_setsBoundsCorrectly() {
        let m = UndoRedoManager()
        let page = newPage()
        let ann = newAnnotation()
        let oldBounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        let newBounds = CGRect(x: 50, y: 50, width: 20, height: 20)

        m.executeRedo(.modify(annotation: ann, oldBounds: oldBounds, newBounds: newBounds, page: page))
        XCTAssertEqual(ann.bounds, newBounds)

        m.executeUndo(.modify(annotation: ann, oldBounds: oldBounds, newBounds: newBounds, page: page))
        XCTAssertEqual(ann.bounds, oldBounds)
    }

    func test_executeModifyContents_setsContents() {
        let m = UndoRedoManager()
        let page = newPage()
        let ann = newAnnotation()

        m.executeRedo(.modifyContents(annotation: ann, oldContents: nil, newContents: "new note", page: page))
        XCTAssertEqual(ann.contents, "new note")

        m.executeUndo(.modifyContents(annotation: ann, oldContents: nil, newContents: "new note", page: page))
        XCTAssertNil(ann.contents)
    }

    func test_executeModifyColor_setsColor() {
        let m = UndoRedoManager()
        let page = newPage()
        let ann = newAnnotation()
        ann.color = .red

        m.executeRedo(.modifyColor(annotation: ann, oldColor: .red, newColor: .blue, page: page))
        XCTAssertEqual(ann.color, .blue)

        m.executeUndo(.modifyColor(annotation: ann, oldColor: .red, newColor: .blue, page: page))
        XCTAssertEqual(ann.color, .red)
    }

    func test_executeRotatePage_setsRotation() {
        let m = UndoRedoManager()
        let page = newPage()
        page.rotation = 0

        m.executeRedo(.rotatePage(page: page, oldRotation: 0, newRotation: 90))
        XCTAssertEqual(page.rotation, 90)

        m.executeUndo(.rotatePage(page: page, oldRotation: 0, newRotation: 90))
        XCTAssertEqual(page.rotation, 0)
    }

    // MARK: - undo when empty returns nil

    func test_undo_emptyReturnsNil() {
        let m = UndoRedoManager()
        XCTAssertNil(m.undo())
    }

    func test_redo_emptyReturnsNil() {
        let m = UndoRedoManager()
        XCTAssertNil(m.redo())
    }
}
