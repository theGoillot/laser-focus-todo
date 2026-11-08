import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

/// Settings, laid out like Things: a toolbar of tabs over a short form.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab(_ title: String, _ symbol: String, _ view: some View) {
            let host = NSHostingController(rootView: view.frame(width: 520).fixedSize())
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let model = AppModel.shared
        tab("General", "slider.horizontal.3", GeneralPane(prefs: .shared))
        tab("Shortcuts", "command", ShortcutsPane())
        tab(model.agentName, "sparkles", AgentPane(prefs: .shared, model: model))
        tab("Connection", "icloud", ConnectionPane(model: model))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "General"
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func open() {
        window?.appearance = Prefs.shared.appearance.nsAppearance
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct Row<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label + ":").frame(width: 200, alignment: .trailing)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct GeneralPane: View {
    @ObservedObject var prefs: Prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AboutHeader()
            Divider().padding(.bottom, 2)
            Row(label: "Hide completed items") {
                Picker("", selection: $prefs.hideCompleted) {
                    ForEach(Prefs.HideCompleted.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 220)
            }
            Row(label: "Menu bar count") {
                Picker("", selection: $prefs.menuBarCount) {
                    ForEach(Prefs.MenuBarCount.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 220)
            }
            Row(label: "Appearance") {
                Picker("", selection: $prefs.appearance) {
                    ForEach(Prefs.Appearance.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 220)
            }
            Row(label: "Text size") {
                VStack(spacing: 2) {
                    HStack(spacing: 8) {
                        Text("A").font(.system(size: 11))
                        Slider(value: $prefs.textSize, in: Prefs.textSizes, step: 1).frame(width: 170)
                        Text("A").font(.system(size: 17))
                    }
                    Text(prefs.textSize == 13 ? "Default" : "\(Int(prefs.textSize)) pt").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(width: 220)
            }
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Group to-dos in the Today list by list", isOn: $prefs.groupToday)
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch { NSLog("Launch at login: \(error)") }
                    UserDefaults.standard.set(!on, forKey: "loginItemOptOut")
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }))
            }
            .padding(.leading, 40)
        }
        .padding(28)
    }
}

/// Icon, name and the idea behind it, at the top of Settings.
struct AboutHeader: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var body: some View {
        HStack(spacing: 16) {
            Image("LaserFocusIcon").resizable().frame(width: 72, height: 72)
                .shadow(color: .red.opacity(0.35), radius: 12, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Laser Focus").font(.system(size: 22, weight: .bold))
                Text("One beam, one list. The flow you enter when you work your to-dos.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Version \(version)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShortcutsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Row(label: "Open the list from anywhere") {
                KeyboardShortcuts.Recorder(for: .togglePanel)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("In the list").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                    keys("⌘K", "Complete", "⌘T", "Today ⭐")
                    keys("⌘S", "When…", "⇧⌘D", "Deadline…")
                    keys("⇧↩", "Note", "⌘Z / ⇧⌘Z", "Undo / Redo")
                    keys("⇥ / ⇧⇥", "Indent / Outdent", "⌘.", "Zoom in")
                    keys("⌘[ / ⌘]", "Previous / next list", "⌘0", "Today")
                    keys("⌘F", "Filter (type #tag for tags)", "⌘,", "Settings")
                }
                .font(.system(size: 12))
            }
        }
        .padding(28)
    }

    @ViewBuilder private func keys(_ k1: String, _ d1: String, _ k2: String, _ d2: String) -> some View {
        GridRow {
            Text(k1).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text(d1)
            Text(k2).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text(d2)
        }
    }
}

struct AgentPane: View {
    @ObservedObject var prefs: Prefs
    let model: AppModel
    @State private var status: (ok: Bool, message: String)?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(model.agentName)").font(.headline)
            Text("Saves \(model.agentName)'s key to ~/.config/laser-focus/agent.env and copies the instructions to paste into \(model.agentName).")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Set Up \(model.agentName)") { run { await model.setUpAgent() } }
                    .keyboardShortcut(.defaultAction)
                Button("Copy MCP Config (JSON)") { run { await model.copyAgentConfig() } }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy || model.connection == nil)
            if let status {
                Label(status.message, systemImage: status.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(status.ok ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle("Show a banner when \(model.agentName) adds a to-do", isOn: $prefs.showBanners)
            Text("New items from \(model.agentName) always get a small tag and a dot on the menu bar icon until you look at them.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("MCP address").font(.subheadline.weight(.semibold))
            HStack {
                Text(mcpURL).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mcpURL, forType: .string)
                }
            }
            Text("\(model.agentName) uses its own key (LASER_FOCUS_API_KEY), never this Mac's. It can add, edit, tick, move and date to-dos, but not delete them or touch your lists.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
    }

    private func run(_ work: @escaping @MainActor () async -> (ok: Bool, message: String)) {
        busy = true
        Task { @MainActor in
            status = await work()
            busy = false
        }
    }

    private var mcpURL: String { model.connection.map { $0.baseURL.appending(path: "mcp").absoluteString } ?? "Not connected" }
}

struct ConnectionPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Row(label: "Backend") {
                Text(model.connection?.baseURL.host() ?? "Not connected").textSelection(.enabled)
            }
            Row(label: "Status") {
                Text(statusText).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if model.connection != nil {
                    Button("Disconnect…") { confirm() }
                }
            }
        }
        .padding(28)
    }

    private var statusText: String {
        switch model.status {
        case .offline: "Offline, changes saved on this Mac"
        case .unauthorized: "The backend refused the token"
        case .syncing: "Syncing"
        case .synced, .idle: model.connection == nil ? "Not connected" : "Up to date"
        }
    }

    private func confirm() {
        let a = NSAlert()
        a.messageText = "Disconnect this Mac?"
        a.informativeText = "Your to-dos stay on the backend. You'll need the Mac token to connect again."
        a.addButton(withTitle: "Disconnect")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            model.disconnect()
            PanelController.shared?.show()
        }
    }
}
