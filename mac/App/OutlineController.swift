import AppKit
import Combine
import TodoCore

/// The outline: a table of flattened rows plus a ghost "New to-do" row at the end for fast capture.
/// Every keystroke goes to the local store; the table updates in place so editing never jumps.
@MainActor
final class OutlineController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let ghostId = "__new__"
    /// QA harness: its typing has no key event, but should get tag suggestions like the keyboard.
    nonisolated(unsafe) static var assumeTyping = false

    let model: AppModel
    let table = NSTableView()
    let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private var rows: [Outline.Row] = []
    private var cancellables: Set<AnyCancellable> = []
    private var reloadScheduled = false
    /// Where the cursor goes once that row exists. Kept until the row shows up (the store may notify a moment later).
    private var pendingFocus: (id: String, caret: Int?)? {
        didSet { pendingFocusSetAt = Date() }
    }
    private var pendingFocusSetAt = Date()
    private var textTimers: [String: Timer] = [:]
    /// Rows with typing not yet written to the store. Only these are ever committed, so leaving a row
    /// can never write stale text over a newer change (from the agent, or from undo).
    private var dirty: Set<String> = []
    /// What is typed in the ghost row, kept across reloads until it becomes an item.
    private var ghostDraft = ""
    /// Notes with typing not yet saved.
    private var dirtyNotes: Set<String> = []
    private var noteTimers: [String: Timer] = [:]
    /// The row whose note is open for editing (it gets room for the note even when empty).
    private var noteEditingId: String?
    /// Note text being typed, by item. Heights are measured from this (never from cells: AppKit forbids that mid-layout).
    private var noteDrafts: [String: String] = [:]
    private var heights: [CGFloat] = []
    private var completing = false
    var onEscape: (() -> Void)?
    /// True while the date picker covers the list: no row may grab the keyboard from it.
    var suspendFocus = false
    /// Opens the When or Deadline picker for an item.
    var onPickDate: ((String, DateKind) -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = Theme.rowHeight
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("To-dos")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 10, right: 0)

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.isHidden = true

        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.topAnchor.constraint(equalTo: root.topAnchor, constant: 90),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.objectWillChange.sink { [weak self] _ in self?.scheduleReload() }.store(in: &cancellables)
        reload()
    }

    // MARK: Data

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    private var editingField: RowTextField? {
        guard let tv = view.window?.firstResponder as? NSTextView, tv.isFieldEditor else { return nil }
        return tv.delegate as? RowTextField
    }

    private var editingId: String? {
        guard let field = editingField, let cell = field.superview as? RowCellView else { return nil }
        return cell.itemId ?? Self.ghostId
    }

    private var editingNote: Bool { editingField?.role == .note }

    private func context(for row: Outline.Row) -> RowContext {
        let virtual = model.isVirtual || model.filter.hasPrefix("#")
        let grouped = model.mode == .today && Prefs.shared.groupToday
        return RowContext(agentName: model.agentName, today: model.today, showStar: model.mode != .today,
                          listName: virtual && !grouped ? model.listName(of: row.id) : nil,
                          noteEditing: noteEditingId == row.id)
    }

    // MARK: Heights

    private func height(for row: Outline.Row) -> CGFloat {
        if row.isSection { return Theme.rowHeight + 4 }
        let note = (row.item.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let editing = noteEditingId == row.id
        guard !note.isEmpty || editing else { return Theme.rowHeight }
        let width = max(80, table.bounds.width - RowCellView.textLeading(depth: row.depth) - Theme.sidePadding - 4)
        let text = editing ? (noteDrafts[row.id] ?? row.item.note ?? "") : note
        let measured = (text.isEmpty ? " " : text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Theme.noteFont]).height
        let lines = min(editing ? 8 : 2, max(1, Int((measured / Theme.noteLineHeight).rounded(.up))))
        return Theme.rowHeight + CGFloat(lines) * Theme.noteLineHeight - 2
    }

    private func liveNoteText(_ id: String) -> String? {
        guard let i = index(of: id), let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? RowCellView else { return nil }
        return (cell.noteField.currentEditor() as? NSTextView)?.string ?? cell.noteField.stringValue
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        row < rows.count ? height(for: rows[row]) : Theme.rowHeight
    }

    /// Re-measures rows (notes changed, text size changed) without reloading cells.
    private func refreshHeights() {
        let new = rows.map(height(for:))
        let changed = IndexSet(new.indices.filter { $0 >= heights.count || heights[$0] != new[$0] })
        heights = new
        if !changed.isEmpty {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                table.noteHeightOfRows(withIndexesChanged: changed)
            }
        }
    }

    var contentHeight: CGFloat {
        rows.map(height(for:)).reduce(0, +) + (numberOfRows(in: table) > rows.count ? Theme.rowHeight : 0)
    }

    func reload() {
        let newRows = model.rows
        let editing = editingId
        let caret = (view.window?.firstResponder as? NSTextView)?.selectedRange().location
        if newRows.map(\.id) == rows.map(\.id) {
            rows = newRows
            // Same shape: refresh visible cells in place, never touching the text being typed.
            for i in 0..<rows.count {
                guard let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? RowCellView else { continue }
                let id = rows[i].id
                let isEditing = id == editing
                let titleEditing = isEditing && !editingNote
                cell.configure(rows[i], context: context(for: rows[i]), updateText: !titleEditing && !dirty.contains(id))
                // A focused row with no unsaved typing shows the store's text (agent edits, undo), keeping the caret.
                if titleEditing, !dirty.contains(id), cell.field.stringValue != rows[i].item.text {
                    setFieldText(id, rows[i].item.text, caret: caret)
                }
            }
            if hasGhost, editing != Self.ghostId, let g = table.view(atColumn: 0, row: rows.count, makeIfNecessary: false) as? RowCellView {
                configureGhost(g)
            }
            refreshHeights()
        } else {
            if pendingFocus == nil, let e = editing { pendingFocus = (e, caret) }
            // End the edit before cells are recycled, so a field editor can never stay attached to a reused cell.
            let wasNote = editingNote
            if editing != nil { view.window?.makeFirstResponder(nil) }
            if wasNote, let e = editing { pendingNoteFocus = e }
            rows = newRows
            heights = rows.map(height(for:))
            table.reloadData()
        }
        updateEmptyState()
        if suspendFocus { updateRowHighlights(); return }
        if let n = pendingNoteFocus {
            pendingNoteFocus = nil
            if index(of: n) != nil { pendingFocus = nil; focusNote(n) }
        }
        if let f = pendingFocus {
            if index(of: f.id) != nil {
                pendingFocus = nil
                focus(f.id, caret: f.caret)
            } else if Date().timeIntervalSince(pendingFocusSetAt) > 2 {
                pendingFocus = nil
            }
        }
        updateRowHighlights()
    }

    private var pendingNoteFocus: String?

    private func updateEmptyState() {
        let message: String
        if !model.filter.isEmpty { message = "No matches" }
        else if model.mode == .today { message = "Nothing for today. Star a to-do with ⌘T." }
        else if case .tag = model.mode { message = "No to-dos with this tag." }
        else { message = "" }
        empty.isHidden = !(rows.isEmpty && !message.isEmpty)
        empty.stringValue = message
    }

    private var hasGhost: Bool {
        guard model.filter.isEmpty else { return false }
        return model.isVirtual ? model.inbox != nil : model.floorId != nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count + (hasGhost ? 1 : 0) }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { OutlineRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("row"), owner: nil) as? RowCellView) ?? {
            let c = RowCellView()
            c.identifier = .init("row")
            return c
        }()
        cell.field.delegate = self
        cell.noteField.delegate = self
        if row == rows.count {
            configureGhost(cell)
            return cell
        }
        let r = rows[row]
        cell.configure(r, context: context(for: r), updateText: true)
        cell.field.placeholderAttributedString = nil
        if r.isSection {
            cell.onTick = nil
            cell.menu = nil
            cell.field.onFocus = nil
            return cell
        }
        cell.field.onTagClick = { [weak self] tag in self?.commitAll(); self?.model.showTag(tag) }
        cell.noteField.onFocus = { [weak self, weak cell] in
            guard let self else { return }
            self.model.editingId = r.id
            self.noteEditingId = r.id
            self.noteDrafts[r.id] = cell?.noteField.stringValue
            cell?.noteField.maximumNumberOfLines = 0
            self.refreshHeights()
            self.updateRowHighlights()
        }
        cell.checkbox.isHidden = false
        cell.checkbox.isAddMarker = false
        let id = r.id
        cell.onTick = { [weak self] in self?.tick(id) }
        cell.onToggleCollapse = { [weak self] in
            self?.commitText(id)
            try? self?.model.editor.toggleCollapsed(id)
        }
        cell.field.onFocus = { [weak self] in
            self?.model.editingId = id
            try? self?.model.editor.markSeen([id])
            self?.updateRowHighlights()
        }
        cell.menu = contextMenu(for: id)
        return cell
    }

    private func configureGhost(_ cell: RowCellView) {
        let r = Outline.Row(item: ghostItem, depth: 0, hasChildren: false)
        cell.configure(r, context: RowContext(agentName: model.agentName, today: model.today, showStar: false, listName: nil, noteEditing: false), updateText: true)
        cell.showText(ghostDraft)
        cell.noteField.isHidden = true
        cell.field.onTagClick = nil
        let placeholder: String
        switch model.mode {
        case .today: placeholder = "New to-do for Today"
        case let .tag(t): placeholder = "New to-do with #\(t)"
        case .list: placeholder = "New to-do"
        }
        cell.field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.placeholderTextColor, .font: Theme.itemFont,
        ])
        cell.checkbox.isHidden = false
        cell.checkbox.isAddMarker = true
        cell.agentTag.isHidden = true
        cell.onTick = nil
        cell.menu = nil
        cell.field.onFocus = { [weak self] in self?.updateRowHighlights() }
    }

    private var ghostItem: Item {
        Item(id: Self.ghostId, parentId: nil, position: "", text: "", note: nil, completedAt: nil, collapsed: false, createdBy: .me,
             seenAt: nil, createdAt: "", updatedAt: "", deletedAt: nil, version: 0)
    }

    private func updateRowHighlights() {
        let e = editingId
        table.enumerateAvailableRowViews { rowView, row in
            (rowView as? OutlineRowView)?.isFocusedRow = (row < self.rows.count ? self.rows[row].id : Self.ghostId) == e && e != Self.ghostId
        }
    }

    // MARK: Focus

    func index(of id: String) -> Int? { id == Self.ghostId ? (numberOfRows(in: table) > rows.count ? rows.count : nil) : rows.firstIndex { $0.id == id } }

    /// Puts the cursor in a row. `caret` nil = end of text.
    func focus(_ id: String, caret: Int? = nil) {
        guard let i = index(of: id) else { return }
        table.scrollRowToVisible(i)
        guard let cell = table.view(atColumn: 0, row: i, makeIfNecessary: true) as? RowCellView else { return }
        view.window?.makeFirstResponder(cell.field)
        if let editor = cell.field.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.insertionPointColor = .controlAccentColor
            styleTags(editor)
            let len = (cell.field.stringValue as NSString).length
            editor.selectedRange = NSRange(location: min(caret ?? len, len), length: 0)
        }
        updateRowHighlights()
    }

    /// Opens the row's note for editing (Shift-Return), caret at the end.
    func focusNote(_ id: String) {
        guard id != Self.ghostId, let i = index(of: id) else { return }
        commitText(id)
        noteEditingId = id
        refreshHeights()
        table.scrollRowToVisible(i)
        guard let cell = table.view(atColumn: 0, row: i, makeIfNecessary: true) as? RowCellView else { return }
        cell.configure(rows[i], context: context(for: rows[i]), updateText: false)
        view.window?.makeFirstResponder(cell.noteField)
        if let editor = cell.noteField.currentEditor() as? NSTextView {
            editor.drawsBackground = false
            editor.insertionPointColor = .controlAccentColor
            editor.textColor = .secondaryLabelColor
            editor.font = Theme.noteFont
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
        updateRowHighlights()
    }

    /// Where the cursor goes when the panel opens: the ghost row, ready to type.
    func focusForOpen() {
        if model.filter.isEmpty, index(of: Self.ghostId) != nil { focus(Self.ghostId) } else if let first = rows.first { focus(first.id) }
    }

    func focusFilterResult() { if let first = rows.first { focus(first.id) } }

    /// The next editable row up or down (section headings are skipped).
    private func neighbour(of id: String, _ d: Int) -> String? {
        guard let i = index(of: id) else { return nil }
        var j = i + d
        while rows.indices.contains(j), rows[j].isSection { j += d }
        if j == rows.count, index(of: Self.ghostId) != nil { return Self.ghostId }
        return rows.indices.contains(j) ? rows[j].id : nil
    }

    // MARK: Text

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? RowTextField, let cell = field.superview as? RowCellView, let id = cell.itemId else { return }
        if field.role == .note {
            noteDrafts[id] = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            dirtyNotes.insert(id)
            noteTimers[id]?.invalidate()
            noteTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitNote(id) }
            }
            refreshHeights()
            return
        }
        suggestTags(field)
        if let tv = field.currentEditor() as? NSTextView { styleTags(tv) }
        if id == Self.ghostId {
            ghostDraft = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
            return
        }
        dirty.insert(id)
        textTimers[id]?.invalidate()
        textTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitText(id) }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? RowTextField, let cell = field.superview as? RowCellView, let id = cell.itemId else { return }
        if field.role == .note {
            commitNote(id)
            noteDrafts[id] = nil
            releaseEditing(id)
            if noteEditingId == id {
                noteEditingId = nil
                DispatchQueue.main.async { [weak self] in self?.refreshHeights() }
            }
            return
        }
        if id == Self.ghostId { return }
        if let tv = field.currentEditor() as? NSTextView { dropCompletion(tv) }
        commitText(id)
        releaseEditing(id)
        updateRowHighlights()
    }

    /// Lets a row that no longer matches its view leave, once nobody is typing in it.
    private func releaseEditing(_ id: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.editingId == id, self.editingId != id else { return }
            self.model.editingId = nil
            self.scheduleReload()
        }
    }

    /// Removes a suggestion that is still only proposed (selected, not accepted) before anything is saved.
    private func dropCompletion(_ tv: NSTextView) {
        guard let c = completion, tv.selectedRange() == c, NSMaxRange(c) <= (tv.string as NSString).length else { return }
        completion = nil
        tv.replaceCharacters(in: c, with: "")
        tv.setSelectedRange(NSRange(location: c.location, length: 0))
    }

    /// Writes the row's current text to the store now (before any structural change).
    func commitText(_ id: String) {
        textTimers[id]?.invalidate()
        textTimers[id] = nil
        guard dirty.remove(id) != nil else { return }
        guard let i = index(of: id), id != Self.ghostId,
              let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? RowCellView else { return }
        var text = cell.field.stringValue
        // A proposed tag completion is not typed text: save without it.
        if let tv = cell.field.currentEditor() as? NSTextView, let c = completion, tv.selectedRange() == c,
           NSMaxRange(c) <= (text as NSString).length {
            text = (text as NSString).replacingCharacters(in: c, with: "")
        }
        try? model.editor.setText(id, text)
    }

    func commitNote(_ id: String) {
        noteTimers[id]?.invalidate()
        noteTimers[id] = nil
        guard dirtyNotes.remove(id) != nil, let text = liveNoteText(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? model.editor.setNote(id, trimmed.isEmpty ? nil : TextLimit.fitNote(text))
    }

    func commitAll() {
        for id in Array(dirty) { commitText(id) }
        for id in Array(dirtyNotes) { commitNote(id) }
    }

    private func fieldText(_ id: String) -> (String, Int)? {
        guard let i = index(of: id), let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? RowCellView else { return nil }
        let caret = cell.field.currentEditor()?.selectedRange.location ?? (cell.field.stringValue as NSString).length
        return (cell.field.stringValue, caret)
    }

    /// Colors #tags while typing too (attributes only: the text and the undo history are untouched).
    private func styleTags(_ tv: NSTextView) {
        // Never restyle mid-composition (accents, IME): it would break the marked text.
        guard !tv.hasMarkedText(), let storage = tv.textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        // One font and color for everything (also flattens anything pasted with styles), then tag color.
        storage.setAttributes([.font: Theme.itemFont, .foregroundColor: NSColor.labelColor], range: all)
        for r in Tags.ranges(in: storage.string) where NSMaxRange(r) <= storage.length {
            storage.addAttribute(.foregroundColor, value: Theme.accent, range: r)
        }
        storage.endEditing()
        tv.typingAttributes = [.font: Theme.itemFont, .foregroundColor: NSColor.labelColor]
    }

    // MARK: Tag autocomplete

    /// The selected suggestion after the caret ("#80" + selected "0.com"), while it is on screen.
    private var completion: NSRange?

    /// While a #tag is typed, fills in the rest of the most used matching tag, selected, like Safari's address bar.
    private func suggestTags(_ field: RowTextField) {
        guard !completing else { return }
        completion = nil
        let typing = NSApp.currentEvent.map { $0.type == .keyDown && $0.keyCode != 51 && $0.keyCode != 117 } ?? false
        guard let tv = field.currentEditor() as? NSTextView, typing || Self.assumeTyping, tv.selectedRange().length == 0 else { return }
        let caret = tv.selectedRange().location
        let ns = tv.string as NSString
        // Only at the end of a word: the next character must be a space or the end.
        if caret < ns.length, ns.substring(with: NSRange(location: caret, length: 1)) != " " { return }
        guard let partial = Tags.partial(in: tv.string, caret: caret), !partial.isEmpty else { return }
        let p = partial.lowercased()
        guard let best = model.outline.allTags.first(where: { $0.hasPrefix(p) && $0.count > p.count }) else { return }
        let rest = String(best.dropFirst(p.count))
        completing = true
        tv.insertText(rest, replacementRange: NSRange(location: caret, length: 0))
        completing = false
        let r = NSRange(location: caret, length: (rest as NSString).length)
        tv.setSelectedRange(r)
        completion = r
    }

    /// Tab, Return or → on a shown suggestion keeps it and puts the caret after it.
    private func acceptCompletion(_ tv: NSTextView) -> Bool {
        guard let c = completion, tv.selectedRange() == c else { completion = nil; return false }
        completion = nil
        tv.setSelectedRange(NSRange(location: c.location + c.length, length: 0))
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let cell = control.superview as? RowCellView, let id = cell.itemId else { return false }
        let ghost = id == Self.ghostId
        if (control as? RowTextField)?.role == .note { return noteCommand(id, sel) }
        let tree = !model.isVirtual && model.filter.isEmpty
        if [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveRight(_:))].contains(sel),
           acceptCompletion(textView) {
            return true
        }
        completion = nil
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                if !ghost { focusNote(id) }
                return true
            }
            ghost ? addFromGhost(cell) : splitOrAdd(id)
            return true
        case #selector(NSResponder.insertTab(_:)):
            if !ghost, tree { structural(id) { try self.model.editor.indent(id) } }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if !ghost, tree, let floor = model.floorId { structural(id) { try self.model.editor.outdent(id, floor: floor) } }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if let n = neighbour(of: id, -1) { commitIfNeeded(id); focus(n, caret: textView.selectedRange().location) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if let n = neighbour(of: id, 1) { commitIfNeeded(id); focus(n, caret: textView.selectedRange().location) }
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            if !ghost, textView.string.isEmpty, textView.selectedRange().location == 0 {
                deleteRow(id)
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            commitAll()
            if !model.filter.isEmpty { model.filter = "" } else { onEscape?() }
            return true
        default:
            return false
        }
    }

    /// Keys inside a note: Return or Esc goes back to the title, Option-Return makes a new line.
    private func noteCommand(_ id: String, _ sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
            commitNote(id)
            noteDrafts[id] = nil
            noteEditingId = nil
            focus(id)
            refreshHeights()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return false
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }

    private func commitIfNeeded(_ id: String) { if id != Self.ghostId { commitText(id) } }

    private func structural(_ id: String, _ action: () throws -> Void) {
        let caret = fieldText(id)?.1
        commitText(id)
        try? action()
        pendingFocus = (id, caret)
        scheduleReload()
    }

    /// Return in a row: Workflowy-style. Text after the cursor moves to a new row below.
    private func splitOrAdd(_ id: String) {
        guard let (text, caret) = fieldText(id) else { return }
        let ns = text as NSString
        let head = ns.substring(to: min(caret, ns.length)).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let tail = ns.substring(from: min(caret, ns.length)).replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        textTimers[id]?.invalidate()
        textTimers[id] = nil
        dirty.remove(id)
        if caret == 0 && !text.isEmpty {
            try? model.editor.setText(id, text)
            // At the very start: open a fresh row above and keep the cursor on this one, like Workflowy.
            _ = try? model.editor.newItem(before: id)
            pendingFocus = (id, 0)
        } else {
            setFieldText(id, head)
            try? model.editor.setText(id, head)
            if let new = try? model.editor.newItem(after: id, text: tail) { pendingFocus = (new, 0) }
        }
        scheduleReload()
    }

    /// Replaces what the row's field shows (and its field editor), so ending the edit cannot write stale text back.
    private func setFieldText(_ id: String, _ text: String, caret: Int? = nil) {
        guard let i = index(of: id), let cell = table.view(atColumn: 0, row: i, makeIfNecessary: false) as? RowCellView else { return }
        cell.showText(text)
        if let editor = cell.field.currentEditor() as? NSTextView {
            editor.string = text
            let len = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(caret ?? len, len), length: 0))
        }
    }

    private func addFromGhost(_ cell: RowCellView) {
        if let tv = cell.field.currentEditor() as? NSTextView { dropCompletion(tv) }
        var text = cell.field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        switch model.mode {
        case .list:
            guard let floor = model.floorId else { return }
            _ = try? model.editor.newItem(in: floor, text: text)
        case .today:
            guard let inbox = model.inbox else { return }
            _ = try? model.editor.newItem(in: inbox.id, text: text, when: model.today)
        case let .tag(t):
            guard let inbox = model.inbox else { return }
            if !Tags.in(text).contains(t) { text += " #" + t }
            _ = try? model.editor.newItem(in: inbox.id, text: text)
        }
        ghostDraft = ""
        if let editor = cell.field.currentEditor() as? NSTextView { editor.string = "" }
        cell.showText("")
        pendingFocus = (Self.ghostId, nil)
        scheduleReload()
    }

    private func deleteRow(_ id: String) {
        let prev = neighbour(of: id, -1)
        textTimers[id]?.invalidate()
        textTimers[id] = nil
        dirty.remove(id)
        try? model.editor.delete(id)
        pendingFocus = prev.map { ($0, nil) } ?? (Self.ghostId, nil)
        scheduleReload()
    }

    private func tick(_ id: String) {
        commitText(id)
        model.tick(id)
    }

    // MARK: Commands (from the panel's key handling and menus)

    var focusedId: String? { editingId.flatMap { $0 == Self.ghostId ? nil : $0 } }

    func command(_ c: Command) {
        if case .undo = c { commitAll(); try? model.editor.undo(); keepFocus(); return }
        if case .redo = c { commitAll(); try? model.editor.redo(); keepFocus(); return }
        let tree = !model.isVirtual && model.filter.isEmpty
        guard let id = focusedId else {
            if case .newAtTop = c, tree, let floor = model.floorId, let new = try? model.editor.newItem(atTopOf: floor) { pendingFocus = (new, 0); scheduleReload() }
            return
        }
        commitAll()
        switch c {
        case .today:
            model.toggleToday(id)
            pendingFocus = (id, nil)
            scheduleReload()
            return
        case .when: onPickDate?(id, .when); return
        case .deadline: onPickDate?(id, .deadline); return
        case .note: focusNote(id); return
        case .zoomIn where model.isVirtual:
            if let f = model.reveal(id) { pendingFocus = (f, nil) }
            scheduleReload()
            return
        case .moveUp, .moveDown, .indent, .outdent, .newAtTop:
            if !tree { pendingFocus = (id, nil); scheduleReload(); return }
        default: break
        }
        switch c {
        case .tick: tick(id); if let n = neighbour(of: id, 1), !model.showCompleted { pendingFocus = (n, nil) } else { pendingFocus = (id, nil) }
        case .collapse: try? model.editor.setCollapsed(id, true); pendingFocus = (id, nil)
        case .expand: try? model.editor.setCollapsed(id, false); pendingFocus = (id, nil)
        case .zoomIn: model.zoom(into: id); pendingFocus = (Self.ghostId, nil)
        case .moveUp: try? model.editor.moveUp(id); pendingFocus = (id, nil)
        case .moveDown: try? model.editor.moveDown(id); pendingFocus = (id, nil)
        case .delete: deleteRow(id); return
        case .newAtTop: if let floor = model.floorId, let new = try? model.editor.newItem(atTopOf: floor) { pendingFocus = (new, 0) }
        case .indent: structural(id) { try self.model.editor.indent(id) }; return
        case .outdent: if let f = model.floorId { structural(id) { try self.model.editor.outdent(id, floor: f) } }; return
        case let .moveTo(list): try? model.editor.move(id, to: list); pendingFocus = nil
        case .undo, .redo, .today, .when, .deadline, .note: break
        }
        scheduleReload()
    }

    private func keepFocus() {
        if let e = editingId { pendingFocus = (e, nil) }
        scheduleReload()
    }

    private func contextMenu(for id: String) -> NSMenu {
        let m = NSMenu()
        func add(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command, _ c: Command) {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            item.representedObject = CommandBox(c, id)
            m.addItem(item)
        }
        let it = model.outline.item(id)
        add(it?.isCompleted == true ? "Mark Not Done" : "Complete", "k", .command, .tick)
        let starred = it?.whenDate.map { $0 <= model.today } ?? false
        add(starred ? "Remove from Today" : "Today", "t", .command, .today)
        add("When…", "s", .command, .when)
        add("Deadline…", "d", [.command, .shift], .deadline)
        add((it?.note ?? "").isEmpty ? "Add Note" : "Edit Note", "\r", .shift, .note)
        m.addItem(.separator())
        add("Indent", "\t", [], .indent)
        add("Outdent", "\t", .shift, .outdent)
        add("Zoom In", ".", .command, .zoomIn)
        let move = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for l in model.outline.lists where l.id != model.outline.rootList(of: id)?.id {
            let li = NSMenuItem(title: l.text, action: #selector(menuCommand(_:)), keyEquivalent: "")
            li.target = self
            li.representedObject = CommandBox(.moveTo(l.id), id)
            sub.addItem(li)
        }
        move.submenu = sub
        move.isEnabled = !sub.items.isEmpty
        m.addItem(move)
        m.addItem(.separator())
        add("Delete", "\u{8}", .command, .delete)
        return m
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        focus(box.id)
        command(box.command)
    }
}

enum Command {
    case tick, collapse, expand, zoomIn, moveUp, moveDown, delete, undo, redo, newAtTop, indent, outdent
    case today, when, deadline, note
    case moveTo(String)
}

enum DateKind { case when, deadline }

final class CommandBox: NSObject {
    let command: Command
    let id: String
    init(_ c: Command, _ id: String) {
        command = c
        self.id = id
    }
}
