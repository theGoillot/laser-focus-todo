import SwiftUI
import TodoCore

/// Top of the panel: large bold list title (a list switcher), breadcrumb when zoomed, and quiet controls.
struct HeaderView: View {
    @ObservedObject var model: AppModel
    var onFilterSubmit: () -> Void
    @FocusState private var filterFocused: Bool
    @Binding var filterVisible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !crumbs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(crumbs) { c in
                        Button(c.text.isEmpty ? "Untitled" : c.text) { model.zoom(into: c.id) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.compact.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .transition(.opacity)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleView
                Spacer(minLength: 8)
                controls
            }
            if filterVisible {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.system(size: 11))
                    TextField(model.mode == .list ? "Filter this list, or #tag" : "Filter, or #tag", text: $model.filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($filterFocused)
                        .onSubmit(onFilterSubmit)
                        .onExitCommand { close() }
                    if !model.filter.isEmpty {
                        Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                .onAppear { filterFocused = true }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .animation(.easeOut(duration: 0.15), value: crumbs.map(\.id))
    }

    private func close() {
        model.filter = ""
        filterVisible = false
    }

    private var crumbs: [Item] {
        guard model.mode == .list, let z = model.zoomId else { return [] }
        return model.outline.path(to: z)
    }

    private var title: String {
        switch model.mode {
        case .today: return "Today"
        case let .tag(t): return "#" + t
        case .list: break
        }
        if let z = model.zoomId, let it = model.outline.item(z) { return it.text.isEmpty ? "Untitled" : it.text }
        return model.currentList?.text ?? "To-do"
    }

    private var titleView: some View {
        Button { PanelController.shared?.showListSwitcher() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.mode == .today {
                    Image(systemName: "star.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Theme.star))
                } else if model.mode == .list, model.zoomId == nil, let l = model.currentList {
                    ListGlyph(style: ListLook.of(l), size: 18)
                }
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(isTag ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .offset(y: -3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch list (⌘[ and ⌘])")
        .accessibilityLabel("List: \(title). Switch list")
    }

    private var isTag: Bool { if case .tag = model.mode { return true } else { return false } }

    private var controls: some View {
        HStack(spacing: 12) {
            if model.status == .offline || model.status == .unauthorized {
                Image(systemName: model.status == .offline ? "icloud.slash" : "key.slash")
                    .foregroundStyle(.secondary)
                    .help(model.status == .offline ? "Offline. Changes are saved and will sync." : "The backend refused the token.")
            }
            Button { model.showCompleted.toggle() } label: {
                Image(systemName: model.showCompleted ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .help(model.showCompleted ? "Hide completed (⇧⌘H)" : "Show completed (⇧⌘H)")
            .accessibilityLabel(model.showCompleted ? "Hide completed" : "Show completed")
            Button {
                PanelController.shared?.hide()
                SettingsWindowController.shared.open()
            } label: { Image(systemName: "gearshape") }
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
}

/// Bottom line: how many are open, what the agent left, and sync state in words.
struct FooterView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Text(openText)
            if model.unseenCount > 0 {
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                    Text("\(model.unseenCount) new from \(model.agentName)")
                }
            }
            Spacer()
            Text(statusText)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 20)
        .frame(height: 30)
    }

    private var openText: String {
        let n: Int
        switch model.mode {
        case .today: n = model.todayCount
        case let .tag(t): n = model.outline.tagged(t).filter { !$0.isCompleted }.count
        case .list:
            guard let f = model.floorId else { return "" }
            n = model.outline.openCount(under: f)
        }
        return n == 1 ? "1 open" : "\(n) open"
    }

    private var statusText: String {
        switch model.status {
        case .offline: "Offline, saved locally"
        case .unauthorized: "Token rejected"
        case .syncing, .synced, .idle: model.connection == nil ? "Not connected" : ""
        }
    }
}
