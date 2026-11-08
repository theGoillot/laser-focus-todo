import Foundation
import GRDB

/// A queued change waiting for the backend to acknowledge it.
public struct PendingOp: Equatable, Sendable {
    public let id: Int64
    public let op: Op
}

/// The Mac's local copy of the outline. Every edit lands here first (so typing never waits on the network)
/// and is queued in `pending_ops` until the backend acknowledges it.
public final class LocalStore: @unchecked Sendable {
    public let db: DatabaseQueue

    public init(path: String) throws {
        db = try DatabaseQueue(path: path)
        try migrate()
    }

    public static func inMemory() throws -> LocalStore { try LocalStore(queue: DatabaseQueue()) }

    init(queue: DatabaseQueue) throws {
        db = queue
        try migrate()
    }

    private func migrate() throws {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE items (
              id TEXT PRIMARY KEY, parent_id TEXT, position TEXT NOT NULL, text TEXT NOT NULL, note TEXT,
              completed_at TEXT, collapsed INTEGER NOT NULL DEFAULT 0, created_by TEXT NOT NULL, seen_at TEXT,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT, version INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX items_tree ON items(parent_id, position, id);
            CREATE TABLE pending_ops (id INTEGER PRIMARY KEY AUTOINCREMENT, item_id TEXT, columns TEXT NOT NULL, payload TEXT NOT NULL);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        }
        m.registerMigration("v2-dates") { db in
            try db.execute(sql: "ALTER TABLE items ADD COLUMN when_date TEXT; ALTER TABLE items ADD COLUMN deadline TEXT;")
        }
        m.registerMigration("v3-style") { db in
            try db.execute(sql: "ALTER TABLE items ADD COLUMN icon TEXT; ALTER TABLE items ADD COLUMN color TEXT;")
        }
        try m.migrate(db)
    }

    // MARK: Reads

    public func item(_ id: String) throws -> Item? { try db.read { try Item.fetchOne($0, key: id) } }

    public func liveItems() throws -> [Item] { try db.read(Self.fetchLive) }

    static func fetchLive(_ db: Database) throws -> [Item] {
        try Item.filter(Item.CodingKeys.deletedAt == nil).order(Item.CodingKeys.position, Item.CodingKeys.id).fetchAll(db)
    }

    /// Calls `onChange` on the main queue with every live item, now and after every change.
    public func observeLive(onChange: @escaping @Sendable ([Item]) -> Void) -> AnyDatabaseCancellable {
        ValueObservation.tracking(Self.fetchLive).start(in: db, scheduling: .async(onQueue: .main), onError: { _ in }, onChange: onChange)
    }

