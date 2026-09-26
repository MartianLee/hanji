import SwiftUI
import Combine
import ExtensionSDK

/// First-party calendar panel: month grid with dots on days that have a daily
/// note; clicking a day opens-or-creates it. Daily notes come from whichever
/// plugin provides the daily-note service (Journal); without one, the
/// calendar is just a calendar.
public struct CalendarPlugin: Plugin {
    public static let id = "io.hanji.calendar"
    public static let displayName = "Calendar"
    public init() {}

    public func activate(host: PluginHost) {
        host.ui.addSidebarView(id: "calendar", title: "Calendar") { [weak host] in
            guard let host else { return AnyView(EmptyView()) }
            return AnyView(CalendarView(services: host.services,
                                        updates: host.query.indexDidUpdate.merge(with: host.services.servicesDidChange)
                                            .eraseToAnyPublisher()))
        }
    }
}

struct CalendarView: View {
    let services: ServiceRegistry
    let updates: AnyPublisher<Void, Never>

    @State private var month = Date()
    @State private var dottedDays: Set<Int> = []
    @State private var hasDailyNotes = false

    private var calendar: Calendar { Calendar.current }
    private var weeks: [[CalendarGrid.Day]] { CalendarGrid.weeks(for: month, calendar: calendar) }

    var body: some View {
        VStack(spacing: 6) {
            header
            weekdayRow
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                }
            }
            if !hasDailyNotes {
                Text("Turn on Journal to open daily notes from here.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { refreshDots() }
        .onChange(of: month) { _, _ in refreshDots() }
        .onReceive(updates) { refreshDots() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
            Text(CalendarGrid.monthTitle(for: month, locale: Locale.current))
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
            Button("오늘") { month = Date() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var weekdayRow: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let rotated = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(rotated, id: \.self) { s in
                Text(s).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func dayCell(_ day: CalendarGrid.Day) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        Button { open(day.date) } label: {
            VStack(spacing: 1) {
                Text("\(day.day)")
                    .font(.caption)
                    .frame(width: 22, height: 18)
                    .background(isToday ? Color.accentColor.opacity(0.25) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Circle()
                    .fill(day.inMonth && dottedDays.contains(day.day) ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .opacity(day.inMonth ? 1 : 0.3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasDailyNotes)
    }

    private func shift(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) { month = next }
    }

    /// Days of the displayed month that already have a daily note.
    private func refreshDots() {
        let daily = services.dailyNotes
        hasDailyNotes = daily != nil
        guard let daily else { dottedDays = []; return }
        dottedDays = Set(weeks.flatMap { $0 }.filter { $0.inMonth && daily.hasDailyNote(on: $0.date) }.map(\.day))
    }

    /// Open-or-create the day's daily note (same pipeline as the ⌘P command).
    private func open(_ date: Date) {
        services.dailyNotes?.openDailyNote(on: date)
    }
}
