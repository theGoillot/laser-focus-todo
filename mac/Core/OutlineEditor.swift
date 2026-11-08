import Foundation

/// Turns editing intents into ops, applies them to the local store, and keeps my own undo history.
/// Only actions taken through the editor are undoable; agent changes never are.
public final class OutlineEditor: @unchecked Sendable {
    private let store: LocalStore
    private let now: () -> Date
    private var undoStack: [[Op]] = []   // each entry: the ops that invert one action
    private var redoStack: [[Op]] = []
    public var onChange: (() -> Void)?

    public init(store: LocalStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    private func snapshot() throws -> Outline { Outline(items: try store.liveItems()) }

    /// Applies `ops` and records `inverse` as one undo step.
    private func commit(_ ops: [Op], inverse: [Op]) throws {
        guard !ops.isEmpty else { return }
        try store.apply(ops, now: now())
        undoStack.append(inverse)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        onChange?()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() throws {
        guard let inverse = undoStack.popLast() else { return }
        let o = try snapshot()
        let redo = try inverse.reversed().flatMap { try invert($0, in: o) }
        try store.apply(inverse, now: now())
        redoStack.append(redo)
        onChange?()
    }

    public func redo() throws {
        guard let ops = redoStack.popLast() else { return }
        let o = try snapshot()
        let back = try ops.reversed().flatMap { try invert($0, in: o) }
        try store.apply(ops, now: now())
        undoStack.append(back)
        onChange?()
    }

    /// The op that undoes `op`, given the tree before `op` runs.
    private func invert(_ op: Op, in o: Outline) throws -> [Op] {
        switch op {
        case let .create(id, _, _, _, _): return [.delete(id: id)]
        case let .delete(id): return [.restore(id: id)]
        case let .restore(id): return [.delete(id: id)]
        case let .complete(id, done): return [.complete(id: id, done: !done)]
        case let .move(id, _, _):
            guard let it = try o.item(id) ?? store.item(id) else { return [] }
            return [.move(id: id, parentId: it.parentId, position: it.position)]
        case let .update(id, f):
            guard let it = try o.item(id) ?? store.item(id) else { return [] }
            var back = ItemFields()
            if f.text != nil { back.text = it.text }
            if f.note != nil { back.note = .some(it.note) }
            if f.collapsed != nil { back.collapsed = it.collapsed }
            if f.seenAt != nil { back.seenAt = .some(it.seenAt) }
            if f.whenDate != nil { back.whenDate = .some(it.whenDate) }
            if f.deadline != nil { back.deadline = .some(it.deadline) }
            if f.icon != nil { back.icon = .some(it.icon) }
            if f.color != nil { back.color = .some(it.color) }
            return [.update(id: id, fields: back)]
        case .opened: return []
        }
    }

    private func run(_ ops: [Op]) throws {
        let o = try snapshot()
        let inverse = try ops.reversed().flatMap { try invert($0, in: o) }
        try commit(ops, inverse: inverse)
    }

    /// A key between two neighbours that tolerates tied or out-of-order positions.
    static func key(between a: String?, _ b: String?) -> String {
        if let a, let b, a >= b { return (try? FractionalIndex.between(a, nil)) ?? a + "V" }
        return (try? FractionalIndex.between(a, b)) ?? (try? FractionalIndex.between(a, nil)) ?? "a0"
    }

    // MARK: Intents

    /// Return on `id`: a new first child if `id` is expanded with children, else a sibling right below. Returns the new id.
    @discardableResult
    public func newItem(after id: String, text: String = "") throws -> String {
        let o = try snapshot()
        guard let it = o.item(id) else { throw OutlineError.missing(id) }
        let kids = o.children(of: id)
        if !kids.isEmpty && !it.collapsed {
            return try insert(in: id, at: Self.key(between: nil, kids.first?.position), text: text)
        }
        let sibs = o.children(of: it.parentId)
        let next = sibs.firstIndex(where: { $0.id == id }).flatMap { $0 + 1 < sibs.count ? sibs[$0 + 1] : nil }
        return try insert(in: it.parentId, at: Self.key(between: it.position, next?.position), text: text)
    }

    /// A new sibling directly above `id` (Return at the start of a row).
    @discardableResult
    public func newItem(before id: String, text: String = "") throws -> String {
        let o = try snapshot()
        guard let it = o.item(id) else { throw OutlineError.missing(id) }
        let sibs = o.children(of: it.parentId)
        let prev = sibs.firstIndex(where: { $0.id == id }).flatMap { $0 > 0 ? sibs[$0 - 1] : nil }
        return try insert(in: it.parentId, at: Self.key(between: prev?.position, it.position), text: text)
    }

    /// Adds an item at the end of `parent` (used for an empty list or "add below everything").
    @discardableResult
    public func newItem(in parent: String, text: String = "", when: String? = nil) throws -> String {
        let last = try snapshot().children(of: parent).last
        return try insert(in: parent, at: Self.key(between: last?.position, nil), text: text, when: when)
    }

    /// Adds an item at the top of `parent`.
    @discardableResult
    public func newItem(atTopOf parent: String, text: String = "") throws -> String {
        let first = try snapshot().children(of: parent).first
        return try insert(in: parent, at: Self.key(between: nil, first?.position), text: text)
    }

    /// A new top-level list at the end.
    @discardableResult
    public func newList(named name: String, icon: String? = nil, color: String? = nil) throws -> String {
        let last = try snapshot().lists.last
        let style = icon != nil || color != nil ? ItemFields(icon: .some(icon), color: .some(color)) : nil
        return try insert(in: nil, at: Self.key(between: last?.position, nil), text: name, extra: style)
    }

    /// A list's icon and color (one undo step).
    public func setStyle(_ id: String, icon: String?, color: String?) throws {
        guard let it = try store.item(id), it.icon != icon || it.color != color else { return }
        try run([.update(id: id, fields: ItemFields(icon: .some(icon), color: .some(color)))])
    }

    /// One undo step even when the new item also gets a When day (added from the Today view).
    private func insert(in parent: String?, at position: String, text: String, when: String? = nil, extra: ItemFields? = nil) throws -> String {
        let id = UUID().uuidString.lowercased()
        let (fit, overflow) = TextLimit.fit(text)
        var ops: [Op] = [.create(id: id, parentId: parent, position: position, text: fit, note: overflow)]
        if let when { ops.append(.update(id: id, fields: ItemFields(whenDate: .some(when)))) }
        if let extra { ops.append(.update(id: id, fields: extra)) }
        try run(ops)
        return id
    }

    /// Tab: becomes the last child of the sibling above, which expands.
    public func indent(_ id: String) throws {
        let o = try snapshot()
        guard let it = o.item(id) else { return }
        let sibs = o.children(of: it.parentId)
        guard let i = sibs.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let target = sibs[i - 1]
        var ops: [Op] = [.move(id: id, parentId: target.id, position: Self.key(between: o.children(of: target.id).last?.position, nil))]
        if target.collapsed { ops.append(.update(id: target.id, fields: ItemFields(collapsed: false))) }
        try run(ops)
    }

    /// Shift-Tab: moves right after its parent, unless the parent is `floor` (the list or zoomed item on screen).
    public func outdent(_ id: String, floor: String) throws {
        let o = try snapshot()
        guard let it = o.item(id), let pid = it.parentId, pid != floor, let parent = o.item(pid), parent.parentId != nil else { return }
        let sibs = o.children(of: parent.parentId)
        let next = sibs.firstIndex(where: { $0.id == pid }).flatMap { $0 + 1 < sibs.count ? sibs[$0 + 1] : nil }
        try run([.move(id: id, parentId: parent.parentId, position: Self.key(between: parent.position, next?.position))])
    }

    public func moveUp(_ id: String) throws { try shift(id, by: -1) }
    public func moveDown(_ id: String) throws { try shift(id, by: 1) }

    private func shift(_ id: String, by d: Int) throws {
        let o = try snapshot()
        guard let it = o.item(id) else { return }
        let sibs = o.children(of: it.parentId)
        guard let i = sibs.firstIndex(where: { $0.id == id }) else { return }
        let j = i + d
        guard sibs.indices.contains(j) else { return }
        let pos: String
        if d < 0 {
            pos = Self.key(between: j > 0 ? sibs[j - 1].position : nil, sibs[j].position)
        } else {
            pos = Self.key(between: sibs[j].position, j + 1 < sibs.count ? sibs[j + 1].position : nil)
        }
        try run([.move(id: id, parentId: it.parentId, position: pos)])
    }

    /// Moves an item to another parent at the end (Move to...).
    public func move(_ id: String, to parent: String) throws {
        let o = try snapshot()
        guard id != parent, !o.path(to: parent).contains(where: { $0.id == id }) else { return }
        try run([.move(id: id, parentId: parent, position: Self.key(between: o.children(of: parent).last?.position, nil))])
    }

    public func toggleComplete(_ id: String) throws {
        guard let it = try store.item(id) else { return }
        try run([.complete(id: id, done: !it.isCompleted)])
    }

    public func delete(_ id: String) throws { try run([.delete(id: id)]) }

    public func setText(_ id: String, _ text: String) throws {
        let (fit, overflow) = TextLimit.fit(text)
        guard let it = try store.item(id), it.text != fit || overflow != nil else { return }
        var fields = ItemFields(text: fit)
        if let overflow {
            let note = [overflow, it.note].compactMap { $0 }.joined(separator: "\n\n")
            fields.note = .some(TextLimit.fitNote(note))
        }
        try run([.update(id: id, fields: fields)])
    }

    public func setNote(_ id: String, _ note: String?) throws {
        guard let it = try store.item(id), it.note != note else { return }
        try run([.update(id: id, fields: ItemFields(note: .some(note)))])
    }

    public func toggleCollapsed(_ id: String) throws {
        guard let it = try store.item(id) else { return }
        try run([.update(id: id, fields: ItemFields(collapsed: !it.collapsed))])
    }

    public func setCollapsed(_ id: String, _ collapsed: Bool) throws {
        guard let it = try store.item(id), it.collapsed != collapsed else { return }
        try run([.update(id: id, fields: ItemFields(collapsed: collapsed))])
    }

    /// Things' Cmd-T: stars the item for today, or clears the When day if it is already in Today.
    public func toggleToday(_ id: String, today: String) throws {
        guard let it = try store.item(id) else { return }
        let inToday = it.whenDate.map { $0 <= today } ?? false
        try setWhen(id, inToday ? nil : today)
    }

    public func setWhen(_ id: String, _ day: String?) throws {
        guard let it = try store.item(id), it.whenDate != day else { return }
        try run([.update(id: id, fields: ItemFields(whenDate: .some(day)))])
    }

    public func setDeadline(_ id: String, _ day: String?) throws {
        guard let it = try store.item(id), it.deadline != day else { return }
        try run([.update(id: id, fields: ItemFields(deadline: .some(day)))])
    }

    /// Marks agent items as seen. Not an undo step: it is bookkeeping, not an edit.
    public func markSeen(_ ids: [String]) throws {
        let stamp = Clock.string(now())
        let ops: [Op] = try ids.compactMap { id in
            guard let it = try store.item(id), it.isUnseenAgentItem else { return nil }
            return .update(id: id, fields: ItemFields(seenAt: .some(stamp)))
        }
        guard !ops.isEmpty else { return }
        try store.apply(ops, now: now())
        onChange?()
    }

    /// Logs that the panel opened (trial metric).
    public func logOpened() throws { try store.apply(.opened, now: now()) }
}

/// The backend counts UTF-16 units: 2,000 for text, 10,000 for notes. Overflowing text moves to the note so nothing is lost.
public enum TextLimit {
    public static let text = 2000
    public static let note = 10000

    public static func fit(_ s: String) -> (String, String?) {
        guard s.utf16.count > text else { return (s, nil) }
        var cut = s.startIndex
        var units = 0
        for i in s.indices {
            let n = s[i].utf16.count
            if units + n > text { break }
            units += n
            cut = s.index(after: i)
        }
        return (String(s[..<cut]), fitNote(String(s[cut...])))
    }

    public static func fitNote(_ s: String) -> String {
        guard s.utf16.count > note else { return s }
        var out = ""
        for ch in s {
            if out.utf16.count + ch.utf16.count > note { break }
            out.append(ch)
        }
        return out
    }
}

public enum OutlineError: Error {
    case missing(String)
}
