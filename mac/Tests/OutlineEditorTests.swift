import XCTest
@testable import TodoCore

/// Drives the editor against a real in-memory LocalStore, so ops are checked by their effect on the tree.
final class OutlineEditorTests: XCTestCase {
    var store: LocalStore!
    var editor: OutlineEditor!
    let list = "L"

    override func setUp() async throws {
        store = try LocalStore.inMemory()
        func it(_ id: String, _ parent: String?, _ pos: String, collapsed: Bool = false) -> Item {
            Item(id: id, parentId: parent, position: pos, text: id, note: nil, completedAt: nil, collapsed: collapsed, createdBy: .me,
                 seenAt: nil, createdAt: "t", updatedAt: "t", deletedAt: nil, version: 1)
        }
        // L
        //   A
        //     A1
        //   B
        //   C
        try store.merge([it("L", nil, "a0"), it("A", "L", "a0"), it("A1", "A", "a0"), it("B", "L", "a1"), it("C", "L", "a2")], version: 1)
        editor = OutlineEditor(store: store)
    }

    func kids(_ id: String?) throws -> [String] { try Outline(items: store.liveItems()).children(of: id).map(\.id) }

    func testIndentMakesPreviousSiblingParent() throws {
        try editor.indent("B")
        XCTAssertEqual(try kids("A"), ["A1", "B"])
        XCTAssertEqual(try kids("L"), ["A", "C"])
    }

    func testIndentFirstChildIsNoop() throws {
        try editor.indent("A")
        XCTAssertEqual(try kids("L"), ["A", "B", "C"])
        XCTAssertEqual(try store.pendingCount(), 0)
    }

    func testIndentIntoCollapsedSiblingExpandsIt() throws {
        try editor.toggleCollapsed("A")
        try editor.indent("B")
        XCTAssertEqual(try store.item("A")?.collapsed, false)
    }

    func testOutdentMovesAfterParent() throws {
        try editor.outdent("A1", floor: list)
        XCTAssertEqual(try kids("L"), ["A", "A1", "B", "C"])
    }

    func testOutdentAtFloorIsNoop() throws {
        try editor.outdent("B", floor: list)
        XCTAssertEqual(try kids("L"), ["A", "B", "C"])
    }

    func testNewItemBelowPositionBetweenSiblings() throws {
        let id = try editor.newItem(after: "B")
        XCTAssertEqual(try kids("L"), ["A", "B", id, "C"])
    }

    func testNewItemAfterExpandedParentBecomesFirstChild() throws {
        let id = try editor.newItem(after: "A")
        XCTAssertEqual(try kids("A"), [id, "A1"])
    }

    func testNewItemBeforeInsertsAbove() throws {
        let id = try editor.newItem(before: "B")
        XCTAssertEqual(try kids("L"), ["A", id, "B", "C"])
        let first = try editor.newItem(before: "A")
        XCTAssertEqual(try kids("L").first, first)
    }

    func testNewItemInEmptyList() throws {
        let id = try editor.newItem(in: "C")
        XCTAssertEqual(try kids("C"), [id])
    }

    func testMoveUpSwapsPositions() throws {
        try editor.moveUp("C")
        XCTAssertEqual(try kids("L"), ["A", "C", "B"])
        try editor.moveUp("A")
        XCTAssertEqual(try kids("L"), ["A", "C", "B"], "first item cannot move up")
    }

    func testMoveDownSwapsPositions() throws {
        try editor.moveDown("A")
        XCTAssertEqual(try kids("L"), ["B", "A", "C"])
    }

    func testTickUndo() throws {
        try editor.toggleComplete("B")
        XCTAssertNotNil(try store.item("B")?.completedAt)
        try editor.undo()
        XCTAssertNil(try store.item("B")?.completedAt)
        try editor.redo()
        XCTAssertNotNil(try store.item("B")?.completedAt)
    }

    func testUndoInvertsOwnLastOpOnly() throws {
        try editor.setText("B", "B2")
        // The agent ticks B after my edit.
        var b = try XCTUnwrap(try store.item("B"))
        b.completedAt = "2026-11-07T00:00:00.000Z"
        b.version = 2
        try store.ack(upTo: Int64.max)
        try store.merge([b], version: 2)
        try editor.undo()
        XCTAssertEqual(try store.item("B")?.text, "B")
        XCTAssertNotNil(try store.item("B")?.completedAt, "the agent's tick is not mine to undo")
    }

    func testDeleteUndoRestoresSubtree() throws {
        try editor.delete("A")
        XCTAssertEqual(try kids("L"), ["B", "C"])
        try editor.undo()
        XCTAssertEqual(try kids("L"), ["A", "B", "C"])
        XCTAssertEqual(try kids("A"), ["A1"])
    }

    func testUndoNewItemRemovesIt() throws {
        _ = try editor.newItem(after: "C")
        try editor.undo()
        XCTAssertEqual(try kids("L"), ["A", "B", "C"])
    }

    func testVisibleRowsRespectCollapseAndCompleted() throws {
        try editor.toggleComplete("C")
        var rows = Outline(items: try store.liveItems()).rows(under: list, showCompleted: false, keep: [])
        XCTAssertEqual(rows.map(\.item.id), ["A", "A1", "B"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
        try editor.toggleCollapsed("A")
        rows = Outline(items: try store.liveItems()).rows(under: list, showCompleted: false, keep: ["C"])
        XCTAssertEqual(rows.map(\.item.id), ["A", "B", "C"], "kept: a just-ticked row stays until its fade ends")
    }

    func testTiedPositionsStillInsert() throws {
        var c = try XCTUnwrap(try store.item("C"))
        c.position = "a1"
        try store.merge([c], version: 2)
        let id = try editor.newItem(after: "B")
        XCTAssertTrue(try kids("L").contains(id))
    }
}
