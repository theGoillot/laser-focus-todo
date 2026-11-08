import Foundation

/// Decides what the user hears about agent items. Pure, so the rules are tested.
public enum AgentAnnouncer {
    /// One banner per new, open, unseen agent item, except items landing in the list the open panel already shows.
    public static func itemsToAnnounce(_ items: [Item], panelVisibleOnList: String?, outline: Outline) -> [Item] {
        items.filter { it in
            guard it.isUnseenAgentItem, !it.isCompleted else { return false }
            guard let visible = panelVisibleOnList else { return true }
            return outline.rootList(of: it.id)?.id != visible
        }
    }

    public static func title(for item: Item, agentName: String, outline: Outline) -> String {
        "\(agentName) added to \(outline.rootList(of: item.id)?.text ?? "Inbox")"
    }

    /// The menu bar dot: any agent item not yet looked at.
    public static func hasUnseen(_ outline: Outline) -> Bool { !outline.unseenAgentItems.isEmpty }
}
