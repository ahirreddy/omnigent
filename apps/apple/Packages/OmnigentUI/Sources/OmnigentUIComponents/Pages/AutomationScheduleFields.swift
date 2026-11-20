import SwiftUI

/// The schedule picker, as the web's `ScheduleFields`: the Visual | RRULE switch, then the
/// frequency, the custom unit, interval and days, and the time, or the rule's text. The ending is
/// ``ScheduleEndFields``, which the editor shows on its own row, as the web's Ends. Interval,
/// custom and RRULE schedules and run-count endings need a server with anchored scheduling.
struct ScheduleFields: View {
  @Binding var choice: ScheduleChoice
  var anchoredScheduling = true
  /// The minutes an Interval schedule may repeat every, from the server and where runs go.
  var minuteRange: ClosedRange<Int> = 10...21_960
  /// Custom schedules offer minutes, as where runs go allows schedules under an hour.
  var offersMinutes = true
  /// Includes the ending; the editor shows it on a row of its own.
  var showsEnding = true
  /// Offers the RRULE editor; `nil` shows only the visual controls.
  var rules: ScheduleRuleConversion?

  var body: some View {
    if let rules {
      ScheduleEditorPicker(choice: $choice, rules: rules, anchoredScheduling: anchoredScheduling)
    }
    if choice.isRule {
      ScheduleRuleFields(choice: $choice, rules: rules, anchoredScheduling: anchoredScheduling)
    } else {
      visualFields
    }
    if showsEnding {
      ScheduleEndFields(choice: $choice, anchoredScheduling: anchoredScheduling)
    }
  }

  /// The frequency, its unit, interval and days, and the time.
  @ViewBuilder private var visualFields: some View {
    frequencyPicker
    if choice.preset == .interval {
      Stepper(value: $choice.interval, in: minuteRange) {
        Text("Every \(choice.interval) minutes")
      }
      .accessibilityIdentifier("automation-schedule-interval")
    }
    if choice.preset == .custom {
      Picker("Repeats", selection: frequencySelection) {
        ForEach(frequencies) { Text($0.title).tag($0) }
      }
      .disabled(!anchoredScheduling)
      .accessibilityIdentifier("automation-schedule-custom-frequency")
      Stepper(value: $choice.interval, in: intervalRange) {
        Text("Every \(everyText)")
      }
      .disabled(!anchoredScheduling)
      .accessibilityIdentifier("automation-schedule-custom-interval")
    }
    if choice.preset == .custom, choice.frequency == .yearly {
      Picker("Month", selection: $choice.month) {
        ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
      }
    }
    if showsWeekdays {
      LabeledContent("On") { weekdays }
    }
    if choice.preset == .custom, [.monthly, .yearly].contains(choice.frequency) {
      TextField("On", text: monthDays, prompt: Text("1, 15"))
        .accessibilityIdentifier("automation-schedule-month-days")
    }
    // A minute rule has no time of day.
    if !isMinutely {
      if isHourly {
        Picker("At minute", selection: $choice.minute) {
          ForEach(0..<60, id: \.self) { Text($0 < 10 ? ":0\($0)" : ":\($0)").tag($0) }
        }
      } else {
        DatePicker(
          choice.preset == .custom ? "Start time" : "Time", selection: time,
          displayedComponents: .hourAndMinute
        )
        .accessibilityIdentifier("automation-schedule-time")
      }
    }
  }

  /// The frequency, as a pop-up menu.
  private var frequencyPicker: some View {
    Picker("Frequency", selection: presetSelection) {
      ForEach(presets) { preset in
        Text(preset.title).tag(preset)
          .selectionDisabled(
            [.custom, .interval].contains(preset) && !anchoredScheduling
              && choice.preset != preset)
      }
    }
    .accessibilityIdentifier("automation-schedule-preset")
  }

  /// "1 week", "3 days".
  private var everyText: String {
    let unit =
      switch choice.frequency {
      case .minutely: "minute"
      case .hourly: "hour"
      case .daily: "day"
      case .weekly: "week"
      case .monthly: "month"
      case .yearly: "year"
      case .rule: "time"
      }
    return "\(choice.interval) \(unit)\(choice.interval == 1 ? "" : "s")"
  }

  /// Interval and Custom show only on servers that run them, or while chosen.
  private var presets: [ScheduleChoice.Preset] {
    ScheduleChoice.Preset.allCases.filter {
      anchoredScheduling || ![.interval, .custom].contains($0) || $0 == choice.preset
    }
  }

