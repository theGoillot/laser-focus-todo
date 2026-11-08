import XCTest
@testable import TodoCore

final class ModelCodingTests: XCTestCase {
    func testItemDecodesBackendJSON() throws {
        let json = """
        {"id":"x","parent_id":"p","position":"a0","text":"Call","note":null,"completed_at":"2026-11-07T15:42:10.000Z",
         "collapsed":false,"created_by":"agent","seen_at":null,"created_at":"2026-11-07T15:42:10.000Z",
         "updated_at":"2026-11-07T15:42:10.000Z","deleted_at":null,"version":7}
        """
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, "x")
        XCTAssertEqual(item.parentId, "p")
        XCTAssertEqual(item.createdBy, .agent)
        XCTAssertTrue(item.isCompleted)
        XCTAssertEqual(item.version, 7)
    }

    func testOpsEncodeLikeBackend() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        func s(_ op: Op) throws -> String { String(decoding: try enc.encode(op), as: UTF8.self) }
        XCTAssertEqual(try s(.create(id: "i", parentId: nil, position: "a0", text: "T", note: nil)),
                       #"{"item":{"id":"i","note":null,"parent_id":null,"position":"a0","text":"T"},"op":"create"}"#)
        XCTAssertEqual(try s(.update(id: "i", fields: ItemFields(text: "B"))), #"{"fields":{"text":"B"},"id":"i","op":"update"}"#)
        XCTAssertEqual(try s(.update(id: "i", fields: ItemFields(note: .some(nil)))), #"{"fields":{"note":null},"id":"i","op":"update"}"#)
        XCTAssertEqual(try s(.move(id: "i", parentId: "p", position: "a1")), #"{"id":"i","op":"move","parent_id":"p","position":"a1"}"#)
        XCTAssertEqual(try s(.complete(id: "i", done: true)), #"{"done":true,"id":"i","op":"complete"}"#)
        XCTAssertEqual(try s(.delete(id: "i")), #"{"id":"i","op":"delete"}"#)
        XCTAssertEqual(try s(.opened), #"{"op":"opened"}"#)
    }

    func testOpRoundTrips() throws {
        let ops: [Op] = [.create(id: "i", parentId: "p", position: "a0", text: "T", note: "n"), .update(id: "i", fields: ItemFields(collapsed: true)), .opened]
        let back = try JSONDecoder().decode([Op].self, from: try JSONEncoder().encode(ops))
        XCTAssertEqual(back, ops)
    }
}
