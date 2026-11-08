import XCTest
@testable import TodoCore

final class AgentAnnouncerTests: XCTestCase {
    func item(_ id: String, parent: String, by: Author = .agent, seen: String? = nil, done: String? = nil) -> Item {
        Item(id: id, parentId: parent, position: "a0", text: id, note: nil, completedAt: done, collapsed: false, createdBy: by,
             seenAt: seen, createdAt: "t", updatedAt: "t", deletedAt: nil, version: 1)
    }
    lazy var outline = Outline(items: [
        Item(id: "work", parentId: nil, position: "a0", text: "Work", note: nil, completedAt: nil, collapsed: false, createdBy: .me, seenAt: nil, createdAt: "t", updatedAt: "t", deletedAt: nil, version: 1),
        Item(id: "inbox", parentId: nil, position: "a1", text: "Inbox", note: nil, completedAt: nil, collapsed: false, createdBy: .me, seenAt: nil, createdAt: "t", updatedAt: "t", deletedAt: nil, version: 1),
        item("w1", parent: "work"), item("i1", parent: "inbox"),
    ])

    func testBannerForEachNewAgentItemWhenPanelClosed() {
        let out = AgentAnnouncer.itemsToAnnounce([item("w1", parent: "work"), item("i1", parent: "inbox")], panelVisibleOnList: nil, outline: outline)
        XCTAssertEqual(out.map(\.id), ["w1", "i1"])
    }

    func testNoBannerWhenPanelOnSameList() {
        let out = AgentAnnouncer.itemsToAnnounce([item("w1", parent: "work"), item("i1", parent: "inbox")], panelVisibleOnList: "work", outline: outline)
        XCTAssertEqual(out.map(\.id), ["i1"])
    }

    func testNoBannerForMyItemsSeenOrDone() {
        let out = AgentAnnouncer.itemsToAnnounce([item("a", parent: "work", by: .me), item("b", parent: "work", seen: "t"), item("c", parent: "work", done: "t")],
                                                 panelVisibleOnList: nil, outline: outline)
        XCTAssertTrue(out.isEmpty)
    }

    func testTitleNamesAgentAndList() {
        XCTAssertEqual(AgentAnnouncer.title(for: item("w1", parent: "work"), agentName: "Agent", outline: outline), "Agent added to Work")
    }

    func testDotOnUntilSeen() {
        XCTAssertTrue(AgentAnnouncer.hasUnseen(outline))
        let seen = Outline(items: outline.byId.values.map { var i = $0; i.seenAt = "t"; return i })
        XCTAssertFalse(AgentAnnouncer.hasUnseen(seen))
    }
}
