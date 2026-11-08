import AppKit
import Combine
import KeyboardShortcuts
import ServiceManagement
import TodoCore

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", default: .init(.space, modifiers: [.option]))
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.shared
    let status = StatusItemController()
    let notifier = AgentNotifier()
    var panel: PanelController!
    var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        status.agentName = model.agentName
        panel = PanelController(model: model, anchor: { [weak self] in self?.status.buttonFrame })
        status.onToggle = { [weak self] in self?.panel.toggle() }
        status.onNewItem = { [weak self] in
            self?.panel.show()
            self?.panel.outline.focusForOpen()
        }
        status.onConnection = { [weak self] in self?.askDisconnect() }
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in self?.panel.toggle() }

        model.$agentName.sink { [weak self] n in self?.status.agentName = n }.store(in: &cancellables)
        model.$hasUnseenDot.removeDuplicates().sink { [weak self] on in self?.status.setUnseenDot(on) }.store(in: &cancellables)
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { if let self { self.status.setCount(self.model.menuBarCount) } }
        }.store(in: &cancellables)

        notifier.setUp()
        notifier.onDone = { [weak self] id in self?.model.tick(id) }
        notifier.onOpen = { [weak self] id in
            guard let self, let focus = self.model.reveal(id) else { return }
            self.panel.show(focusing: focus)
        }
        model.agentItemsArrived.sink { [weak self] items, outline in
            guard let self else { return }
            let visibleList = self.panel.isVisible ? self.model.currentListId : nil
            let toAnnounce = AgentAnnouncer.itemsToAnnounce(items, panelVisibleOnList: visibleList, outline: outline)
            self.notifier.announce(toAnnounce, outline: outline, agentName: self.model.agentName)
            if self.panel.isVisible { self.model.hasUnseenDot = false }
        }.store(in: &cancellables)

        #if DEBUG
        DebugHooks.install(model: model, panel: panel)
        #else
        registerLoginItemOnce()
        #endif
        #if !DEBUG
        if model.connection == nil { panel.show() }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Quit must not lose the last moment of typing.
        panel.outline.commitAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return false
    }

    /// Launch at login is on unless I turned it off myself. Re-registers after a reinstall (replacing the
    /// app bundle drops the system's login item record).
    private func registerLoginItemOnce() {
        guard !UserDefaults.standard.bool(forKey: "loginItemOptOut"), SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Launch at login registration failed: \(error)")
        }
    }

    private func askDisconnect() {
        let a = NSAlert()
        a.messageText = "Connection"
        a.informativeText = model.connection.map { "Connected to \($0.baseURL.host() ?? $0.baseURL.absoluteString)." } ?? "Not connected."
        a.addButton(withTitle: "Done")
        if model.connection != nil { a.addButton(withTitle: "Disconnect") }
        NSApp.activate()
        if a.runModal() == .alertSecondButtonReturn {
            model.disconnect()
            panel.show()
        }
    }

    /// A menu bar app has no visible menus, but text fields only get Cut/Copy/Paste/Select All/Undo
    /// through Edit menu key equivalents. A hidden main menu provides them.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }
}
