import Foundation

/// A read-only snapshot of the live tree, indexed for the editor and the views.
public struct Outline: Sendable {
    public let byId: [String: Item]
    private let kids: [String: [Item]]
    private let roots: [Item]

    public init(items: [Item]) {
        var byId: [String: Item] = [:]
        var kids: [String: [Item]] = [:]
        var roots: [Item] = []
        for it in items where it.deletedAt == nil {
            byId[it.id] = it
            if let p = it.parentId { kids[p, default: []].append(it) } else { roots.append(it) }
        }
        let order: (Item, Item) -> Bool = { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
        self.byId = byId
        self.kids = kids.mapValues { $0.sorted(by: order) }
        self.roots = roots.sorted(by: order)
    }

    public func item(_ id: String) -> Item? { byId[id] }

    /// Live children in display order (top-level lists when `id` is nil).
    public func children(of id: String?) -> [Item] {
        guard let id else { return roots }
        return kids[id] ?? []
    }

    public var lists: [Item] { roots }

    public struct Row: Identifiable, Equatable, Sendable {
        public let item: Item
        public let depth: Int
        public let hasChildren: Bool
        /// A list-name heading (Today grouped by list), not an editable row.
        public var isSection = false
        public var id: String { isSection ? "section:" + item.id : item.id }
        public init(item: Item, depth: Int, hasChildren: Bool) {
            self.item = item
            self.depth = depth
            self.hasChildren = hasChildren
        }
    }

    /// Rows to draw under `root`, depth-first, skipping collapsed subtrees and completed rows
    /// (unless `showCompleted`, or the row is in `keep`, which holds rows still fading out).
    public func rows(under root: String, showCompleted: Bool, keep: Set<String>) -> [Row] {
        var out: [Row] = []
        var visited: Set<String> = [root]
        func walk(_ id: String, _ depth: Int) {
            for c in children(of: id) where visited.insert(c.id).inserted {
                if c.isCompleted && !showCompleted && !keep.contains(c.id) { continue }
                let has = !children(of: c.id).isEmpty
                out.append(Row(item: c, depth: depth, hasChildren: has))
                if has && !c.collapsed { walk(c.id, depth + 1) }
            }
        }
        walk(root, 0)
        return out
    }

    /// Ancestors from the top-level list down to the parent of `id`.
    public func path(to id: String) -> [Item] {
        var out: [Item] = []
        var seen: Set<String> = [id]
        var cur = byId[id]?.parentId
        while let c = cur, let it = byId[c], seen.insert(c).inserted {
            out.insert(it, at: 0)
            cur = it.parentId
        }
        return out
    }

    public func rootList(of id: String) -> Item? {
        var cur = byId[id]
        var seen: Set<String> = [id]
        while let c = cur, let p = c.parentId, seen.insert(p).inserted { cur = byId[p] }
        return cur
    }

    /// Open (not completed) descendants count.
    public func openCount(under id: String) -> Int {
        var seen: Set<String> = [id]
        func count(_ id: String) -> Int {
            children(of: id).reduce(0) { n, c in
                guard seen.insert(c.id).inserted else { return n }
                return n + (c.isCompleted ? 0 : 1 + count(c.id))
            }
        }
        return count(id)
    }

    public var unseenAgentItems: [Item] { byId.values.filter(\.isUnseenAgentItem) }

    // MARK: Today and tags

    public struct TodayGroup: Sendable {
        public let list: Item
        public let items: [Item]
    }

    func inToday(_ i: Item, _ day: String, keep: Set<String> = []) -> Bool {
        guard !i.isList, !i.isCompleted || keep.contains(i.id) else { return false }
        return (i.whenDate.map { $0 <= day } ?? false) || (i.deadline.map { $0 <= day } ?? false)
    }

    /// Things' Today: open items starred for `day` or earlier, or due by `day`, grouped by list in outline order.
    public func today(_ day: String, keep: Set<String> = []) -> [TodayGroup] {
        roots.compactMap { list in
            let hits = descendants(of: list.id).filter { inToday($0, day, keep: keep) }
            return hits.isEmpty ? nil : TodayGroup(list: list, items: hits)
        }
    }

    public func todayCount(_ day: String) -> Int { today(day).reduce(0) { $0 + $1.items.count } }

    /// Every item, across all lists, carrying `tag` (without the #), in outline order.
    /// `keep`: rows that stay although they no longer match (the one being edited).
    public func tagged(_ tag: String, keep: Set<String> = []) -> [Item] {
        let t = tag.lowercased()
        return roots.flatMap { descendants(of: $0.id) }.filter { keep.contains($0.id) || Tags.in($0.text).contains(t) }
    }

    /// Items with a tag starting with `prefix` (what the filter shows while `#80` is being typed).
    public func tagged(prefix: String, keep: Set<String> = []) -> [Item] {
        let p = prefix.lowercased()
        return roots.flatMap { descendants(of: $0.id) }.filter { keep.contains($0.id) || Tags.in($0.text).contains { $0.hasPrefix(p) } }
    }

    /// Tags in use, most used first, then alphabetical.
    public var allTags: [String] {
        var counts: [String: Int] = [:]
        for i in byId.values where i.deletedAt == nil && !i.isList { for t in Tags.in(i.text) { counts[t, default: 0] += 1 } }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// Depth-first descendants in outline order (loop-guarded).
    func descendants(of id: String) -> [Item] {
        var out: [Item] = []
        var seen: Set<String> = [id]
        func walk(_ p: String) {
            for c in children(of: p) where !seen.contains(c.id) {
                seen.insert(c.id)
                out.append(c)
                walk(c.id)
            }
        }
        walk(id)
        return out
    }
}