    public func lastVersion() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT value FROM meta WHERE key = 'version'") ?? 0 }
    }

    public func pending(limit: Int) throws -> [PendingOp] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, payload FROM pending_ops ORDER BY id LIMIT ?", arguments: [limit]).map { row in
                PendingOp(id: row["id"], op: try JSONDecoder().decode(Op.self, from: Data((row["payload"] as String).utf8)))
            }
        }
    }

    public func pendingCount() throws -> Int { try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_ops") ?? 0 } }

    public func meta(_ key: String) throws -> String? {
        try db.read { try String.fetchOne($0, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key]) }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value]) }
    }

    // MARK: Local writes

    /// Applies ops locally and queues them, in one transaction.
    public func apply(_ ops: [Op], now: Date = Date()) throws {
        let stamp = Clock.string(now)
        try db.write { db in
            for op in ops {
                try Self.applyLocally(op, stamp: stamp, db: db)
                let payload = String(decoding: try JSONEncoder().encode(op), as: UTF8.self)
                try db.execute(sql: "INSERT INTO pending_ops (item_id, columns, payload) VALUES (?, ?, ?)",
                               arguments: [op.itemId, op.touchedColumns.joined(separator: ","), payload])
            }
        }
    }

    public func apply(_ op: Op, now: Date = Date()) throws { try apply([op], now: now) }

    private static func applyLocally(_ op: Op, stamp: String, db: Database) throws {
        switch op {
        case let .create(id, parentId, position, text, note):
            if try Item.exists(db, key: id) { return }
            try Item(id: id, parentId: parentId, position: position, text: text, note: note, completedAt: nil, collapsed: false,
                     createdBy: .me, seenAt: nil, createdAt: stamp, updatedAt: stamp, deletedAt: nil, version: 0).insert(db)
        case let .update(id, f):
            guard var it = try Item.fetchOne(db, key: id) else { return }
            if let t = f.text { it.text = t }
            if let n = f.note { it.note = n }
            if let c = f.collapsed { it.collapsed = c }
            if let s = f.seenAt { it.seenAt = s }
            if let w = f.whenDate { it.whenDate = w }
            if let d = f.deadline { it.deadline = d }
            if let v = f.icon { it.icon = v }
            if let v = f.color { it.color = v }
            it.updatedAt = stamp
            try it.update(db)
        case let .move(id, parentId, position):
            guard var it = try Item.fetchOne(db, key: id) else { return }
            it.parentId = parentId
            it.position = position
            it.updatedAt = stamp
            try it.update(db)
        case let .complete(id, done):
            guard var it = try Item.fetchOne(db, key: id) else { return }
            it.completedAt = done ? (it.completedAt ?? stamp) : nil
            it.updatedAt = stamp
            try it.update(db)
        case let .delete(id):
            var stack = [id]
            while let cur = stack.popLast() {
                try db.execute(sql: "UPDATE items SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL", arguments: [stamp, stamp, cur])
                stack += try String.fetchAll(db, sql: "SELECT id FROM items WHERE parent_id = ? AND deleted_at IS NULL", arguments: [cur])
            }
        case let .restore(id):
            guard let root = try Item.fetchOne(db, key: id), let deletedAt = root.deletedAt else { return }
            var stack = [id]
            while let cur = stack.popLast() {
                try db.execute(sql: "UPDATE items SET deleted_at = NULL, updated_at = ? WHERE id = ?", arguments: [stamp, cur])
                stack += try String.fetchAll(db, sql: "SELECT id FROM items WHERE parent_id = ? AND deleted_at = ?", arguments: [cur, deletedAt])
            }
        case .opened:
            return
        }
    }

    // MARK: Sync

    /// Forgets everything: used when the app points at a different backend.
    public func resetAll() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM items; DELETE FROM pending_ops; DELETE FROM meta WHERE key = 'version'")
        }
    }

    /// Full resync: the server's items become the truth. Local rows the server does not have are removed,
    /// except items created locally that are still waiting to be sent.
    @discardableResult
    public func replaceAll(_ serverItems: [Item], version: Int) throws -> [Item] {
        let fresh = try merge(serverItems, version: version)
        try db.write { db in
            let serverIds = Set(serverItems.map(\.id))
            let pendingCreates = Set(try String.fetchAll(db, sql: "SELECT item_id FROM pending_ops WHERE item_id IS NOT NULL AND payload LIKE '%\"op\":\"create\"%'"))
            for id in try String.fetchAll(db, sql: "SELECT id FROM items") where !serverIds.contains(id) && !pendingCreates.contains(id) {
                try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
            }
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('version', ?)", arguments: [String(version)])
        }
        return fresh
    }

    /// Drops acknowledged ops (everything up to and including `pendingId`).
    public func ack(upTo pendingId: Int64) throws {
        try db.write { try $0.execute(sql: "DELETE FROM pending_ops WHERE id <= ?", arguments: [pendingId]) }
    }

    /// Drops one op the backend rejected, so it cannot block the queue.
    public func drop(_ pendingId: Int64) throws {
        try db.write { try $0.execute(sql: "DELETE FROM pending_ops WHERE id = ?", arguments: [pendingId]) }
    }

    /// Merges server items. Columns with a pending local change keep the local value. Returns agent items seen for the first time.
    @discardableResult
    public func merge(_ serverItems: [Item], version: Int) throws -> [Item] {
        try db.write { db in
            var fresh: [Item] = []
            var touched: [String: Set<String>] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT item_id, columns FROM pending_ops WHERE item_id IS NOT NULL") {
                let cols = (row["columns"] as String).split(separator: ",").map(String.init)
                touched[row["item_id"], default: []].formUnion(cols)
            }
            for s in serverItems {
                guard var local = try Item.fetchOne(db, key: s.id) else {
                    try s.insert(db)
                    if s.isUnseenAgentItem { fresh.append(s) }
                    continue
                }
                let keep = touched[s.id] ?? []
                if !keep.contains("parent_id") { local.parentId = s.parentId }
                if !keep.contains("position") { local.position = s.position }
                if !keep.contains("text") { local.text = s.text }
                if !keep.contains("note") { local.note = s.note }
                if !keep.contains("completed_at") { local.completedAt = s.completedAt }
                if !keep.contains("collapsed") { local.collapsed = s.collapsed }
                if !keep.contains("seen_at") { local.seenAt = s.seenAt }
                if !keep.contains("deleted_at") { local.deletedAt = s.deletedAt }
                if !keep.contains("when_date") { local.whenDate = s.whenDate }
                if !keep.contains("deadline") { local.deadline = s.deadline }
                if !keep.contains("icon") { local.icon = s.icon }
                if !keep.contains("color") { local.color = s.color }
                local.createdBy = s.createdBy
                local.createdAt = s.createdAt
                local.updatedAt = s.updatedAt
                local.version = s.version
                try local.update(db)
            }
            let current = try Int.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'version'") ?? 0
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('version', ?)", arguments: [String(max(current, version))])
            return fresh
        }
    }
}
