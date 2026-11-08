import XCTest
@testable import TodoCore

final class ListStyleTests: XCTestCase {
    func list(_ id: String, _ text: String, icon: String? = nil, color: String? = nil) -> Item {
        Item(id: id, parentId: nil, position: "a" + id, text: text, note: nil, completedAt: nil, collapsed: false, createdBy: .me,
             seenAt: nil, createdAt: "t", updatedAt: "t", deletedAt: nil, version: 1, icon: icon, color: color)
    }

    func testFieldsEncodeStyle() throws {
        let data = try JSONEncoder().encode(ItemFields(icon: .some("airplane"), color: .some(nil)))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["icon"] as? String, "airplane")
        XCTAssertTrue(obj["color"] is NSNull)
        XCTAssertEqual(obj.count, 2)
        XCTAssertEqual(ItemFields(icon: .some("x"), color: .some("teal")).columns, ["icon", "color"])
    }

    func testDefaultsAndExplicitStyle() {
        XCTAssertEqual(ListLook.of(list("i", "Inbox")), ListLook(icon: "tray.fill", color: "blue"))
        XCTAssertEqual(ListLook.of(list("w", "Work")), ListLook(icon: "circle.fill", color: "gray"))
        XCTAssertEqual(ListLook.of(list("t", "Travel", icon: "airplane", color: "teal")), ListLook(icon: "airplane", color: "teal"))
        XCTAssertTrue(ListLook.colors.contains("teal"))
        XCTAssertTrue(ListLook.icons.contains("scope"))
    }

    func testSetStyleUndoAndMerge() throws {
        let store = try LocalStore.inMemory()
        try store.merge([list("L", "Work")], version: 1)
        let ed = OutlineEditor(store: store)
        try ed.setStyle("L", icon: "briefcase.fill", color: "indigo")
        XCTAssertEqual(try store.item("L")?.icon, "briefcase.fill")
        XCTAssertEqual(try store.item("L")?.color, "indigo")
        try ed.undo()
        XCTAssertNil(try store.item("L")?.icon)
        // Once the local changes are acknowledged, the server's style wins.
        try store.ack(upTo: Int64.max)
        try store.merge([list("L", "Work", icon: "house.fill", color: "orange")], version: 2)
        XCTAssertEqual(try store.item("L")?.color, "orange")
    }

    func testNewListWithStyleIsOneUndoStep() throws {
        let store = try LocalStore.inMemory()
        let ed = OutlineEditor(store: store)
        let id = try ed.newList(named: "Travel", icon: "airplane", color: "teal")
        XCTAssertEqual(try store.item(id)?.icon, "airplane")
        try ed.undo()
        XCTAssertNil(try Outline(items: store.liveItems()).item(id))
    }
}
