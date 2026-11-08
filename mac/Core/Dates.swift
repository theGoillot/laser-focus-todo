import Foundation

/// Calendar days as `YYYY-MM-DD` strings in the user's own time zone (what Today means on this Mac).
public enum Day {
    nonisolated(unsafe) static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        // Follows the Mac's time zone when it changes (travel), without a relaunch.
        c.timeZone = .autoupdatingCurrent
        return c
    }()

    public static func string(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func today() -> String { string(Date()) }

    /// The local day of an ISO timestamp such as `completed_at`.
    public static func of(timestamp: String) -> String? { Clock.date(timestamp).map(string) }

    public static func date(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        let comps = DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)
        guard let d = calendar.date(from: comps), string(d) == s else { return nil }
        return d
    }

    public static func add(_ s: String, days: Int) -> String? {
        date(s).flatMap { calendar.date(byAdding: .day, value: days, to: $0) }.map(string)
    }

    /// 1 = Monday ... 7 = Sunday.
    public static func isoWeekday(_ s: String) -> Int? {
        date(s).map { (calendar.component(.weekday, from: $0) + 5) % 7 + 1 }
    }
}

/// Things-style typed dates: "today", "tmr", "fri", "next fri", "next week", "in 3 days", "3d", "2w", "dec 24", "11/20", "2026-12-01".
public enum NaturalDate {
    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    public static func parse(_ raw: String, today: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if Day.date(s) != nil, s.count == 10 { return s }
        if "today".hasPrefix(s), s.count >= 3 { return today }
        if ["tomorrow", "tmr", "tmrw", "tom"].contains(s) || ("tomorrow".hasPrefix(s) && s.count >= 3) { return Day.add(today, days: 1) }
        if s == "next week" { return nextWeekday(1, after: today) }
        if s == "next month" { return add(months: 1, to: today) }
        if ["weekend", "this weekend"].contains(s) {
            guard let wd = Day.isoWeekday(today) else { return nil }
            return wd >= 6 ? today : Day.add(today, days: 6 - wd)
        }
        if let n = amount(s) { return Day.add(today, days: n) }
        let isNext = s.hasPrefix("next ")
        let bare = isNext ? String(s.dropFirst(5)) : s
        let names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        if bare.count >= 3, let i = names.firstIndex(where: { $0.hasPrefix(bare) || (bare.count == 4 && $0.hasPrefix(String(bare.prefix(3))) && ["tues", "thur", "thurs"].contains(bare)) }) {
            // "fri": the coming Friday. "next fri": Friday of next week (weeks start Monday).
            if isNext, let wd = Day.isoWeekday(today) { return Day.add(today, days: 7 - (wd - 1) + i) }
            return nextWeekday(i + 1, after: today)
        }
        return monthDay(s, today: today)
    }

    /// "in 3 days", "3d", "2w", "3 weeks"
    private static func amount(_ s: String) -> Int? {
        var t = s
        if t.hasPrefix("in ") { t = String(t.dropFirst(3)) }
        let scanner = Scanner(string: t)
        guard let n = scanner.scanInt(), n >= 0, n < 3650 else { return nil }
        let unit = String(t[scanner.currentIndex...]).trimmingCharacters(in: .whitespaces)
        switch unit {
        case "d", "day", "days": return n
        case "w", "wk", "week", "weeks": return n * 7
        default: return nil
        }
    }

    private static func nextWeekday(_ target: Int, after today: String) -> String? {
        guard let wd = Day.isoWeekday(today) else { return nil }
        var diff = (target - wd + 7) % 7
        if diff == 0 { diff = 7 }
        return Day.add(today, days: diff)
    }

    private static func add(months n: Int, to s: String) -> String? {
        Day.date(s).flatMap { Day.calendar.date(byAdding: .month, value: n, to: $0) }.map(Day.string)
    }

    /// "dec 24", "24 dec", "december 24", "11/20" (US order). Rolls to next year when the day has passed.
    private static func monthDay(_ s: String, today: String) -> String? {
        var month: Int?
        var day: Int?
        if s.contains("/") {
            let p = s.split(separator: "/").compactMap { Int($0) }
            guard p.count == 2 else { return nil }
            month = p[0]; day = p[1]
        } else {
            let parts = s.split(separator: " ").map(String.init)
            guard parts.count == 2 else { return nil }
            for p in parts {
                if let n = Int(p) { day = n } else if let m = months.firstIndex(where: { p.count >= 3 && p.hasPrefix($0) }) { month = m + 1 }
            }
        }
        guard let m = month, let d = day, let year = Int(today.prefix(4)) else { return nil }
        let cand = String(format: "%04d-%02d-%02d", year, m, d)
        guard Day.date(cand) != nil else { return nil }
        if cand >= today { return cand }
        let next = String(format: "%04d-%02d-%02d", year + 1, m, d)
        return Day.date(next) != nil ? next : nil
    }
}

/// Short labels for row chips: "Today", "Tomorrow", "Thu", "Nov 20", "Jan 3, 2027".
public enum DayLabel {
    public static func short(_ day: String, today: String) -> String {
        guard let n = daysLeft(day, today: today), let d = Day.date(day) else { return day }
        switch n {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: break
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = Day.calendar.timeZone
        if n > 1 && n < 7 { f.dateFormat = "EEE"; return f.string(from: d) }
        f.dateFormat = day.prefix(4) == today.prefix(4) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    public static func daysLeft(_ day: String, today: String) -> Int? {
        guard let a = Day.date(today), let b = Day.date(day) else { return nil }
        return Day.calendar.dateComponents([.day], from: a, to: b).day
    }
}
