import AppKit
import TodoCore

/// Text field that reports focus, and clicks on a #tag while it is not being edited.
final class RowTextField: NSTextField {
    enum Role { case title, note }
    var role: Role = .title
    var onFocus: (() -> Void)?
    var onTagClick: ((String) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        if currentEditor() == nil, let tag = tag(at: convert(event.locationInWindow, from: nil)), let onTagClick {
            onTagClick(tag)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard currentEditor() == nil, onTagClick != nil else { return }
        for r in tagRects() { addCursorRect(r, cursor: .pointingHand) }
    }

    private func layout() -> (NSLayoutManager, NSTextContainer, NSTextStorage) {
        let storage = NSTextStorage(attributedString: attributedStringValue)
        let lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: max(1, bounds.width - 4), height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        storage.addLayoutManager(lm)
        return (lm, tc, storage)
    }

    /// The tag under a point in the field (title rows are one line, so only x matters).
    /// The tag under a point: only a click on the tag's own text counts (a click after the text edits the row).
    func tag(at p: NSPoint) -> String? {
        let ns = stringValue as NSString
        for (r, rect) in zip(Tags.ranges(in: stringValue), tagRects()) where p.x >= rect.minX && p.x <= rect.maxX {
            return ns.substring(with: NSRange(location: r.location + 1, length: r.length - 1)).lowercased()
        }
        return nil
    }

    func tagRects() -> [NSRect] {
        // The layout manager holds its text storage weakly: keep it alive while measuring.
        let (lm, tc, storage) = layout()
        return withExtendedLifetime(storage) {
            lm.ensureLayout(for: tc)
            // Single-line title: stop at what is actually visible.
            return Tags.ranges(in: stringValue).map { r in
                let g = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                return lm.boundingRect(forGlyphRange: g, in: tc).offsetBy(dx: 2, dy: 0).insetBy(dx: 0, dy: -4)
            }.filter { $0.minX < bounds.width }
        }
    }
}

/// What a row shows next to its text.
struct RowContext {
    var agentName: String
    var today: String
    /// Show the star on items starred for today (not in the Today view itself).
    var showStar: Bool
    /// Show the list name (rows of Today and tag views come from many lists).
    var listName: String?
    var noteEditing: Bool
}

/// One outline row: disclosure chevron, checkbox, title, a grey note under it, date chips and the agent tag.
final class RowCellView: NSTableCellView {
    let chevron = NSButton()
    let checkbox = CheckboxView()
    let field = RowTextField()
    let noteField = RowTextField()
    let agentTag = TagView()
    let chips = NSStackView()
    private let star = NSImageView()
    /// The list's icon on a Today section heading.
    private let sectionIcon = NSImageView()
    private let whenChip = ChipView()
    private let deadlineChip = ChipView()
    private let listChip = ChipView()
    private var leading: NSLayoutConstraint!
    private var lineCenter: NSLayoutConstraint!
    private var checkboxW: NSLayoutConstraint!
    private var checkboxH: NSLayoutConstraint!
    private(set) var itemId: String?
    private(set) var isSection = false
    var onToggleCollapse: (() -> Void)?
    var onTick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.target = self
        chevron.action = #selector(chevronClicked)
        chevron.setAccessibilityLabel("Expand or collapse")
        checkbox.onToggle = { [weak self] in self?.onTick?() }

        for f in [field, noteField] {
            f.isBordered = false
            f.drawsBackground = false
            f.focusRingType = .none
            f.isEditable = true
            f.placeholderString = ""
        }
        field.lineBreakMode = .byTruncatingTail
        // Lets the editor show #tags in color while typing; pasted styles are dropped (see importsGraphics/paste below).
        field.allowsEditingTextAttributes = true
        field.importsGraphics = false
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        textField = field

