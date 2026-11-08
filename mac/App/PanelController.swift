import AppKit
import Combine
import SwiftUI
import TodoCore

/// A borderless panel that can take keystrokes without activating the app, like Spotlight.
final class KeyPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    /// Esc: closes the card on top first, the panel only when there is none.
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { if let onCancel { onCancel() } else { orderOut(nil) } }
}

/// Owns the panel that drops from the menu bar icon: header, outline, footer, or the setup screen.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static var shared: PanelController?

    let model: AppModel
    let panel: KeyPanel
    let outline: OutlineController
    private var anchor: (() -> NSRect?)
    private var cancellables: Set<AnyCancellable> = []
    private let content = NSView()
    private var filterVisible = false { didSet { rebuildHeader() } }
    private var header: NSHostingView<HeaderView>!
    private var setup: NSHostingView<SetupView>?
    private var main = NSStackView()
    /// A card over the list (date picker, list switcher, list style). It owns the keyboard while open.
    private var picker: NSView?
    private var overlayMinHeight: CGFloat = 0
    var isPickerOpen: Bool { picker != nil }
    var onVisibilityChange: ((Bool) -> Void)?

    init(model: AppModel, anchor: @escaping () -> NSRect?) {
        self.model = model
        self.anchor = anchor
        outline = OutlineController(model: model)
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: Theme.windowWidth, height: Theme.maxPanelHeight)),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        PanelController.shared = self
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.picker != nil {
                self.closeOverlay(focus: nil)
                self.outline.focusForOpen()
            } else {
                self.hide()
            }
        }
        panel.setAccessibilityLabel("Laser Focus")

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        // The window's own shape: a mask on the material makes the window server cut the corners, so the blur,
        // the edge and the system shadow all follow the curve (a layer cornerRadius leaves a square window behind).
        effect.maskImage = Self.roundedMask(radius: Theme.cornerRadius)
        // Window = transparent margin + soft shadow + the rounded panel. Clicks in the clear margin pass through.
        let root = NSView()
        panel.contentView = root
        let shadow = ShadowView()
        let m = Theme.shadowMargin
        for v in [shadow, effect] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: m),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -m),
                v.topAnchor.constraint(equalTo: root.topAnchor, constant: m),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -m),
            ])
        }
        // A hairline like native menus: light on dark, dark on light, inside the curve.
        let rim = RimView()
        rim.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(rim, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            rim.leadingAnchor.constraint(equalTo: effect.leadingAnchor), rim.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            rim.topAnchor.constraint(equalTo: effect.topAnchor), rim.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        header = NSHostingView(rootView: makeHeader())
        let footer = NSHostingView(rootView: FooterView(model: model))
        main.orientation = .vertical
        main.spacing = 0
        main.alignment = .leading
        for v in [header!, outline.view, footer] as [NSView] {
            main.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
        }
        header.setContentHuggingPriority(.required, for: .vertical)
        footer.setContentHuggingPriority(.required, for: .vertical)
        outline.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        outline.onEscape = { [weak self] in self?.hide() }
        outline.onPickDate = { [weak self] id, kind in self?.showPicker(id, kind) }
        panel.appearance = Prefs.shared.appearance.nsAppearance
        Prefs.shared.$appearance.sink { [weak self] a in self?.panel.appearance = a.nsAppearance }.store(in: &cancellables)

        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitHeight() }
        }.store(in: &cancellables)
        model.$connection.map { $0 != nil }.removeDuplicates().sink { [weak self] connected in
            self?.showContent(connected: connected)
        }.store(in: &cancellables)
    }

    /// A stretchable rounded-rect mask with continuous-looking corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    private func makeHeader() -> HeaderView {
        HeaderView(model: model, onFilterSubmit: { [weak self] in self?.outline.focusFilterResult() },
                   filterVisible: Binding(get: { [weak self] in self?.filterVisible ?? false }, set: { [weak self] in self?.filterVisible = $0 }))
    }

    private func rebuildHeader() { header.rootView = makeHeader() }

    private func showContent(connected: Bool) {
        content.subviews.forEach { $0.removeFromSuperview() }
        let v: NSView
        if connected {
            v = main
            setup = nil
        } else {
            let s = NSHostingView(rootView: SetupView(model: model))
            setup = s
            v = s
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.topAnchor.constraint(equalTo: content.topAnchor),
            v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        if connected && panel.isVisible { outline.focusForOpen() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    func show(focusing id: String? = nil) {
        position()
        let wasVisible = panel.isVisible
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible {
            model.panelOpened()
            onVisibilityChange?(true)
        }
        outline.reload()
        if let id { outline.focus(id) } else if !wasVisible { outline.focusForOpen() }
    }

    func hide() {
        guard panel.isVisible else { return }
        outline.commitAll()
        picker?.removeFromSuperview()
        picker = nil
        outline.suspendFocus = false
        filterVisible = false
        model.filter = ""
        panel.orderOut(nil)
        onVisibilityChange?(false)
    }

    /// Height that fits the rows (plus the ghost row), between a calm minimum and the maximum.
    /// Window height: the panel plus the shadow margin above and below.
    var fittingHeight: CGFloat { panelHeight + Theme.shadowMargin * 2 }

    var panelHeight: CGFloat {
        guard model.connection != nil else { return 300 }
        let chrome = header.fittingSize.height + 30 + 14
        let h = min(Theme.maxPanelHeight, max(Theme.minPanelHeight, (chrome + outline.contentHeight).rounded()))
        return picker == nil ? h : max(h, overlayMinHeight)
    }

    // MARK: Date picker

    func showPicker(_ id: String, _ kind: DateKind) {
        guard picker == nil, let it = model.outline.item(id) else { return }
        let card = DatePickerCard(kind: kind, today: model.today, current: kind == .when ? it.whenDate : it.deadline,
                                  onPick: { [weak self] day in
                                      guard let self else { return }
                                      if kind == .when { self.model.setWhen(id, day) } else { self.model.setDeadline(id, day) }
                                      self.closeOverlay(focus: id)
                                  },
                                  onCancel: { [weak self] in self?.closeOverlay(focus: id) })
        showOverlay(card, minHeight: 540)
    }

    /// The Things-style list switcher, dropped under the title.
    func showListSwitcher() {
        guard picker == nil, model.connection != nil else { return }
        let focusBack = outline.focusedId
        showOverlay(ListSwitcher(model: model, close: { [weak self] action in
            guard let self else { return }
            self.closeOverlay(focus: nil)
            switch action {
            case .none: if let f = focusBack { self.outline.focus(f) } else { self.outline.focusForOpen() }
            case .newList: DispatchQueue.main.async { self.showListStyle(nil) }
            case let .edit(id): DispatchQueue.main.async { self.showListStyle(id) }
            case .opened: DispatchQueue.main.async { self.outline.focusForOpen() }
            }
        }), minHeight: 420)
    }

    /// Name, color and icon of a list (`id` nil = a new list).
    func showListStyle(_ id: String?) {
        guard picker == nil else { return }
        let it = id.flatMap { model.outline.item($0) }
        let start = it.map(ListLook.of) ?? ListLook(icon: "circle.fill", color: "blue")
        showOverlay(ListStyleEditor(name: it?.text ?? "", style: start, isNew: id == nil, onSave: { [weak self] name, style in
            guard let self else { return }
            if let id {
                if name != it?.text { try? self.model.editor.setText(id, name) }
                try? self.model.editor.setStyle(id, icon: style.icon, color: style.color)
            } else if let new = try? self.model.editor.newList(named: name, icon: style.icon, color: style.color) {
                self.model.selectList(new)
            }
            self.closeOverlay(focus: nil)
            DispatchQueue.main.async { self.outline.focusForOpen() }
        }, onCancel: { [weak self] in
            self?.closeOverlay(focus: nil)
            DispatchQueue.main.async { self?.outline.focusForOpen() }
        }), minHeight: 520)
    }

    private func showOverlay<V: View>(_ view: V, minHeight: CGFloat) {
        let host = NSHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        picker = host
        overlayMinHeight = minHeight
        outline.suspendFocus = true
        fitHeight()
    }

    private func closeOverlay(focus id: String?) {
        // Removed on the next turn: this runs inside the card's own button action.
        let old = picker
        DispatchQueue.main.async { old?.removeFromSuperview() }
        picker = nil
        outline.suspendFocus = false
        fitHeight()
        if let id { outline.focus(id) }
    }

    /// Grows or shrinks from the top edge, so the panel stays pinned under the menu bar.
    func fitHeight() {
        let h = fittingHeight
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true, animate: false)
    }

    private func position() {
        let size = NSSize(width: Theme.windowWidth, height: fittingHeight)
        let m = Theme.shadowMargin
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: NSPoint
        // The visible panel sits 6pt under the menu bar; the window extends `m` beyond it on every side.
        if let a = anchor(), let s = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: a.midX, y: a.midY)) }) {
            origin = NSPoint(x: a.midX - size.width / 2, y: a.minY - size.height - 6 + m)
            origin.x = min(max(origin.x, s.visibleFrame.minX + 8 - m), s.visibleFrame.maxX - size.width - 8 + m)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 12 + m, y: visible.maxY - size.height - 6 + m)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Closes when I click elsewhere, like a menu. A modal alert from the app keeps it open.
        if NSApp.modalWindow == nil { hide() }
    }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        // The picker owns the keyboard while it is open (its text field, Return and Esc).
        if picker != nil { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode
        let up: UInt16 = 126, down: UInt16 = 125, backspace: UInt16 = 51
        switch (mods, key, code) {
        case (.command, "k", _): outline.command(.tick)
        case (.command, "t", _): outline.command(.today)
        case (.command, "s", _): outline.command(.when)
        case ([.command, .shift], "d", _): outline.command(.deadline)
        case (.command, "0", _): model.showToday()
        case (.command, ",", _): hide(); SettingsWindowController.shared.open()
        case (.command, _, up): outline.command(.collapse)
        case (.command, _, down): outline.command(.expand)
        case ([.command, .shift], _, up): outline.command(.moveUp)
        case ([.command, .shift], _, down): outline.command(.moveDown)
        case (.command, ".", _): outline.command(.zoomIn)
        case ([.command, .shift], ".", _), ([.command, .shift], ">", _): model.zoomOut()
        case (.command, _, backspace): outline.command(.delete)
        case (.command, "z", _): outline.command(.undo)
        case ([.command, .shift], "z", _): outline.command(.redo)
        case (.command, "f", _): filterVisible = true
        case ([.command, .shift], "h", _): model.showCompleted.toggle()
        case (.command, "n", _): outline.command(.newAtTop)
        case (.command, "[", _): model.cycleList(-1)
        case (.command, "]", _): model.cycleList(1)
        case (.command, "w", _): hide()
        case (.command, "r", _): model.syncNow()
        case (.command, "q", _): outline.commitAll(); NSApp.terminate(nil)
        default:
            if mods == .command, let n = Int(key), (1...9).contains(n), n <= model.outline.lists.count {
                model.selectList(model.outline.lists[n - 1].id)
                return true
            }
            return false
        }
        return true
    }
}

/// The panel's hairline edge, drawn inside the rounded shape. Never takes clicks.
final class RimView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Theme.cornerRadius - 0.5, yRadius: Theme.cornerRadius - 0.5)
        path.lineWidth = 1
        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)).setStroke()
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A tight, soft shadow under the rounded panel (like a native menu), drawn by us so it stays small.
final class ShadowView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.cornerRadius, cornerHeight: Theme.cornerRadius, transform: nil)
    }
}
