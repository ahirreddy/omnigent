import SwiftUI

/// The schedule picker: a preset, the time, the custom unit, interval and days, and the ending.
/// Interval and custom schedules and run-count endings need a server with anchored scheduling.
struct ScheduleFields: View {
  @Binding var choice: ScheduleChoice
  var anchoredScheduling = true
  /// The minutes an Interval schedule may repeat every, from the server and where runs go.
  var minuteRange: ClosedRange<Int> = 10...21_960
  /// Custom schedules offer minutes, as where runs go allows schedules under an hour.
  var offersMinutes = true

  private static let weekdayNames = Calendar.current.shortWeekdaySymbols

  var body: some View {
    Picker("Repeats", selection: presetSelection) {
      ForEach(presets) { preset in
        Text(preset.title).tag(preset)
          .selectionDisabled(
            [.custom, .interval].contains(preset) && !anchoredScheduling
              && choice.preset != preset)
      }
    }
    .accessibilityIdentifier("automation-schedule-preset")
    if choice.preset == .interval {
      Stepper(value: $choice.interval, in: minuteRange) {
        Text("Every \(choice.interval) minutes")
      }
      .accessibilityIdentifier("automation-schedule-interval")
    }
    if choice.preset == .custom {
      Stepper(value: $choice.interval, in: intervalRange) {
        Picker("Every \(choice.interval)", selection: frequencySelection) {
          ForEach(frequencies) { Text($0.title).tag($0) }
        }
      }
      .accessibilityIdentifier("automation-schedule-custom-interval")
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
    // A minute rule has no time of day.
    if !isMinutely {
      if isHourly {
        Picker("At minute", selection: $choice.minute) {
          ForEach(0..<60, id: \.self) { Text($0 < 10 ? ":0\($0)" : ":\($0)").tag($0) }
        }
      } else {
        DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
          .accessibilityIdentifier("automation-schedule-time")
      }
    }
    ending
  }

  /// Interval and Custom show only on servers that run them, or while chosen.
  private var presets: [ScheduleChoice.Preset] {
    ScheduleChoice.Preset.allCases.filter {
      anchoredScheduling || ![.interval, .custom].contains($0) || $0 == choice.preset
    }
  }

  private var frequencies: [ScheduleChoice.Frequency] {
    ScheduleChoice.Frequency.allCases.filter {
      $0 != .minutely || offersMinutes || choice.frequency == .minutely
    }
  }

  private var intervalRange: ClosedRange<Int> {
    choice.frequency == .minutely ? minuteRange : 1...366
  }

  /// As the web's `changePreset`: Interval starts at the shortest allowed interval, and Custom
  /// carries over the preset's unit and days.
  private var presetSelection: Binding<ScheduleChoice.Preset> {
    Binding(
      get: { choice.preset },
      set: { preset in
        let previous = choice
        choice.preset = preset
        switch preset {
        case .interval:
          if previous.frequency != .minutely { choice.interval = minuteRange.lowerBound }
          choice.frequency = .minutely
        case .custom:
          switch previous.preset {
          case .weekdays:
            choice.frequency = .weekly
            choice.weekdays = [0, 1, 2, 3, 4]
          case .hourly: choice.frequency = .hourly
          case .daily: choice.frequency = .daily
          case .weekly: choice.frequency = .weekly
          case .interval, .custom: break
          }
          if previous.preset != .custom, previous.preset != .interval { choice.interval = 1 }
        case .hourly, .daily, .weekdays, .weekly:
          break
        }
      })
  }

  /// Minutes start at the shortest allowed interval; leaving them starts over at 1.
  private var frequencySelection: Binding<ScheduleChoice.Frequency> {
    Binding(
      get: { choice.frequency },
      set: { frequency in
        if frequency == .minutely {
          choice.interval = max(minuteRange.lowerBound, choice.interval)
        } else if choice.frequency == .minutely {
          choice.interval = 1
        }
        choice.frequency = frequency
      })
  }

  private var isMinutely: Bool {
    choice.preset == .interval || (choice.preset == .custom && choice.frequency == .minutely)
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
