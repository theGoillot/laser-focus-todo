import XCTest
@testable import TodoCore

/// In-memory stand-in for the backend: applies ops naively and serves sync.
final class FakeAPI: SyncAPI, @unchecked Sendable {
    var items: [String: Item] = [:]
    var version = 0
    var postedBatches: [[Op]] = []
    var syncCalls: [Int] = []
    var failNextPostWith: Error?
    var rejectText: String?
    let lock = NSLock()

    func postOps(_ ops: [Op]) async throws -> SyncResponse {
        try lock.withLock {
            if let e = failNextPostWith { failNextPostWith = nil; throw e }
            if let bad = rejectText, let i = ops.firstIndex(where: { if case let .create(_, _, _, t, _) = $0 { return t == bad }; return false }) {
                throw APIError.badOp(index: i, code: "TEXT_TOO_LONG")
            }
            postedBatches.append(ops)
            for op in ops {
                version += 1
                switch op {
                case let .create(id, p, pos, t, n):
                    items[id] = Item(id: id, parentId: p, position: pos, text: t, note: n, completedAt: nil, collapsed: false, createdBy: .me,
                                     seenAt: nil, createdAt: "x", updatedAt: "x", deletedAt: nil, version: version)
                case let .update(id, f):
                    if let t = f.text { items[id]?.text = t }
                    items[id]?.version = version
                default: break
                }
            }
            return SyncResponse(version: version, items: [])
        }
    }

    func sync(since: Int) async throws -> SyncResponse {
        lock.withLock {
            syncCalls.append(since)
            return SyncResponse(version: version, items: items.values.filter { $0.version > since })
        }
    }

    func agentAdds(_ id: String, _ text: String) {
        lock.withLock {
            version += 1
            items[id] = Item(id: id, parentId: nil, position: "a5", text: text, note: nil, completedAt: nil, collapsed: false, createdBy: .agent,
                             seenAt: nil, createdAt: "x", updatedAt: "x", deletedAt: nil, version: version)
        }
    }
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

final class SyncEngineTests: XCTestCase {
    var store: LocalStore!
    var api: FakeAPI!
    var agentItems: Box<[Item]>!
    var engine: SyncEngine!

    override func setUp() async throws {
        store = try LocalStore.inMemory()
        api = FakeAPI()
        let box = Box<[Item]>([])
        agentItems = box
        engine = SyncEngine(store: store, api: api, onAgentItems: { box.value += $0 })
    }

    func testPushThenPullMerges() async throws {
        try store.apply(.create(id: "a", parentId: nil, position: "a0", text: "Hi", note: nil))
        await engine.syncNow()
        XCTAssertEqual(api.postedBatches.count, 1)
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertEqual(try store.item("a")?.version, 1, "pulled server copy replaced the local one")
        XCTAssertEqual(try store.lastVersion(), 1)
    }

    func testBadOpIsDroppedAndRestSent() async throws {
        api.rejectText = "bad"
        try store.apply([.create(id: "a", parentId: nil, position: "a0", text: "ok", note: nil),
                         .create(id: "b", parentId: nil, position: "a1", text: "bad", note: nil),
                         .create(id: "c", parentId: nil, position: "a2", text: "ok2", note: nil)])
        await engine.syncNow()
        XCTAssertEqual(try store.pendingCount(), 0)
        XCTAssertEqual(Set(api.items.keys), ["a", "c"])
    }

    func testOfflineKeepsPending() async throws {
        api.failNextPostWith = URLError(.notConnectedToInternet)
        try store.apply(.create(id: "a", parentId: nil, position: "a0", text: "Hi", note: nil))
        await engine.syncNow()
        XCTAssertEqual(try store.pendingCount(), 1)
        let status = await engine.status
        XCTAssertEqual(status, .offline)
        await engine.syncNow()
        XCTAssertEqual(try store.pendingCount(), 0)
        let after = await engine.status
        XCTAssertEqual(after, .synced)
    }

    func testReconnectTriggersPull() async throws {
        await engine.socketConnected()
        XCTAssertEqual(api.syncCalls, [0])
    }

    func testVersionFrameAheadTriggersPull() async throws {
        api.agentAdds("g", "From bot")
        await engine.versionAnnounced(api.version)
        XCTAssertEqual(try store.item("g")?.text, "From bot")
        XCTAssertEqual(agentItems.value.map(\.id), ["g"])
        await engine.versionAnnounced(api.version)
        XCTAssertEqual(api.syncCalls.count, 1, "a version we already have does not pull again")
    }

    func testPendingFieldNotOverwrittenByPull() async throws {
        api.agentAdds("g", "Old")
        await engine.syncNow()
        api.failNextPostWith = URLError(.notConnectedToInternet)
        try store.apply(.update(id: "g", fields: ItemFields(text: "Mine")))
        api.lock.withLock { api.version += 1; api.items["g"]?.completedAt = "t"; api.items["g"]?.version = api.version }
        await engine.syncNow()
        XCTAssertEqual(try store.item("g")?.text, "Mine")
        XCTAssertEqual(try store.item("g")?.completedAt, "t")
    }

    func testBackoffSchedule() {
        XCTAssertEqual((0..<7).map { LiveSocket.backoff(attempt: $0) }, [1, 2, 4, 8, 16, 30, 30])
    }
}
