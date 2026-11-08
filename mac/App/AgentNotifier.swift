import AppKit
import TodoCore
import UserNotifications

/// One macOS banner per new agent item ("Agent added to Work"), with Done and Open.
/// No banner when the panel is already open on that list: the row just appears with its tag.
@MainActor
final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let category = "AGENT_ITEM"
    private let center = UNUserNotificationCenter.current()
    var onDone: ((String) -> Void)?
    var onOpen: ((String) -> Void)?

    func setUp() {
        center.delegate = self
        if quiet { return }
        let done = UNNotificationAction(identifier: "DONE", title: "Done", options: [])
        let open = UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [done, open], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// Debug QA runs set MENUBAR_TODO_QUIET=1 so no real banner appears on screen.
    var quiet = ProcessInfo.processInfo.environment["MENUBAR_TODO_QUIET"] == "1"

    func announce(_ items: [Item], outline: Outline, agentName: String) {
        if quiet {
            for it in items { NSLog("QA: would announce \(AgentAnnouncer.title(for: it, agentName: agentName, outline: outline)): \(it.text)") }
            return
        }
        guard Prefs.shared.showBanners else { return }
        for it in items.prefix(5) {
            let c = UNMutableNotificationContent()
            c.title = AgentAnnouncer.title(for: it, agentName: agentName, outline: outline)
            c.body = it.text
            c.categoryIdentifier = Self.category
            c.threadIdentifier = "agent"
            c.userInfo = ["id": it.id]
            center.add(UNNotificationRequest(identifier: it.id, content: c, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["id"] as? String else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            if action == "DONE" { self.onDone?(id) } else { self.onOpen?(id) }
        }
    }
}
