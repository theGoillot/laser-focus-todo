import XCTest
@testable import TodoCore

/// Regression tests for the final review's findings.
final class ReviewFixTests: XCTestCase {
    func item(_ id: String, _ parent: String?, text: String? = nil, version: Int = 1) -> Item {
        Item(id: id, parentId: parent, position: "a0", text: text ?? id, note: nil, completedAt: nil, collapsed: false, createdBy: .me,
             seenAt: nil, createdAt: "t", updatedAt: "t", deletedAt: nil, version: version)
    }

    // #2: switching backends must not keep the old cursor or old rows.
    func testResetAllClearsItemsPendingAndVersion() throws {
        let store = try LocalStore.inMemory()
        try store.merge([item("a", nil)], version: 97)
        try store.apply(.opened)
        try store.resetAll()
        XCTAssertTrue(try store.liveItems().isEmpty)
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertEqual(try store.lastVersion(), 0)
    }

    func testServerBehindLocalCursorTriggersFullResync() async throws {
        let store = try LocalStore.inMemory()
        try store.merge([item("dev", nil)], version: 97)
        let api = FakeAPI()
        api.agentAdds("prod", "Prod item")
        let engine = SyncEngine(store: store, api: api)
        await engine.syncNow()
        XCTAssertEqual(api.syncCalls.last, 0, "a server behind our cursor means a different or reset backend")
        XCTAssertNotNil(try store.item("prod"))
        XCTAssertNil(try store.item("dev"), "rows the server does not have are dropped on a full resync")
        XCTAssertEqual(try store.lastVersion(), api.version)
    }

    // #5: a rejected op must not leave a local-only item behind.
    func testRejectedCreateIsRemovedLocally() async throws {
        let store = try LocalStore.inMemory()
        let api = FakeAPI()
        api.rejectText = "bad"
        try store.apply([.create(id: "ok", parentId: nil, position: "a0", text: "ok", note: nil),
                         .create(id: "b", parentId: nil, position: "a1", text: "bad", note: nil)])
        let engine = SyncEngine(store: store, api: api)
        await engine.syncNow()
        XCTAssertNotNil(try store.item("ok"))
        XCTAssertNil(try store.item("b"), "the server never accepted it, so it must not live on only on the Mac")
        let rejected = await engine.rejectedCount
        XCTAssertEqual(rejected, 1)
    }

    func testTextIsCappedInUTF16WithOverflowInNote() throws {
        let store = try LocalStore.inMemory()
        try store.merge([item("L", nil)], version: 1)
        let editor = OutlineEditor(store: store)
        let long = String(repeating: "😀", count: 1500) // 3000 UTF-16 units, 1500 Characters
        let id = try editor.newItem(in: "L", text: long)
        let it = try XCTUnwrap(try store.item(id))
        XCTAssertLessThanOrEqual(it.text.utf16.count, 2000)
        XCTAssertEqual(it.text + (it.note ?? ""), long, "nothing typed is lost")
        try editor.setText(id, long + "!")
        XCTAssertLessThanOrEqual(try XCTUnwrap(try store.item(id)).text.utf16.count, 2000)
    }

    // #6: a parent loop in data must not hang the UI.
    func testPathAndRootSurviveParentLoop() {
        let o = Outline(items: [item("A", "B"), item("B", "A")])
        XCTAssertLessThanOrEqual(o.path(to: "A").count, 2)
        _ = o.rootList(of: "A")
    }

    // Local restore stamps updated_at with the restore time, not the old delete time.
    func testLocalRestoreUpdatedAt() throws {
        let store = try LocalStore.inMemory()
        try store.merge([item("x", nil)], version: 1)
        try store.apply(.delete(id: "x"), now: Date(timeIntervalSince1970: 1_000))
        try store.apply(.restore(id: "x"), now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try store.item("x")?.updatedAt, "1970-01-01T00:33:20.000Z")
    }
}
