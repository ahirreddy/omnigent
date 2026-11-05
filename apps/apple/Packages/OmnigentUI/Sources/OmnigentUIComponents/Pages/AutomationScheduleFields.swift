import SwiftUI

/// The schedule picker: a preset, the time, the custom unit, interval and days, and the ending.
/// Custom schedules and run-count endings need a server with anchored scheduling.
struct ScheduleFields: View {
  @Binding var choice: ScheduleChoice
  var anchoredScheduling = true

  private static let weekdayNames = Calendar.current.shortWeekdaySymbols

  var body: some View {
    Picker("Repeats", selection: $choice.preset) {
      ForEach(ScheduleChoice.Preset.allCases) { preset in
        Text(preset.title).tag(preset)
          .selectionDisabled(preset == .custom && !anchoredScheduling && choice.preset != .custom)
      }
    }
    .accessibilityIdentifier("automation-schedule-preset")
    if choice.preset == .custom {
      Stepper(value: $choice.interval, in: 1...366) {
        Picker("Every \(choice.interval)", selection: $choice.frequency) {
          ForEach(ScheduleChoice.Frequency.allCases) { Text($0.title).tag($0) }
        }
      }
    }
    if showsWeekdays { weekdays }
    if choice.preset == .custom, choice.frequency == .yearly {
      Picker("Month", selection: $choice.month) {
        ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
      }
    }
    if choice.preset == .custom, [.monthly, .yearly].contains(choice.frequency) {
      TextField("Days of the month", text: monthDays, prompt: Text("1, 15"))
    }
    if isHourly {
      Picker("At minute", selection: $choice.minute) {
        ForEach(0..<60, id: \.self) { Text($0 < 10 ? ":0\($0)" : ":\($0)").tag($0) }
      }
    } else {
      DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
        .accessibilityIdentifier("automation-schedule-time")
    }
    ending
  }

  /// The ending as the web's "ends" select: never, on a date, or after a number of runs.
  @ViewBuilder private var ending: some View {
    Picker("Ends", selection: endKind) {
      Text("Never").tag(EndKind.never)
      Text("On date").tag(EndKind.until)
      if anchoredScheduling || endKind.wrappedValue == .count {
        Text("After").tag(EndKind.count)
          .selectionDisabled(!anchoredScheduling)
      }
    }
    .accessibilityIdentifier("automation-schedule-end")
    switch choice.end {
    case .never:
      EmptyView()
    case .until(let date):
      DatePicker(
        "End date",
        selection: Binding(get: { date }, set: { choice.end = .until(endOfDay($0)) }),
        displayedComponents: .date
      )
      .accessibilityIdentifier("automation-schedule-until")
    case .count(let count):
      Stepper(
        value: Binding(get: { count }, set: { choice.end = .count($0) }), in: 2...9_999
      ) {
        Text(count == 1 ? "1 run" : "\(count) runs")
      }
      .disabled(!anchoredScheduling)
      .accessibilityIdentifier("automation-schedule-count")
    }
  }

  private enum EndKind: Hashable { case never, until, count }

  private var endKind: Binding<EndKind> {
    Binding(
      get: {
        switch choice.end {
        case .never: .never
        case .until: .until
        case .count: .count
        }
      },
      set: { kind in
        switch kind {
        case .never: choice.end = .never
        case .until: choice.end = .until(endOfDay(Date().addingTimeInterval(7 * 86_400)))
        case .count: choice.end = .count(2)
        }
      })
  }

  /// The web ends a schedule at the last second of the chosen day.
  private func endOfDay(_ date: Date) -> Date {
    let start = Calendar.current.startOfDay(for: date)
    return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
  }

  private var isHourly: Bool {
    choice.preset == .hourly || (choice.preset == .custom && choice.frequency == .hourly)
  }

  private var showsWeekdays: Bool {
    choice.preset == .weekly || (choice.preset == .custom && choice.frequency == .weekly)
  }

  /// Monday first, as the rule counts them; the calendar's symbols start on Sunday.
  private var weekdays: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      ForEach(0..<7, id: \.self) { day in
        let isOn = choice.weekdays.contains(day)
        Button(Self.weekdayNames[(day + 1) % 7]) {
          if isOn, choice.weekdays.count > 1 {
            choice.weekdays.remove(day)
          } else {
            choice.weekdays.insert(day)
          }
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Theme.accent : nil)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("automation-weekday-\(day)")
      }
    }
  }

  private var time: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: choice.hour, minute: choice.minute, second: 0,
          of: Date(timeIntervalSince1970: 0)
        ) ?? Date(timeIntervalSince1970: 0)
      },
      set: { date in
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        choice.hour = parts.hour ?? choice.hour
        choice.minute = parts.minute ?? choice.minute
      })
  }

  private var monthDays: Binding<String> {
    Binding(
      get: { choice.monthDays.map(String.init).joined(separator: ", ") },
      set: { text in
        let days = text.split(separator: ",").compactMap {
          Int($0.trimmingCharacters(in: .whitespaces))
        }
        .filter { (1...31).contains($0) }
        if !days.isEmpty { choice.monthDays = days }
      })
  }
}
