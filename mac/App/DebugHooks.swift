#if DEBUG
import AppKit
import ServiceManagement
import SwiftUI
import TodoCore

/// Debug builds only. A QA channel that never takes over the screen:
/// post distributed notification `laser-focus.debug` with a command string as the object.
///   snapshot <path.png> [dark|light]   render the panel off-screen
///   dump <path.json>                   rows, focus and status as JSON
///   focus <row text> | focusghost      put the cursor in a row (window stays off-screen)
///   key return|tab|backtab|up|down|backspace|esc|cmd-k|cmd-z|cmd-shift-z|cmd-up|cmd-down|cmd-.|cmd-shift-.|cmd-shift-up|cmd-shift-down|cmd-backspace|cmd-shift-h|cmd-f|cmd-]|cmd-[
///   type <text>                        insert text at the cursor
///   caret <n>                          move the cursor in the focused row
///   list <name>                        switch list
///   loginoff                           unregister the login item
///   show | hide                        real panel (only when asked)
@MainActor
enum DebugHooks {
    static func install(model: AppModel, panel: PanelController) {
        let env = ProcessInfo.processInfo.environment
        if let url = env["MENUBAR_TODO_URL"], let token = env["MENUBAR_TODO_TOKEN"] {
            Task { _ = await model.saveConnection(url: url, token: token) }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("laser-focus.debug"), object: nil, queue: .main) { n in
            guard let cmd = n.object as? String else { return }
            MainActor.assumeIsolated { run(cmd, model: model, panel: panel) }
        }
    }

