import AppKit
import Combine
import GRDB
import Network
import TodoCore

/// The app's single source of UI state. Owns the local store, sync engine, live socket and editor.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: LocalStore
    let editor: OutlineEditor
    #if DEBUG
    // Debug builds (QA runs) never share the Keychain entry or the database with the installed app.
    static let suffix = "-Debug"
    let tokens = TokenStore(service: (Bundle.main.bundleIdentifier ?? "laser-focus") + ".debug")
    #else
    static let suffix = ""
    let tokens = TokenStore()
    #endif
    /// The agent's display name. Comes from the backend (AGENT_NAME) on connect; cached for offline starts.
    @Published private(set) var agentName: String

    @Published private(set) var outline = Outline(items: [])
    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var connection: Connection?
    /// What the panel shows: a list (or a zoomed item in it), Things' Today, or every item with one #tag.
    enum ViewMode: Equatable {
        case list, today
        case tag(String)
    }

    @Published var mode: ViewMode = .list { didSet { persistView() } }
    @Published var currentListId: String? { didSet { persistView() } }
    @Published var zoomId: String? { didSet { persistView() } }
    @Published var showCompleted = false
    @Published var filter = ""
    @Published var hasUnseenDot = false
    /// Rows ticked a moment ago, still shown while they fade out.
    @Published private(set) var fading: Set<String> = []
    /// Agent items that arrived while the panel was closed, for the notifier.
    let agentItemsArrived = PassthroughSubject<([Item], Outline), Never>()

    private var engine: SyncEngine?
    private var socket: LiveSocket?
    private var observation: AnyDatabaseCancellable?
    private var timer: Timer?
    private var retry: Timer?
    private let path = NWPathMonitor()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MenuBarTodo" + Self.suffix, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            store = try LocalStore(path: dir.appending(path: "todo.sqlite").path)
        } catch {
            fatalError("Cannot open local database: \(error)")
        }
        editor = OutlineEditor(store: store)
        agentName = UserDefaults.standard.string(forKey: "agentName") ?? "Agent"
        currentListId = try? store.meta("currentList")
        zoomId = try? store.meta("zoom")
        if (try? store.meta("mode")) == "today" { mode = .today }
        Prefs.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }.store(in: &cancellables)
        // Today changes at midnight, or when the Mac changes time zone, even if nothing else does.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        }
        observation = store.observeLive { [weak self] items in
            MainActor.assumeIsolated { self?.refresh(items) }
        }
        editor.onChange = { [weak self] in self?.engine?.kick() }
        connect(tokens.load())
        // Safety net only: the live socket pushes every change within a second, and reconnects pull what was missed.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine?.kick() }
        }
        path.pathUpdateHandler = { [weak self] p in
            guard p.status == .satisfied else { return }
            Task { @MainActor in
                self?.socket?.reconnectNow()
                self?.engine?.kick()
            }
        }
        path.start(queue: .global(qos: .utility))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.socket?.reconnectNow()
                self?.engine?.kick()
            }
        }
    }

    private var loaded = false

    private func refresh(_ items: [Item]) {
        let o = Outline(items: items)
        outline = o
        if !loaded {
            loaded = true
            hasUnseenDot = AgentAnnouncer.hasUnseen(o)
        }
        if let z = zoomId, o.item(z) == nil { zoomId = nil }
        if currentListId == nil || o.item(currentListId!) == nil {
            currentListId = o.lists.first(where: { $0.text == "Inbox" })?.id ?? o.lists.first?.id
        }
    }

    private func persistView() {
        try? store.setMeta("currentList", currentListId ?? "")
        try? store.setMeta("zoom", zoomId ?? "")
        try? store.setMeta("mode", mode == .today ? "today" : "list")
    }

    // MARK: Connection

    func connect(_ c: Connection?) {
        socket?.stop()
        socket = nil
        engine = nil
        connection = c
        // The local copy belongs to one backend. A different backend starts from an empty copy and version 0.
        if let c, (try? store.meta("backend")) != c.baseURL.absoluteString {
            try? store.resetAll()
            try? store.setMeta("backend", c.baseURL.absoluteString)
            currentListId = nil
            zoomId = nil
        }
        guard let c else {
            status = .idle
            return
        }
        let api = APIClient(baseURL: c.baseURL, token: c.token)
        let engine = SyncEngine(store: store, api: api, onAgentItems: { [weak self] items in
            Task { @MainActor in self?.agentArrived(items) }
        }, onStatus: { [weak self] s in
            Task { @MainActor in self?.statusChanged(s) }
        })
        self.engine = engine
        let socket = LiveSocket(makeRequest: { api.liveRequest() }, onVersion: { v in
            Task { await engine.versionAnnounced(v) }
        }, onConnected: {
            Task { await engine.socketConnected() }
        })
        self.socket = socket
        socket.start()
        engine.kick()
        refreshAgentName(api)
    }

    /// Learns the agent's display name from the backend (its AGENT_NAME), so forks never need code changes for it.
    private func refreshAgentName(_ api: APIClient) {
        Task { @MainActor in
            guard let name = try? await api.agentSetup().agentName, !name.isEmpty, name != agentName else { return }
            agentName = name
            UserDefaults.standard.set(name, forKey: "agentName")
        }
    }

    /// Checks the URL and token against the backend, then saves them to the Keychain.
    func saveConnection(url: String, token: String) async -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let base = URL(string: s.hasSuffix("/") ? s : s + "/") else { return "That URL doesn't look right." }
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let api = APIClient(baseURL: base, token: tok)
        guard await api.health() else { return "Can't reach the backend at that URL." }
        do {
            _ = try await api.sync(since: Int.max)
        } catch APIError.unauthorized {
            return "The backend refused that token."
        } catch {
            return "Connected, but sync failed: \(error.localizedDescription)"
        }
        let c = Connection(baseURL: base, token: tok)
        do {
            try tokens.save(c)
        } catch {
            return "Couldn't save to the Keychain."
        }
        connect(c)
        return nil
    }

    func disconnect() {
        tokens.clear()
        try? store.resetAll()
        try? store.setMeta("backend", "")
        connect(nil)
    }

    func syncNow() { engine?.kick() }

    // MARK: Agent setup

    /// Fetches the agent's key from the backend, saves it to ~/.config/laser-focus/agent.env (owner-only),
    /// and puts the instructions for the agent on the clipboard. Returns a message for the UI.
    func setUpAgent() async -> (ok: Bool, message: String) {
        guard let c = connection else { return (false, "Connect this Mac first.") }
        do {
            let setup = try await APIClient(baseURL: c.baseURL, token: c.token).agentSetup()
            let path = AgentSetup.envPath()
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(setup.envFile.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            copy(setup.instructions(agentName: agentName, envPath: path))
            return (true, "Saved the key to \((path as NSString).abbreviatingWithTildeInPath). Instructions copied: paste them into \(agentName).")
        } catch APIError.unauthorized {
            return (false, "The backend refused this Mac's token.")
        } catch {
            return (false, "Couldn't get the agent setup: \(error.localizedDescription)")
        }
    }

    /// The clipboard, except in quiet QA runs (they log instead, so the owner's clipboard is never touched).
    private func copy(_ text: String) {
        if ProcessInfo.processInfo.environment["MENUBAR_TODO_QUIET"] == "1" { NSLog("QA clipboard: \(text)"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Copies the standard mcpServers JSON (with the key) for agents configured by file.
    func copyAgentConfig() async -> (ok: Bool, message: String) {
        guard let c = connection else { return (false, "Connect this Mac first.") }
        do {
            let setup = try await APIClient(baseURL: c.baseURL, token: c.token).agentSetup()
            copy(setup.mcpConfigJSON)
            return (true, "MCP config copied (it contains the key: paste it only into the agent's config).")
        } catch {
            return (false, "Couldn't get the agent setup: \(error.localizedDescription)")
        }
    }

    /// While offline, retry every 5 seconds (the socket also reconnects on its own backoff).
    private func statusChanged(_ s: SyncStatus) {
        status = s
        retry?.invalidate()
        retry = nil
        if s == .offline {
            retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.socket?.reconnectNow()
                    self?.engine?.kick()
                }
            }
        }
    }

    // MARK: Agent items

    private func agentArrived(_ items: [Item]) {
        hasUnseenDot = true
        // The observed outline may lag the merge by a tick: announce from what the store holds now.
        let fresh = Outline(items: (try? store.liveItems()) ?? [])
        agentItemsArrived.send((items, fresh))
    }

    // MARK: View helpers

    var currentList: Item? { currentListId.flatMap { outline.item($0) } }
    /// The item whose children fill the panel: the zoomed item, else the current list.
    var floorId: String? { zoomId ?? currentListId }

    var today: String { Day.today() }
    var isVirtual: Bool { mode != .list }
    var inbox: Item? { outline.lists.first(where: { $0.text == "Inbox" }) ?? outline.lists.first }

    /// Completed rows still shown: the ones fading out, plus what the "Hide completed items" setting keeps.
    private var keep: Set<String> {
        var k = fading
        if Prefs.shared.hideCompleted == .nextDay {
            for it in outline.byId.values where it.completedAt.flatMap(Day.of(timestamp:)) == today { k.insert(it.id) }
        }
        return k
    }

    /// The row being edited stays on screen even if it stops matching the view (its tag or date changed mid-typing).
    var editingId: String?

    var effectiveShowCompleted: Bool { showCompleted || Prefs.shared.hideCompleted == .never }

    var rows: [Outline.Row] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let flat = { (items: [Item]) in items.map { Outline.Row(item: $0, depth: 0, hasChildren: false) } }
        let keep = self.keep
        let editing: Set<String> = editingId.map { [$0] } ?? []
        let showDone = effectiveShowCompleted
        let visible = { (i: Item) in showDone || !i.isCompleted || keep.contains(i.id) }
        // "#80" in the filter: every item with a tag starting with 80, across all lists.
        if q.hasPrefix("#"), q.count > 1 { return flat(outline.tagged(prefix: String(q.dropFirst()), keep: editing).filter(visible)) }
        switch mode {
        case .today:
            var keepToday = keep.union(editing)
            if effectiveShowCompleted { keepToday.formUnion(outline.byId.values.filter(\.isCompleted).map(\.id)) }
            let groups = outline.today(today, keep: keepToday)
            let matches = { (i: Item) in q.isEmpty || i.text.lowercased().contains(q) }
            if !Prefs.shared.groupToday { return flat(groups.flatMap(\.items).filter(matches)) }
            return groups.flatMap { g -> [Outline.Row] in
                let items = g.items.filter(matches)
                guard !items.isEmpty else { return [] }
                var header = Outline.Row(item: g.list, depth: 0, hasChildren: false)
                header.isSection = true
                return [header] + flat(items)
            }
        case let .tag(t):
            return flat(outline.tagged(t, keep: editing).filter { visible($0) && (q.isEmpty || editing.contains($0.id) || $0.text.lowercased().contains(q)) })
        case .list:
            guard let floor = floorId else { return [] }
            if q.isEmpty { return outline.rows(under: floor, showCompleted: effectiveShowCompleted, keep: keep) }
            // Filtering: every matching item under the floor, flat, in tree order.
            var out: [Outline.Row] = []
            func walk(_ id: String) {
                for c in outline.children(of: id) {
                    if visible(c) && c.text.lowercased().contains(q) { out.append(Outline.Row(item: c, depth: 0, hasChildren: false)) }
                    walk(c.id)
                }
            }
            walk(floor)
            return out
        }
    }

    /// The list a row lives in (shown on rows of Today and tag views when they are not grouped).
    func listName(of id: String) -> String? { outline.rootList(of: id)?.text }

    func showToday() {
        mode = .today
        zoomId = nil
        filter = ""
    }

    func showTag(_ tag: String) {
        mode = .tag(tag.lowercased())
        zoomId = nil
        filter = ""
    }

    func toggleToday(_ id: String) { try? editor.toggleToday(id, today: today) }
    func setWhen(_ id: String, _ day: String?) { try? editor.setWhen(id, day) }
    func setDeadline(_ id: String, _ day: String?) { try? editor.setDeadline(id, day) }

    var todayCount: Int { outline.todayCount(today) }

    /// What the menu bar shows next to the icon, per the setting.
    var menuBarCount: Int {
        switch Prefs.shared.menuBarCount {
        case .none: 0
        case .today: todayCount
        case .inbox: inbox.map { outline.openCount(under: $0.id) } ?? 0
        }
    }

    func tick(_ id: String) {
        guard let it = outline.item(id) else { return }
        try? editor.toggleComplete(id)
        try? editor.markSeen([id])
        if !it.isCompleted && !effectiveShowCompleted {
            fading.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.fading.remove(id) }
        }
    }

    func zoom(into id: String) {
        guard outline.item(id) != nil else { return }
        mode = .list
        if let root = outline.rootList(of: id), root.id == id {
            currentListId = id
            zoomId = nil
        } else {
            zoomId = id
        }
    }

    func zoomOut() {
        guard let z = zoomId, let it = outline.item(z) else { return }
        zoomId = (it.parentId == currentListId) ? nil : it.parentId
    }

    func selectList(_ id: String) {
        mode = .list
        currentListId = id
        zoomId = nil
        filter = ""
    }

    /// Cmd-[ / Cmd-]: Today, then each list, round and round.
    func cycleList(_ d: Int) {
        let stops: [String?] = [nil] + outline.lists.map(\.id)
        let cur: String? = mode == .list ? currentListId : nil
        let i = stops.firstIndex(where: { $0 == cur }) ?? 0
        if let next = stops[(i + d + stops.count) % stops.count] { selectList(next) } else { showToday() }
    }

    /// Shows the item: switches to its list, zooms to its parent if it is deep, and returns its id for focusing.
    func reveal(_ id: String) -> String? {
        guard let it = outline.item(id), let root = outline.rootList(of: id) else { return nil }
        mode = .list
        currentListId = root.id
        zoomId = nil
        filter = ""
        var cur = it.parentId
        while let c = cur, c != root.id, let p = outline.item(c) {
            if p.collapsed { try? editor.setCollapsed(c, false) }
            cur = p.parentId
        }
        if it.isCompleted { showCompleted = true }
        return id
    }

    func panelOpened() {
        hasUnseenDot = false
        try? editor.logOpened()
        engine?.kick()
    }

    var unseenCount: Int { outline.unseenAgentItems.count }
}

