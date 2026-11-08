import XCTest
@testable import TodoCore

final class DatesTagsTests: XCTestCase {
    func it(_ id: String, _ parent: String?, _ pos: String, when: String? = nil, deadline: String? = nil, done: Bool = false) -> Item {
        Item(id: id, parentId: parent, position: pos, text: id, note: nil, completedAt: done ? "t" : nil, collapsed: false, createdBy: .me,
             seenAt: nil, createdAt: "t", updatedAt: "t", deletedAt: nil, version: 1, whenDate: when, deadline: deadline)
    }

    // MARK: Model

    func testItemDecodesDates() throws {
        let json = #"{"id":"x","parent_id":null,"position":"a0","text":"T","note":null,"completed_at":null,"collapsed":false,"created_by":"me","seen_at":null,"created_at":"t","updated_at":"t","deleted_at":null,"version":3,"when_date":"2026-11-08","deadline":"2026-12-01"}"#
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(item.whenDate, "2026-11-08")
        XCTAssertEqual(item.deadline, "2026-12-01")
    }

    func testFieldsEncodeDatesAndClears() throws {
        let set = String(decoding: try JSONEncoder().encode(ItemFields(whenDate: .some("2026-11-08"))), as: UTF8.self)
        XCTAssertEqual(set, #"{"when_date":"2026-11-08"}"#)
        let clear = String(decoding: try JSONEncoder().encode(ItemFields(deadline: .some(nil))), as: UTF8.self)
        XCTAssertEqual(clear, #"{"deadline":null}"#)
        XCTAssertEqual(ItemFields(whenDate: .some(nil), deadline: .some("x")).columns, ["when_date", "deadline"])
        let back = try JSONDecoder().decode(ItemFields.self, from: Data(#"{"when_date":null}"#.utf8))
        XCTAssertEqual(back.whenDate, .some(nil))
    }

    // MARK: Store + editor

    func testStarTodayAndUndo() throws {
        let store = try LocalStore.inMemory()
        try store.merge([it("L", nil, "a0"), it("A", "L", "a0")], version: 1)
        let ed = OutlineEditor(store: store, now: { Date(timeIntervalSince1970: 1_794_000_000) })
        try ed.toggleToday("A", today: "2026-11-07")
        XCTAssertEqual(try store.item("A")?.whenDate, "2026-11-07")
        try ed.toggleToday("A", today: "2026-11-07")
        XCTAssertNil(try store.item("A")?.whenDate)
        try ed.undo()
        XCTAssertEqual(try store.item("A")?.whenDate, "2026-11-07")
        try ed.setDeadline("A", "2026-12-01")
        XCTAssertEqual(try store.item("A")?.deadline, "2026-12-01")
        try ed.setWhen("A", "2026-11-20")
        XCTAssertEqual(try store.item("A")?.whenDate, "2026-11-20")
        try ed.undo()
        XCTAssertEqual(try store.item("A")?.whenDate, "2026-11-07")
    }

    func testNewItemWithWhenIsOneUndoStep() throws {
        let store = try LocalStore.inMemory()
        try store.merge([it("L", nil, "a0")], version: 1)
        let ed = OutlineEditor(store: store)
        let id = try ed.newItem(in: "L", text: "From Today", when: "2026-11-07")
        XCTAssertEqual(try store.item(id)?.whenDate, "2026-11-07")
        try ed.undo()
        XCTAssertNil(try Outline(items: store.liveItems()).item(id))
    }

    func testMergeCopiesServerDatesButKeepsPendingLocal() throws {
        let store = try LocalStore.inMemory()
        try store.merge([it("L", nil, "a0"), it("A", "L", "a0")], version: 1)
        try store.merge([it("L", nil, "a0"), it("A", "L", "a0", when: "2026-11-09", deadline: "2026-11-30")], version: 2)
        XCTAssertEqual(try store.item("A")?.whenDate, "2026-11-09")
        try store.apply(.update(id: "A", fields: ItemFields(whenDate: .some("2026-11-07"))))
        try store.merge([it("L", nil, "a0"), it("A", "L", "a0", when: "2026-11-10", deadline: "2026-12-31")], version: 3)
        XCTAssertEqual(try store.item("A")?.whenDate, "2026-11-07")
        XCTAssertEqual(try store.item("A")?.deadline, "2026-12-31")
    }

    // MARK: Today

    func testTodayGroupsOpenStarredAndDueItemsByList() {
        let o = Outline(items: [
            it("Inbox", nil, "a0"), it("Work", nil, "a1"),
            it("star", "Work", "a0", when: "2026-11-07"),
            it("old", "Inbox", "a0", when: "2026-11-01"),
            it("due", "Inbox", "a1", deadline: "2026-11-07"),
            it("later", "Inbox", "a2", when: "2026-11-09"),
            it("done", "Inbox", "a3", when: "2026-11-07", done: true),
            it("plain", "Inbox", "a4"),
        ])
        let groups = o.today("2026-11-07")
        XCTAssertEqual(groups.map(\.list.id), ["Inbox", "Work"])
        XCTAssertEqual(groups[0].items.map(\.id), ["old", "due"])
        XCTAssertEqual(groups[1].items.map(\.id), ["star"])
        XCTAssertEqual(o.todayCount("2026-11-07"), 3)
    }

    func testTodayKeepsJustTickedRows() {
        let o = Outline(items: [it("Inbox", nil, "a0"), it("done", "Inbox", "a0", when: "2026-11-07", done: true), it("x", "Inbox", "a1", when: "2026-11-07")])
        XCTAssertEqual(o.today("2026-11-07").flatMap(\.items).map(\.id), ["x"])
        XCTAssertEqual(o.today("2026-11-07", keep: ["done"]).flatMap(\.items).map(\.id), ["done", "x"])
    }

    func testTaggedPrefix() {
        var a = it("a", "Inbox", "a0"); a.text = "Wire #acme.io deal"
        var b = it("b", "Inbox", "a1"); b.text = "#ac party"
        let o = Outline(items: [it("Inbox", nil, "a0"), a, b])
        XCTAssertEqual(o.tagged(prefix: "acme").map(\.id), ["a"])
        XCTAssertEqual(o.tagged(prefix: "ac").map(\.id), ["a", "b"])
    }

    func testTaggedKeepsTheRowBeingEdited() {
        var a = it("a", "Inbox", "a0"); a.text = "Buy milk #wor"
        var b = it("b", "Inbox", "a1"); b.text = "Other #work"
        let o = Outline(items: [it("Inbox", nil, "a0"), a, b])
        XCTAssertEqual(o.tagged("work").map(\.id), ["b"])
        XCTAssertEqual(o.tagged("work", keep: ["a"]).map(\.id), ["a", "b"])
        XCTAssertEqual(o.tagged(prefix: "work", keep: ["a"]).map(\.id), ["a", "b"])
    }

    func testTaggedAcrossLists() {
        var a = it("a", "Inbox", "a0"); a.text = "Wire #acme.io deal"
        var b = it("b", "Work", "a0"); b.text = "Call #ACME.IO banker"
        var c = it("c", "Work", "a1"); c.text = "acme.io no tag"
        let o = Outline(items: [it("Inbox", nil, "a0"), it("Work", nil, "a1"), a, b, c])
        XCTAssertEqual(o.tagged("acme.io").map(\.id), ["a", "b"])
        XCTAssertEqual(o.allTags, ["acme.io"])
    }

    // MARK: Tags

    func testTagsMatchBackendRules() {
        XCTAssertEqual(Tags.in("Call Acme #acme.io. Then #Work, and #a-b/c! not a#b"), ["acme.io", "work", "a-b/c"])
        XCTAssertEqual(Tags.in("#sunday Send update"), ["sunday"])
        XCTAssertEqual(Tags.in("no tags # here"), [])
        XCTAssertEqual(Tags.in("#a.#b and #c-#d"), ["a", "b", "c", "d"])
        let ranges = Tags.ranges(in: "Hi #acme.io.")
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(("Hi #acme.io." as NSString).substring(with: ranges[0]), "#acme.io")
    }

    func testPartialTagAtCaret() {
        XCTAssertEqual(Tags.partial(in: "Send #80", caret: 8), "80")
        XCTAssertEqual(Tags.partial(in: "Send #", caret: 6), "")
        XCTAssertNil(Tags.partial(in: "Send 80", caret: 7))
        XCTAssertNil(Tags.partial(in: "Send #80 x", caret: 10))
    }

    // MARK: Natural dates (today is Saturday 2026-11-07)

    func testNaturalDates() {
        let today = "2026-11-07"
        func p(_ s: String) -> String? { NaturalDate.parse(s, today: today) }
        XCTAssertEqual(p("today"), "2026-11-07")
        XCTAssertEqual(p("tod"), "2026-11-07")
        XCTAssertEqual(p("tomorrow"), "2026-11-08")
        XCTAssertEqual(p("tmr"), "2026-11-08")
        XCTAssertEqual(p("mon"), "2026-11-09")
        XCTAssertEqual(p("friday"), "2026-11-13")
        XCTAssertEqual(p("sat"), "2026-11-14")
        XCTAssertEqual(p("next week"), "2026-11-09")
        XCTAssertEqual(p("this weekend"), "2026-11-07")
        XCTAssertEqual(p("weekend"), "2026-11-07")
        XCTAssertEqual(p("in 3 days"), "2026-11-10")
        XCTAssertEqual(p("3d"), "2026-11-10")
        XCTAssertEqual(p("2w"), "2026-11-21")
        XCTAssertEqual(p("dec 24"), "2026-12-24")
        XCTAssertEqual(p("24 dec"), "2026-12-24")
        XCTAssertEqual(p("jan 3"), "2027-01-03")
        XCTAssertEqual(p("11/20"), "2026-11-20")
        XCTAssertEqual(p("2027-02-01"), "2027-02-01")
        XCTAssertEqual(p("next month"), "2026-12-07")
        XCTAssertNil(p("blah"))
        XCTAssertNil(p("monthly"))
        XCTAssertEqual(p("next fri"), "2026-11-13")
        XCTAssertEqual(NaturalDate.parse("next fri", today: "2026-11-12"), "2026-11-20")
        XCTAssertEqual(NaturalDate.parse("fri", today: "2026-11-12"), "2026-11-13")
        XCTAssertNil(p("feb 30"))
    }

    func testDayLabels() {
        let today = "2026-11-07"
        XCTAssertEqual(DayLabel.short("2026-11-07", today: today), "Today")
        XCTAssertEqual(DayLabel.short("2026-11-08", today: today), "Tomorrow")
        XCTAssertEqual(DayLabel.short("2026-11-06", today: today), "Yesterday")
        XCTAssertEqual(DayLabel.short("2026-11-12", today: today), "Thu")
        XCTAssertEqual(DayLabel.short("2026-11-20", today: today), "Nov 20")
        XCTAssertEqual(DayLabel.short("2027-01-03", today: today), "Jan 3, 2027")
        XCTAssertEqual(DayLabel.daysLeft("2026-11-10", today: today), 3)
        XCTAssertEqual(DayLabel.daysLeft("2026-11-05", today: today), -2)
    }
}
