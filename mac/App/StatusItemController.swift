import AppKit
import ServiceManagement

/// The menu bar icon: left click toggles the panel, right click shows a small menu. A dot marks unseen agent items.
@MainActor
final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onToggle: (() -> Void)?
    var onNewItem: (() -> Void)?
    var onConnection: (() -> Void)?
    var agentName = "Agent"

    override init() {
        super.init()
        guard let b = item.button else { return }
        b.target = self
        b.action = #selector(clicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.setAccessibilityLabel("Laser Focus")
        b.imagePosition = .imageLeading
        setUnseenDot(false)
    }

    /// The count next to the icon (Settings > Menu bar count). Zero shows just the icon.
    func setCount(_ n: Int) {
        guard let b = item.button else { return }
        b.title = n > 0 ? "\(n)" : ""
        b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        b.imageHugsTitle = true
    }

    var buttonFrame: NSRect? {
        guard let b = item.button, let w = b.window else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    func setUnseenDot(_ on: Bool) {
        item.button?.image = Self.icon(dot: on)
        item.button?.toolTip = on ? "Laser Focus: new to-dos from \(agentName)" : "Laser Focus"
    }

    /// A template image so macOS tints it like every other menu bar icon; the dot is cut into the same template.
    static func icon(dot: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            if let s = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let r = NSRect(x: (rect.width - s.size.width) / 2 - (dot ? 1 : 0), y: (rect.height - s.size.height) / 2, width: s.size.width, height: s.size.height)
                s.draw(in: r)
            }
            if dot {
                let d = NSRect(x: rect.width - 6.5, y: rect.height - 6.5, width: 6, height: 6)
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: d.insetBy(dx: -1.2, dy: -1.2)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: d).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc private func clicked() {
        guard let e = NSApp.currentEvent else { return }
        if e.type == .rightMouseUp || e.modifierFlags.contains(.control) { showMenu() } else { onToggle?() }
    }

    private func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "New Item", action: #selector(newItem), keyEquivalent: "").target = self
        m.addItem(withTitle: "Open", action: #selector(open), keyEquivalent: "").target = self
        m.addItem(.separator())
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Laser Focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func newItem() { onNewItem?() }
    @objc private func open() { onToggle?() }
    @objc private func connection() { onConnection?() }
    @objc private func settings() { SettingsWindowController.shared.open() }

    @objc private func toggleLogin() {
        do {
            let on = SMAppService.mainApp.status != .enabled
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            UserDefaults.standard.set(!on, forKey: "loginItemOptOut")
        } catch {
            NSLog("Launch at login: \(error)")
        }
    }
}
