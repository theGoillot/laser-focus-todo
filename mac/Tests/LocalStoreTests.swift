import XCTest
@testable import TodoCore

final class LocalStoreTests: XCTestCase {
    var store: LocalStore!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        store = try LocalStore.inMemory()
    }

    func server(_ id: String, parent: String? = nil, text: String = "T", position: String = "a0", completed: String? = nil, by: Author = .me, version: Int = 1) -> Item {
        Item(id: id, parentId: parent, position: position, text: text, note: nil, completedAt: completed, collapsed: false,
             createdBy: by, seenAt: nil, createdAt: "2026-11-07T00:00:00.000Z", updatedAt: "2026-11-07T00:00:00.000Z", deletedAt: nil, version: version)
    }

    func testApplyWritesItemAndPending() throws {
        try store.apply(.create(id: "a", parentId: nil, position: "a0", text: "Hi", note: nil), now: now)
        XCTAssertEqual(try store.item("a")?.text, "Hi")
        XCTAssertEqual(try store.item("a")?.createdBy, .me)
        XCTAssertEqual(try store.pending(limit: 10).map(\.op), [.create(id: "a", parentId: nil, position: "a0", text: "Hi", note: nil)])
    }

    func testPendingFieldNotOverwrittenByPull() throws {
        try store.merge([server("x", text: "Old")], version: 1)
        try store.apply(.update(id: "x", fields: ItemFields(text: "Mine")), now: now)
        try store.merge([server("x", text: "Old", completed: "2026-11-07T01:00:00.000Z", version: 2)], version: 2)
        let x = try XCTUnwrap(try store.item("x"))
        XCTAssertEqual(x.text, "Mine")
        XCTAssertNotNil(x.completedAt)
    }

    func testAckClearsPendingAndPullThenWins() throws {
        try store.merge([server("x", text: "Old")], version: 1)
        try store.apply(.update(id: "x", fields: ItemFields(text: "Mine")), now: now)
        let p = try store.pending(limit: 10)
        try store.ack(upTo: p.last!.id)
        XCTAssertTrue(try store.pending(limit: 10).isEmpty)
        try store.merge([server("x", text: "Server", version: 3)], version: 3)
        XCTAssertEqual(try store.item("x")?.text, "Server")
        XCTAssertEqual(try store.lastVersion(), 3)
    }

    func testDeleteHidesSubtreeLocally() throws {
        try store.merge([server("p"), server("c", parent: "p"), server("g", parent: "c")], version: 1)
        try store.apply(.delete(id: "p"), now: now)
        XCTAssertTrue(try store.liveItems().isEmpty)
        XCTAssertEqual(try store.pending(limit: 10).count, 1, "one delete op; the server cascades")
    }

    func testCompleteSetsAndClears() throws {
        try store.merge([server("x")], version: 1)
        try store.apply(.complete(id: "x", done: true), now: now)
        XCTAssertNotNil(try store.item("x")?.completedAt)
        try store.apply(.complete(id: "x", done: false), now: now)
        XCTAssertNil(try store.item("x")?.completedAt)
    }

    func testOpenedOnlyQueues() throws {
        try store.apply(.opened, now: now)
        XCTAssertEqual(try store.pending(limit: 10).map(\.op), [.opened])
    }

    func testDropRemovesOnePending() throws {
        try store.apply(.opened, now: now)
        try store.apply(.opened, now: now)
        let p = try store.pending(limit: 10)
        try store.drop(p[0].id)
        XCTAssertEqual(try store.pending(limit: 10).map(\.id), [p[1].id])
    }

    func testMergeReportsNewAgentItems() throws {
        let fresh = try store.merge([server("g", text: "From bot", by: .agent)], version: 1)
        XCTAssertEqual(fresh.map(\.id), ["g"])
        let again = try store.merge([server("g", text: "From bot edited", by: .agent, version: 2)], version: 2)
        XCTAssertTrue(again.isEmpty, "only first sight counts as new")
    }
}