    static func run(_ line: String, model: AppModel, panel: PanelController) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let outline = panel.outline
        prepareOffscreen(panel)
        switch parts.first ?? "" {
        case "show": panel.show()
        case "hide": panel.hide()
        case "loginoff": try? SMAppService.mainApp.unregister()
        case "snapshot":
            let bits = arg.split(separator: " ").map(String.init)
            snapshot(panel, to: bits[0], dark: bits.count > 1 && bits[1] == "dark")
        case "dump": dump(model: model, panel: panel, to: arg)
        case "focus":
            if let r = model.rows.first(where: { $0.item.text == arg }) { outline.focus(r.id) }
        case "focusghost": outline.focus(OutlineController.ghostId)
        case "type":
            // Same path as the keyboard: one insert per character, each posting "text did change".
            guard let tv = panel.panel.firstResponder as? NSTextView else { break }
            OutlineController.assumeTyping = true
            defer { OutlineController.assumeTyping = false }
            for ch in arg {
                if tv.shouldChangeText(in: tv.selectedRange(), replacementString: String(ch)) {
                    tv.replaceCharacters(in: tv.selectedRange(), with: String(ch))
                    tv.didChangeText()
                }
            }
        case "caret":
            if let tv = panel.panel.firstResponder as? NSTextView { tv.setSelectedRange(NSRange(location: Int(arg) ?? 0, length: 0)) }
        case "list":
            if let l = model.outline.lists.first(where: { $0.text == arg }) { model.selectList(l.id) }
        case "key": key(arg, panel: panel)
        case "settingsnap":
            // Renders one Settings pane off-screen: settingsnap <path> <general|shortcuts|agent|connection> [dark]
            let b = arg.split(separator: " ").map(String.init)
            let view: AnyView
            switch b.count > 1 ? b[1] : "general" {
            case "shortcuts": view = AnyView(ShortcutsPane())
            case "agent": view = AnyView(AgentPane(prefs: .shared, model: model))
            case "connection": view = AnyView(ConnectionPane(model: model))
            default: view = AnyView(GeneralPane(prefs: .shared))
            }
            let host = NSHostingView(rootView: view.frame(width: 520).fixedSize().background(Color(nsColor: .windowBackgroundColor)))
            host.appearance = NSAppearance(named: b.count > 2 && b[2] == "dark" ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: b[0]))
            }
        case "tagat":
            // Which tag a click at x (in the focused row's title field) would open.
            // Uses the first visible row that has a tag and is not being edited.
            for i in 0..<outline.table.numberOfRows {
                guard let cell = outline.table.view(atColumn: 0, row: i, makeIfNecessary: false) as? RowCellView,
                      cell.field.currentEditor() == nil, !Tags.in(cell.field.stringValue).isEmpty else { continue }
                NSLog("QA rects=\(cell.field.tagRects()) tagat \(arg) on '\(cell.field.stringValue)': \(cell.field.tag(at: NSPoint(x: Double(arg) ?? 0, y: 8)) ?? "none") width=\(cell.field.bounds.width)")
                break
            }
        case "realshot":
            // Real window (true shape, material and shadow) on screen but BELOW the wallpaper, so it is never visible;
            // the window server still keeps its pixels, which `screencapture -l` reads by id.
            let w = panel.panel
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            w.setFrame(NSRect(x: vf.maxX - Theme.windowWidth - 40, y: vf.minY + 20, width: Theme.windowWidth, height: panel.fittingHeight), display: true)
            w.orderFrontRegardless()
            w.invalidateShadow()
            NSLog("QA window \(w.windowNumber)")
        case "realhide":
            panel.panel.orderOut(nil)
            panel.panel.level = .popUpMenu
        case "switcher": panel.showListSwitcher()
        case "agentsetup": Task { let r = await model.setUpAgent(); NSLog("QA agentsetup ok=\(r.ok) \(r.message)") }
        case "escape": panel.panel.cancelOperation(nil)
        case "liststyle": panel.showListStyle(arg == "new" ? nil : model.currentListId)
        case "setstyle":
            // setstyle <list name>|<icon>|<color>
            let b = arg.split(separator: "|").map(String.init)
            if b.count == 3, let l = model.outline.lists.first(where: { $0.text == b[0] }) { try? model.editor.setStyle(l.id, icon: b[1], color: b[2]) }
        case "today": model.showToday()
        case "appearance": Prefs.shared.appearance = Prefs.Appearance(rawValue: arg) ?? .automatic
        case "tag": model.showTag(arg)
        case "filter": model.filter = arg
        case "note": outline.command(.note)
        case "textsize": Prefs.shared.textSize = Double(arg) ?? 13
        case "group": Prefs.shared.groupToday = arg == "on"
        case "hidecompleted": Prefs.shared.hideCompleted = Prefs.HideCompleted(rawValue: arg) ?? .immediately
        case "clicktag":
            // Simulates clicking the first #tag of the focused row.
            if let id = outline.focusedId, let it = model.outline.item(id), let t = Tags.in(it.text).first { panel.hide(); model.showTag(t) }
        default: NSLog("debug: unknown command \(line)")
        }
    }

    /// Keeps the panel window ordered out but laid out, so views exist and the field editor works without stealing focus.
    private static func prepareOffscreen(_ panel: PanelController) {
        guard !panel.panel.isVisible else { return }
        panel.panel.setContentSize(NSSize(width: Theme.windowWidth, height: panel.fittingHeight))
        panel.panel.contentView?.layoutSubtreeIfNeeded()
        panel.outline.reload()
        panel.panel.contentView?.layoutSubtreeIfNeeded()
    }

    private static func key(_ k: String, panel: PanelController) {
        let selectors: [String: Selector] = [
            "return": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)),
            "backtab": #selector(NSResponder.insertBacktab(_:)), "up": #selector(NSResponder.moveUp(_:)),
            "down": #selector(NSResponder.moveDown(_:)), "backspace": #selector(NSResponder.deleteBackward(_:)),
            "esc": #selector(NSResponder.cancelOperation(_:)),
        ]
        if let sel = selectors[k] {
            guard let tv = panel.panel.firstResponder as? NSTextView, let field = tv.delegate as? NSTextField else { return }
            if !panel.outline.control(field, textView: tv, doCommandBy: sel) { tv.doCommand(by: sel) }
            return
        }
        var mods: NSEvent.ModifierFlags = []
        var rest = k
        while let r = rest.range(of: "-"), r.lowerBound != rest.startIndex, rest.count > 1 {
            let m = String(rest[..<r.lowerBound])
            if m == "cmd" { mods.insert(.command) } else if m == "shift" { mods.insert(.shift) } else { break }
            rest = String(rest[r.upperBound...])
        }
        let codes: [String: (UInt16, String)] = ["up": (126, "\u{F700}"), "down": (125, "\u{F701}"), "backspace": (51, "\u{8}")]
        let (code, chars) = codes[rest] ?? (0, rest)
        if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: panel.panel.windowNumber,
                                    context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
            _ = panel.panel.performKeyEquivalent(with: e)
        }
    }

    private static func snapshot(_ panel: PanelController, to path: String, dark: Bool) {
        let window = panel.panel
        let before = window.appearance
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.appearance = before }
        guard let view = window.contentView else { return }
        func redraw(_ v: NSView) { v.needsDisplay = true; v.viewDidChangeEffectiveAppearance(); v.subviews.forEach(redraw) }
        redraw(view)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let out = NSImage(size: NSSize(width: size.width + 40, height: size.height + 40))
        out.lockFocus()
        // A desktop-ish backdrop so the translucent panel reads like it does on screen.
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.92, alpha: 1)).setFill()
        NSRect(origin: .zero, size: out.size).fill()
        let panelRect = NSRect(x: 20, y: 20, width: size.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        let clip = NSBezierPath(roundedRect: panelRect, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        window.appearance!.performAsCurrentDrawingAppearance {
            (dark ? NSColor(white: 0.20, alpha: 0.96) : NSColor(white: 0.97, alpha: 0.96)).setFill()
        }
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()
        clip.addClip()
        rep.draw(in: panelRect)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return }
        _ = scale
        try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private static func dump(model: AppModel, panel: PanelController, to path: String) {
        let focused = panel.outline.focusedId
        let ghostFocused = (panel.panel.firstResponder as? NSTextView).flatMap { $0.delegate as? RowTextField }.flatMap { ($0.superview as? RowCellView)?.itemId } == OutlineController.ghostId
        let caret = (panel.panel.firstResponder as? NSTextView)?.selectedRange().location
        let obj: [String: Any] = [
            "list": model.currentList?.text ?? "",
            "zoom": model.zoomId.flatMap { model.outline.item($0)?.text } ?? "",
            "rows": model.rows.map { ["text": $0.item.text, "depth": $0.depth, "done": $0.item.isCompleted, "collapsed": $0.item.collapsed,
                                      "agent": $0.item.isUnseenAgentItem, "children": $0.hasChildren, "section": $0.isSection,
                                      "when": $0.item.whenDate ?? "", "deadline": $0.item.deadline ?? "", "note": $0.item.note ?? ""] },
            "mode": "\(model.mode)",
            "selection": (panel.panel.firstResponder as? NSTextView).map { NSStringFromRange($0.selectedRange()) } ?? "",
            "pickerOpen": panel.isPickerOpen,
            "editorTagColors": (panel.panel.firstResponder as? NSTextView).map { tv in
                Tags.ranges(in: tv.string).map { r in
                    (tv.textStorage?.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor) == Theme.accent ? "accent" : "plain"
                }
            } ?? [],
            "editorRich": (panel.panel.firstResponder as? NSTextView)?.isRichText ?? false,
            "panelHeight": panel.fittingHeight,
            "focused": focused.flatMap { model.outline.item($0)?.text } ?? (ghostFocused ? "__ghost__" : ""),
            "caret": caret ?? -1,
            "fieldText": (panel.panel.firstResponder as? NSTextView)?.string ?? "",
            "status": "\(model.status)",
            "dot": model.hasUnseenDot,
            "showCompleted": model.showCompleted,
            "pending": (try? model.store.pendingCount()) ?? -1,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
