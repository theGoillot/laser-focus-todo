import Foundation
import GRDB

/// Who made a change. Matches the backend's `"me" | "agent"`.
public enum Author: String, Codable, Sendable, DatabaseValueConvertible {
    case me
    case agent
}

/// One bullet of the outline. A top-level item (no parent) is a list. Mirrors the backend row.
public struct Item: Codable, Equatable, Hashable, Identifiable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"

    public var id: String
    public var parentId: String?
    public var position: String
    public var text: String
    public var note: String?
    public var completedAt: String?
    public var collapsed: Bool
    public var createdBy: Author
    public var seenAt: String?
    public var createdAt: String
    public var updatedAt: String
    public var deletedAt: String?
    public var version: Int
    /// Things-style "When" day (YYYY-MM-DD): the item shows in Today from that day on.
    public var whenDate: String?
    public var deadline: String?
    /// List style (top-level items): SF Symbol name and palette color name.
    public var icon: String?
    public var color: String?

    enum CodingKeys: String, CodingKey, ColumnExpression {
        case id, position, text, note, collapsed, version
        case parentId = "parent_id"
        case completedAt = "completed_at"
        case createdBy = "created_by"
        case seenAt = "seen_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case whenDate = "when_date"
        case deadline, icon, color
    }

    public init(id: String, parentId: String?, position: String, text: String, note: String?, completedAt: String?, collapsed: Bool,
                createdBy: Author, seenAt: String?, createdAt: String, updatedAt: String, deletedAt: String?, version: Int,
                whenDate: String? = nil, deadline: String? = nil, icon: String? = nil, color: String? = nil) {
        self.id = id
        self.parentId = parentId
        self.position = position
        self.text = text
        self.note = note
        self.completedAt = completedAt
        self.collapsed = collapsed
        self.createdBy = createdBy
        self.seenAt = seenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.version = version
        self.whenDate = whenDate
        self.deadline = deadline
        self.icon = icon
        self.color = color
    }

    public var isCompleted: Bool { completedAt != nil }
    public var isList: Bool { parentId == nil }
    /// An agent item I have not looked at yet: shows the tag and the menu bar dot.
    public var isUnseenAgentItem: Bool { createdBy == .agent && seenAt == nil && deletedAt == nil }
}

/// Fields an `update` op may change. `nil` means "not touched"; `.some(nil)` clears a nullable field.
public struct ItemFields: Codable, Equatable, Sendable {
    public var text: String?
    public var note: String??
    public var collapsed: Bool?
    public var seenAt: String??
    public var whenDate: String??
    public var deadline: String??
    public var icon: String??
    public var color: String??

    public init(text: String? = nil, note: String?? = nil, collapsed: Bool? = nil, seenAt: String?? = nil,
                whenDate: String?? = nil, deadline: String?? = nil, icon: String?? = nil, color: String?? = nil) {
        self.text = text
        self.note = note
        self.collapsed = collapsed
        self.seenAt = seenAt
        self.whenDate = whenDate
        self.deadline = deadline
        self.icon = icon
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case text, note, collapsed, deadline, icon, color
        case seenAt = "seen_at"
        case whenDate = "when_date"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let text { try c.encode(text, forKey: .text) }
        if let note { try c.encode(note, forKey: .note) }
        if let collapsed { try c.encode(collapsed, forKey: .collapsed) }
        if let seenAt { try c.encode(seenAt, forKey: .seenAt) }
        if let whenDate { try c.encode(whenDate, forKey: .whenDate) }
        if let deadline { try c.encode(deadline, forKey: .deadline) }
        if let icon { try c.encode(icon, forKey: .icon) }
        if let color { try c.encode(color, forKey: .color) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        note = c.contains(.note) ? .some(try c.decodeNil(forKey: .note) ? nil : try c.decode(String.self, forKey: .note)) : nil
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed)
        seenAt = try Self.nullable(c, .seenAt)
        whenDate = try Self.nullable(c, .whenDate)
        deadline = try Self.nullable(c, .deadline)
        icon = try Self.nullable(c, .icon)
        color = try Self.nullable(c, .color)
    }

    private static func nullable(_ c: KeyedDecodingContainer<CodingKeys>, _ k: CodingKeys) throws -> String?? {
        guard c.contains(k) else { return nil }
        return .some(try c.decodeNil(forKey: k) ? nil : try c.decode(String.self, forKey: k))
    }

