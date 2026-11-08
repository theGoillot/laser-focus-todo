import AppKit
import Combine

/// User settings (the Settings window), saved in UserDefaults. Changing any of them redraws the panel.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    enum HideCompleted: String, CaseIterable, Identifiable {
        case immediately, nextDay, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .immediately: "Immediately"
            case .nextDay: "The next day"
            case .never: "Never"
            }
        }
    }

    enum MenuBarCount: String, CaseIterable, Identifiable {
        case none, today, inbox
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .today: "Today"
            case .inbox: "Inbox"
            }
        }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case automatic, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var nsAppearance: NSAppearance? {
            switch self {
            case .automatic: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    @Published var hideCompleted: HideCompleted { didSet { d.set(hideCompleted.rawValue, forKey: "hideCompleted") } }
    @Published var menuBarCount: MenuBarCount { didSet { d.set(menuBarCount.rawValue, forKey: "menuBarCount") } }
    @Published var appearance: Appearance { didSet { d.set(appearance.rawValue, forKey: "appearance") } }
    /// Point size of to-do text. 13 is the default.
    @Published var textSize: Double { didSet { d.set(textSize, forKey: "textSize") } }
    @Published var groupToday: Bool { didSet { d.set(groupToday, forKey: "groupToday") } }
    @Published var showBanners: Bool { didSet { d.set(showBanners, forKey: "showBanners") } }

    static let textSizes: ClosedRange<Double> = 11...18

    private init() {
        hideCompleted = HideCompleted(rawValue: d.string(forKey: "hideCompleted") ?? "") ?? .immediately
        menuBarCount = MenuBarCount(rawValue: d.string(forKey: "menuBarCount") ?? "") ?? .today
        appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .automatic
        let size = d.double(forKey: "textSize")
        textSize = size == 0 ? 13 : min(max(size, Self.textSizes.lowerBound), Self.textSizes.upperBound)
        groupToday = d.object(forKey: "groupToday") as? Bool ?? true
        showBanners = d.object(forKey: "showBanners") as? Bool ?? true
    }
}
