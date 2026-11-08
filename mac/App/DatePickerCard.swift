import SwiftUI
import TodoCore

/// Things-style When / Deadline picker, shown over the list. Type a date ("fri", "in 3 days", "dec 24"), pick a quick
/// option, or click the calendar. Return applies, Esc cancels.
struct DatePickerCard: View {
    let kind: DateKind
    let today: String
    let current: String?
    var onPick: (String?) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    init(kind: DateKind, today: String, current: String?, onPick: @escaping (String?) -> Void, onCancel: @escaping () -> Void) {
        self.kind = kind
        self.today = today
        self.current = current
        self.onPick = onPick
        self.onCancel = onCancel
    }

    private var parsed: String? { NaturalDate.parse(text, today: today) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            card
                .padding(.top, 54)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: kind == .when ? "calendar" : "flag.fill")
                    .foregroundStyle(kind == .when ? Color.accentColor : Color.red)
                Text(kind == .when ? "When" : "Deadline").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let current {
                    Text(DayLabel.short(current, today: today)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField(kind == .when ? "tomorrow, fri, in 3 days, dec 24" : "fri, next week, dec 24", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(submit)
                    .onExitCommand(perform: onCancel)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                Text(hint).font(.system(size: 11)).foregroundStyle(parsed == nil && !text.isEmpty ? Color.red : Color.secondary)
                    .padding(.leading, 4)
            }
            quickOptions
            WeeksGrid(today: today, selected: current, onPick: { onPick($0) })
            HStack {
                if current != nil {
                    Button(role: .destructive) { onPick(nil) } label: { Text(kind == .when ? "Clear date" : "Clear deadline") }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", action: onCancel).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(16)
        .frame(width: 330)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .onAppear { focused = true }
    }

    private var hint: String {
        if text.isEmpty { return "Type a date, or click a day." }
        guard let p = parsed, let d = Day.date(p) else { return "Not a date I understand." }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: d)
    }

    private var quickOptions: some View {
        HStack(spacing: 5) {
            if kind == .when {
                quick("Today", icon: "star.fill", tint: Color(nsColor: Theme.star), day: today)
            } else {
                quick("Today", icon: nil, tint: nil, day: today)
            }
            quick("Tomorrow", icon: nil, tint: nil, day: NaturalDate.parse("tomorrow", today: today))
            quick("Weekend", icon: nil, tint: nil, day: NaturalDate.parse("this weekend", today: today))
            quick("Next week", icon: nil, tint: nil, day: NaturalDate.parse("next week", today: today))
        }
    }

    private func quick(_ title: String, icon: String?, tint: Color?, day: String?) -> some View {
        Button { if let day { onPick(day) } } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).foregroundStyle(tint ?? .primary) }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(day == current ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain)
    }

    private func submit() {
        if let p = parsed { onPick(p) }
    }
}

/// Things-style calendar: rolling weeks from this week, big day numbers, the month name on its first day,
/// today in the accent color. Arrows page by four weeks.
struct WeeksGrid: View {
    let today: String
    let selected: String?
    var onPick: (String) -> Void
    @State private var offsetWeeks = 0

    private let labels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let month: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()

    private var start: String {
        let wd = (Day.isoWeekday(today) ?? 1) - 1
        return Day.add(today, days: -wd + offsetWeeks * 7) ?? today
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { offsetWeeks = max(0, offsetWeeks - 4) } label: { Image(systemName: "chevron.left") }
                    .disabled(offsetWeeks == 0)
                Button { offsetWeeks += 4 } label: { Image(systemName: "chevron.right") }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 4)
            HStack(spacing: 0) {
                ForEach(labels, id: \.self) { Text($0).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).frame(maxWidth: .infinity) }
            }
            ForEach(0..<6, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { d in cell(Day.add(start, days: w * 7 + d) ?? start) }
                }
            }
        }
    }

    private var title: String {
        guard let d = Day.date(start) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    @ViewBuilder private func cell(_ day: String) -> some View {
        let isToday = day == today
        let isSelected = day == selected
        let past = day < today
        let first = day.hasSuffix("-01")
        Button { onPick(day) } label: {
            VStack(spacing: -2) {
                if first, let d = Day.date(day) {
                    Text(Self.month.string(from: d)).font(.system(size: 9, weight: .bold))
                }
                Text(String(Int(day.suffix(2)) ?? 0)).font(.system(size: 14, weight: isToday || isSelected ? .bold : .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(isSelected ? Color.white : isToday ? Color.accentColor : past ? Color.secondary.opacity(0.5) : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : isToday ? Color.accentColor.opacity(0.14) : Color.clear)
                    .padding(1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