        noteField.role = .note
        noteField.cell?.wraps = true
        noteField.cell?.isScrollable = false
        noteField.cell?.truncatesLastVisibleLine = true
        noteField.usesSingleLineMode = false
        noteField.lineBreakMode = .byWordWrapping
        noteField.setAccessibilityLabel("Notes")
        noteField.setContentHuggingPriority(.defaultLow, for: .vertical)
        noteField.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        star.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Today")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        star.contentTintColor = Theme.star
        star.setContentHuggingPriority(.required, for: .horizontal)
        chips.orientation = .horizontal
        chips.spacing = 5
        chips.alignment = .centerY
        for v in [listChip, whenChip, deadlineChip, star, agentTag] as [NSView] { chips.addArrangedSubview(v) }
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)
        chips.setContentHuggingPriority(.required, for: .horizontal)

        for v in [chevron, checkbox, sectionIcon, field, noteField, chips] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        leading = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        lineCenter = chevron.centerYAnchor.constraint(equalTo: topAnchor, constant: Theme.rowHeight / 2)
        checkboxW = checkbox.widthAnchor.constraint(equalToConstant: Theme.checkboxSize)
        checkboxH = checkbox.heightAnchor.constraint(equalToConstant: Theme.checkboxSize)
        NSLayoutConstraint.activate([
            leading, lineCenter, checkboxW, checkboxH,
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 14),
            checkbox.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            checkbox.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            sectionIcon.centerXAnchor.constraint(equalTo: checkbox.centerXAnchor),
            sectionIcon.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            noteField.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            noteField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.sidePadding),
            noteField.topAnchor.constraint(equalTo: field.bottomAnchor, constant: -1),
            {
                // The table sizes the row for the note (up to 2 lines, more while editing); the note fills it.
                let c = noteField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
                c.priority = .init(999)
                return c
            }(),
            chips.leadingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 8),
            chips.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.sidePadding),
            chips.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
        ])
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.sidePadding)
        trailing.priority = .defaultLow
        trailing.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func chevronClicked() { onToggleCollapse?() }

    /// Left edge of the title text for a row at `depth` (used to measure note height).
    static func textLeading(depth: Int) -> CGFloat {
        Theme.sidePadding - 4 + CGFloat(depth) * Theme.indent + 14 + 4 + Theme.checkboxSize + 10
    }

    func configure(_ row: Outline.Row, context ctx: RowContext, updateText: Bool) {
        itemId = row.item.id
        isSection = row.isSection
        let it = row.item
        leading.constant = Theme.sidePadding - 4 + CGFloat(row.depth) * Theme.indent
        lineCenter.constant = Theme.rowHeight / 2 + (row.isSection ? 4 : 0)
        checkboxW.constant = Theme.checkboxSize
        checkboxH.constant = Theme.checkboxSize
        chevron.isHidden = !row.hasChildren || row.isSection
        if row.hasChildren {
            let name = it.collapsed ? "chevron.right" : "chevron.down"
            chevron.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        }
        sectionIcon.isHidden = !row.isSection
        if row.isSection {
            let look = ListLook.of(it)
            sectionIcon.image = NSImage(systemSymbolName: look.icon, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Theme.sectionFont.pointSize + 1, weight: .semibold))
            sectionIcon.contentTintColor = Theme.color(look.color)
            checkbox.isHidden = true
            chips.isHidden = true
            noteField.isHidden = true
            field.isEditable = false
            field.isSelectable = false
            field.onTagClick = nil
            field.attributedStringValue = NSAttributedString(string: it.text.uppercased(), attributes: [
                .font: Theme.sectionFont, .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6,
            ])
            alphaValue = 1
            setAccessibilityLabel(it.text)
            return
        }
        checkbox.isHidden = false
        chips.isHidden = false
        field.isEditable = true
        field.isSelectable = true
        checkbox.isChecked = it.isCompleted
        if updateText { setText(it.text, completed: it.isCompleted) }
        let note = (it.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        noteField.isHidden = note.isEmpty && !ctx.noteEditing
        noteField.font = Theme.noteFont
        noteField.textColor = .secondaryLabelColor
        noteField.maximumNumberOfLines = ctx.noteEditing ? 0 : 2
        if noteField.currentEditor() == nil { noteField.stringValue = it.note ?? "" }
        noteField.placeholderAttributedString = NSAttributedString(string: "Notes", attributes: [
            .font: Theme.noteFont, .foregroundColor: NSColor.placeholderTextColor,
        ])
        alphaValue = it.isCompleted ? Theme.fadedAlpha : 1

        // Chips: list name, When, Deadline, Today star, agent tag.
        listChip.isHidden = ctx.listName == nil
        listChip.set(symbol: nil, text: ctx.listName ?? "", color: .tertiaryLabelColor)
        let starred = it.whenDate.map { $0 <= ctx.today } ?? false
        star.isHidden = !(starred && ctx.showStar)
        if let w = it.whenDate, w > ctx.today {
            whenChip.isHidden = false
            whenChip.set(symbol: "calendar", text: DayLabel.short(w, today: ctx.today), color: .secondaryLabelColor)
        } else {
            whenChip.isHidden = true
        }
        if let d = it.deadline, let left = DayLabel.daysLeft(d, today: ctx.today) {
            deadlineChip.isHidden = false
            let text = left < 0 ? "\(-left)d overdue" : left == 0 ? "Due today" : left <= 7 ? "\(left)d left" : DayLabel.short(d, today: ctx.today)
            deadlineChip.set(symbol: "flag.fill", text: text, color: left <= 0 && !it.isCompleted ? Theme.overdue : .secondaryLabelColor)
        } else {
            deadlineChip.isHidden = true
        }
        agentTag.isHidden = !it.isUnseenAgentItem
        agentTag.label.stringValue = ctx.agentName
        setAccessibilityLabel(it.text)
    }

    private var lastText = ""
    private var lastCompleted = false

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !isSection else { return }
        for f in [field, noteField] {
            if let editor = f.currentEditor() as? NSTextView {
                editor.textColor = f === noteField ? .secondaryLabelColor : .labelColor
                editor.insertionPointColor = .controlAccentColor
            }
        }
        if field.currentEditor() == nil { setText(lastText, completed: lastCompleted) }
    }

    /// Replaces the shown text and remembers it, so an appearance refresh redraws this text and not an older one.
    func showText(_ text: String) { setText(text, completed: lastCompleted) }

    func setText(_ text: String, completed: Bool) {
        lastText = text
        lastCompleted = completed
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: Theme.itemFont,
            .foregroundColor: completed ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ])
        if completed { s.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: s.length)) }
        for r in Tags.ranges(in: text) {
            s.addAttribute(.foregroundColor, value: Theme.accent, range: r)
        }
        field.attributedStringValue = s
        field.font = Theme.itemFont
        window?.invalidateCursorRects(for: field)
    }
}

/// Small grey (or red) label with an SF Symbol: "📅 Fri", "⚑ 2d left", list names.
final class ChipView: NSStackView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        spacing = 3
        alignment = .centerY
        addArrangedSubview(icon)
        addArrangedSubview(label)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(symbol: String?, text: String, color: NSColor) {
        label.font = Theme.chipFont
        label.stringValue = text
        label.textColor = color
        icon.isHidden = symbol == nil
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: Theme.chipFont.pointSize - 1, weight: .semibold))
            icon.contentTintColor = color
        }
    }
}

/// The small accent capsule that marks an agent item until I look at it.
final class TagView: NSView {
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = Theme.tagFont
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accent.withAlphaComponent(0.14).cgColor
        label.textColor = Theme.accent
    }

    override var wantsUpdateLayer: Bool { true }
}

/// Row background: none. Editing is Workflowy-style: click and type, only the caret shows where you are.
final class OutlineRowView: NSTableRowView {
    var isFocusedRow = false

    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {}
}