    /// Column names this update touches.
    public var columns: [String] {
        var out: [String] = []
        if text != nil { out.append("text") }
        if note != nil { out.append("note") }
        if collapsed != nil { out.append("collapsed") }
        if seenAt != nil { out.append("seen_at") }
        if whenDate != nil { out.append("when_date") }
        if deadline != nil { out.append("deadline") }
        if icon != nil { out.append("icon") }
        if color != nil { out.append("color") }
        return out
    }
}

/// A change the Mac sends to the backend. Encodes to exactly the backend's `Op` JSON.
public enum Op: Codable, Equatable, Sendable {
    case create(id: String, parentId: String?, position: String, text: String, note: String?)
    case update(id: String, fields: ItemFields)
    case move(id: String, parentId: String?, position: String)
    case complete(id: String, done: Bool)
    case delete(id: String)
    case restore(id: String)
    case opened

    enum Keys: String, CodingKey { case op, id, item, fields, done, position, parent_id }
    enum ItemKeys: String, CodingKey { case id, parent_id, position, text, note }

    public var itemId: String? {
        switch self {
        case let .create(id, _, _, _, _), let .update(id, _), let .move(id, _, _), let .complete(id, _), let .delete(id), let .restore(id): id
        case .opened: nil
        }
    }

    /// Item columns this op changes; pulled server values for these wait until the op is acknowledged.
    public var touchedColumns: [String] {
        switch self {
        case .create: ["parent_id", "position", "text", "note", "completed_at", "collapsed", "seen_at", "deleted_at"]
        case let .update(_, f): f.columns
        case .move: ["parent_id", "position"]
        case .complete: ["completed_at"]
        case .delete, .restore: ["deleted_at"]
        case .opened: []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .create(id, parentId, position, text, note):
            try c.encode("create", forKey: .op)
            var i = c.nestedContainer(keyedBy: ItemKeys.self, forKey: .item)
            try i.encode(id, forKey: .id)
            try i.encode(parentId, forKey: .parent_id)
            try i.encode(position, forKey: .position)
            try i.encode(text, forKey: .text)
            try i.encode(note, forKey: .note)
        case let .update(id, fields):
            try c.encode("update", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(fields, forKey: .fields)
        case let .move(id, parentId, position):
            try c.encode("move", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(parentId, forKey: .parent_id)
            try c.encode(position, forKey: .position)
        case let .complete(id, done):
            try c.encode("complete", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(done, forKey: .done)
        case let .delete(id):
            try c.encode("delete", forKey: .op)
            try c.encode(id, forKey: .id)
        case let .restore(id):
            try c.encode("restore", forKey: .op)
            try c.encode(id, forKey: .id)
        case .opened:
            try c.encode("opened", forKey: .op)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .op) {
        case "create":
            let i = try c.nestedContainer(keyedBy: ItemKeys.self, forKey: .item)
            self = .create(id: try i.decode(String.self, forKey: .id), parentId: try i.decodeIfPresent(String.self, forKey: .parent_id),
                           position: try i.decode(String.self, forKey: .position), text: try i.decode(String.self, forKey: .text),
                           note: try i.decodeIfPresent(String.self, forKey: .note))
        case "update": self = .update(id: try c.decode(String.self, forKey: .id), fields: try c.decode(ItemFields.self, forKey: .fields))
        case "move": self = .move(id: try c.decode(String.self, forKey: .id), parentId: try c.decodeIfPresent(String.self, forKey: .parent_id),
                                  position: try c.decode(String.self, forKey: .position))
        case "complete": self = .complete(id: try c.decode(String.self, forKey: .id), done: try c.decode(Bool.self, forKey: .done))
        case "delete": self = .delete(id: try c.decode(String.self, forKey: .id))
        case "restore": self = .restore(id: try c.decode(String.self, forKey: .id))
        case "opened": self = .opened
        case let other: throw DecodingError.dataCorruptedError(forKey: .op, in: c, debugDescription: "unknown op \(other)")
        }
    }
}

public struct SyncResponse: Codable, Sendable, Equatable {
    public var version: Int
    public var items: [Item]
    /// Echoed by a push sent with a cursor: `items` then hold everything newer than it, so no pull is needed.
    public var since: Int?
    public init(version: Int, items: [Item], since: Int? = nil) {
        self.version = version
        self.items = items
        self.since = since
    }
}

enum Clock {
    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func string(_ d: Date) -> String { iso.string(from: d) }
    static func date(_ s: String) -> Date? { iso.date(from: s) }
}
