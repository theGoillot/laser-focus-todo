import Foundation

/// A list's look: a filled SF Symbol and a palette color (names shared with the backend).
public struct ListLook: Equatable, Sendable {
    public var icon: String
    public var color: String
    public init(icon: String, color: String) {
        self.icon = icon
        self.color = color
    }

    /// Same names as the backend's COLORS.
    public static let colors = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "brown", "gray"]

    /// A curated set, like North's object glyphs: filled, readable at 14pt.
    public static let icons = [
        "tray.fill", "briefcase.fill", "building.2.fill", "dollarsign.circle.fill", "chart.bar.fill", "phone.fill",
        "envelope.fill", "person.2.fill", "person.fill", "house.fill", "heart.fill", "star.fill",
        "flag.fill", "bolt.fill", "flame.fill", "scope", "target", "lightbulb.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "paintpalette.fill", "book.fill", "graduationcap.fill", "airplane",
        "car.fill", "cart.fill", "gift.fill", "fork.knife", "figure.run", "dumbbell.fill",
        "leaf.fill", "pawprint.fill", "music.note", "gamecontroller.fill", "film.fill", "sparkles",
        "brain.head.profile", "moon.fill", "sun.max.fill", "globe.americas.fill", "circle.fill", "square.stack.3d.up.fill",
    ]

    /// The style to show: what the list has, else Inbox's tray or a gray dot.
    public static func of(_ list: Item) -> ListLook {
        let fallback = list.text == "Inbox" ? ListLook(icon: "tray.fill", color: "blue") : ListLook(icon: "circle.fill", color: "gray")
        return ListLook(icon: list.icon ?? fallback.icon, color: list.color.flatMap { colors.contains($0) ? $0 : nil } ?? fallback.color)
    }
}