  private var frequencies: [ScheduleChoice.Frequency] {
    ScheduleChoice.Frequency.allCases.filter {
      $0 != .rule && ($0 != .minutely || offersMinutes || choice.frequency == .minutely)
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

  private var isHourly: Bool {
    choice.preset == .hourly || (choice.preset == .custom && choice.frequency == .hourly)
  }

  private var showsWeekdays: Bool {
    choice.preset == .weekly || (choice.preset == .custom && choice.frequency == .weekly)
  }

  /// Monday first, as the rule counts them, in round buttons with the day's initial, as the
  /// web's; the calendar's symbols start on Sunday.
  private var weekdays: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      ForEach(0..<7, id: \.self) { day in
        let isOn = choice.weekdays.contains(day)
        let name = Calendar.current.weekdaySymbols[(day + 1) % 7]
        Button {
          if isOn, choice.weekdays.count > 1 {
            choice.weekdays.remove(day)
          } else {
            choice.weekdays.insert(day)
          }
        } label: {
          Text(String(name.prefix(1)))
            .font(.callout.weight(.medium))
            .frame(width: 26, height: 26)
            .foregroundStyle(isOn ? AnyShapeStyle(ThemeColor.onAccent) : AnyShapeStyle(.primary))
            .background(
              Circle().fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear))
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
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

/// The schedule's frequency and time, or a rule kept as it is until a new one is chosen.
struct AutomationScheduleRows: View {
  @Binding var draft: AutomationDraftState
  let context: AutomationEditorContext

  var body: some View {
    if let kept = draft.keptRule, draft.schedule == nil {
      LabeledContent("Repeats", value: kept)
      Text(
        "This schedule can\u{2019}t be edited in this form yet. Choose a frequency to replace it."
      )
      .font(.callout).foregroundStyle(.red)
      .fixedSize(horizontal: false, vertical: true)
      Button("Choose a new schedule") { draft.schedule = ScheduleChoice() }
        .accessibilityIdentifier("automation-schedule-replace")
    } else {
      ScheduleFields(
        choice: Binding(
          get: { draft.schedule ?? ScheduleChoice() }, set: { draft.schedule = $0 }),
        anchoredScheduling: context.anchoredScheduling, minuteRange: context.minuteRange,
        offersMinutes: context.offersMinutes, showsEnding: false, rules: context.ruleConversion)
      AutomationTimeZonePicker(timezone: $draft.timezone)
    }
  }
}

/// When a schedule stops, as the web's Ends: never, on a date, or after a number of runs.
struct ScheduleEndFields: View {
  @Binding var choice: ScheduleChoice
  var anchoredScheduling = true
  /// On one line with its picker, as the editor's Ends row, rather than as form rows.
  var inline = false

  var body: some View {
    if inline {
      HStack(spacing: Theme.Spacing.small) {
        details
        kindPicker.labelsHidden().fixedSize()
      }
    } else {
      kindPicker
      details
    }
  }

  /// The web's "Ends" summary: "Never", "On date" or "After N occurrences".
  static func summary(_ end: ScheduleChoice.End) -> String {
    switch end {
    case .never: "Never"
    case .until: "On date"
    case .count(let count): "After \(count) occurrences"
    }
  }

  private var kindPicker: some View {
    Picker("Ends", selection: endKind) {
      Text("Never").tag(EndKind.never)
      Text("On date").tag(EndKind.until)
      if anchoredScheduling || endKind.wrappedValue == .count {
        Text("After").tag(EndKind.count)
          .selectionDisabled(!anchoredScheduling)
      }
    }
    .accessibilityIdentifier("automation-schedule-end")
  }

  @ViewBuilder private var details: some View {
    switch choice.end {
    case .never:
      EmptyView()
    case .until(let date):
      DatePicker(
        "End date",
        selection: Binding(get: { date }, set: { choice.end = .until(endOfDay($0)) }),
        displayedComponents: .date
      )
      .labelsHidden(inline)
      .accessibilityIdentifier("automation-schedule-until")
    case .count(let count):
      Stepper(
        value: Binding(get: { count }, set: { choice.end = .count($0) }), in: 2...9_999
      ) {
        Text("\(count) occurrences").foregroundStyle(inline ? .secondary : .primary)
      }
      .disabled(!anchoredScheduling)
      .fixedSize()
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
}

extension View {
  /// Hides the labels when `hidden`.
  @ViewBuilder fileprivate func labelsHidden(_ hidden: Bool) -> some View {
    if hidden { labelsHidden() } else { self }
  }
}
