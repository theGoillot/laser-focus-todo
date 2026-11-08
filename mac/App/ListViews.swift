import SwiftUI
import TodoCore

extension Theme {
    /// Palette names (shared with the backend) to system colors, so they follow light and dark mode.
    static func color(_ name: String) -> NSColor {
        switch name {
        case "blue": .systemBlue
        case "indigo": .systemIndigo
        case "purple": .systemPurple
        case "pink": .systemPink
        case "red": .systemRed
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "green": .systemGreen
        case "mint": .systemMint
        case "teal": .systemTeal
        case "brown": .systemBrown
        default: .systemGray
        }
    }
}

/// A list's filled glyph in its color.
struct ListGlyph: View {
    let style: ListLook
    var size: CGFloat = 14
    var body: some View {
        Image(systemName: style.icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(nsColor: Theme.color(style.color)))
            .frame(width: size + 6)
    }
}

/// The list switcher: Inbox and Today on top, then the lists with their icons, then tags, like Things' sidebar.
struct ListSwitcher: View {
    enum Action { case none, opened, newList, edit(String) }
    @ObservedObject var model: AppModel
    var close: (Action) -> Void

    enum Entry: Hashable {
        case today, list(String), tag(String), newList, edit(String)
    }

    @State private var selection = 0
    @FocusState private var focused: Bool

    private var inbox: Item? { model.inbox }
    private var others: [Item] { model.outline.lists.filter { $0.id != inbox?.id } }
    private var tags: [String] { Array(model.outline.allTags.prefix(8)) }

    private var entries: [Entry] {
        var e: [Entry] = []
        if let inbox { e.append(.list(inbox.id)) }
        e.append(.today)
        e += others.map { .list($0.id) }
        e += tags.map { .tag($0) }
        e.append(.newList)
        if model.mode == .list, let cur = model.currentListId { e.append(.edit(cur)) }
        return e
    }

    private var current: Entry? {
        switch model.mode {
        case .today: .today
        case let .tag(t): .tag(t)
        case .list: model.currentListId.map { .list($0) }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.12).contentShape(Rectangle()).onTapGesture { close(.none) }
            card.padding(.top, 58).padding(.leading, 14)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(entries.enumerated()), id: \.element) { i, entry in
                if needsGap(before: i) { Divider().padding(.vertical, 5).padding(.horizontal, 6) }
                row(entry, index: i)
            }
        }
        .padding(6)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            selection = entries.firstIndex(where: { $0 == current }) ?? 0
        }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.downArrow) { selection = min(entries.count - 1, selection + 1); return .handled }
        .onKeyPress(.return) { activate(entries[selection]); return .handled }
        .onExitCommand { close(.none) }
    }

    /// Gaps like Things: after Today, before tags, before the actions.
    private func needsGap(before i: Int) -> Bool {
        guard i > 0 else { return false }
        let prev = entries[i - 1], cur = entries[i]
        switch (prev, cur) {
        case (.today, _): return true
        case (.list, .tag), (.list, .newList), (.tag, .newList): return true
        default: return false
        }
    }

    @ViewBuilder private func row(_ entry: Entry, index: Int) -> some View {
        let on = entry == current
        Button { activate(entry) } label: {
            HStack(spacing: 9) {
                label(entry)
                Spacer(minLength: 8)
                if let n = count(entry), n > 0 {
                    Text("\(n)").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(index == selection ? Color.primary.opacity(0.10) : on ? Color.primary.opacity(0.05) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection = index } }
    }

    @ViewBuilder private func label(_ entry: Entry) -> some View {
        switch entry {
        case .today:
            Image(systemName: "star.fill").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(nsColor: Theme.star)).frame(width: 20)
            Text("Today").font(.system(size: 14, weight: .semibold))
        case let .list(id):
            if let l = model.outline.item(id) {
                ListGlyph(style: ListLook.of(l))
                Text(l.text.isEmpty ? "Untitled" : l.text).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
        case let .tag(t):
            Image(systemName: "number").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20)
            Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        case .newList:
            Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20)
            Text("New List").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        case .edit:
            Image(systemName: "paintpalette").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).frame(width: 20)
            Text("Icon, Colour & Name…").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private func count(_ entry: Entry) -> Int? {
        switch entry {
        case .today: model.todayCount
        case let .list(id): model.outline.openCount(under: id)
        case let .tag(t): model.outline.tagged(t).filter { !$0.isCompleted }.count
        default: nil
        }
    }

    private func activate(_ entry: Entry) {
        switch entry {
        case .today: model.showToday(); close(.opened)
        case let .list(id): model.selectList(id); close(.opened)
        case let .tag(t): model.showTag(t); close(.opened)
        case .newList: close(.newList)
        case let .edit(id): close(.edit(id))
        }
    }
}

/// Name, color and icon of a list, North-style: a color row and a grid of filled glyphs.
struct ListStyleEditor: View {
    @State var name: String
    @State var style: ListLook
    let isNew: Bool
    var onSave: (String, ListLook) -> Void
    var onCancel: () -> Void
    @FocusState private var nameFocused: Bool

    private let grid = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 7)

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16).contentShape(Rectangle()).onTapGesture(perform: onCancel)
            card.padding(.top, 50)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ListGlyph(style: style, size: 20)
                TextField(isNew ? "New list" : "Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .bold))
                    .focused($nameFocused)
                    .onSubmit(save)
                    .onExitCommand(perform: onCancel)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 7) {
                ForEach(ListLook.colors, id: \.self) { c in
                    Button { style.color = c } label: {
                        Circle().fill(Color(nsColor: Theme.color(c))).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(style.color == c ? 0.9 : 0), lineWidth: 2).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .help(c.capitalized)
                }
            }
            .padding(.horizontal, 4)

            LazyVGrid(columns: grid, spacing: 6) {
                ForEach(ListLook.icons, id: \.self) { icon in
                    Button { style.icon = icon } label: {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(style.icon == icon ? Color.white : Color(nsColor: Theme.color(style.color)))
                            .frame(width: 38, height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(style.icon == icon ? Color(nsColor: Theme.color(style.color)) : Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.plain).foregroundStyle(.secondary)
                Button(isNew ? "Create List" : "Save", action: save)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                    .disabled(trimmed.isEmpty)
                    .opacity(trimmed.isEmpty ? 0.5 : 1)
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .padding(16)
        .frame(width: 336)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .onAppear { nameFocused = true }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, style)
    }
}
