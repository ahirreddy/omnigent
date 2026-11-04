public import SwiftUI

/// Creates or edits an automation: name, prompt, agent, schedule and session mode.
public struct AutomationEditorSheet: View {
  @Binding private var draft: AutomationDraftState
  private let context: AutomationEditorContext
  private let save: @MainActor () -> Void
  private let cancel: @MainActor () -> Void

  /// Creates the sheet.
  /// - Parameters:
  ///   - draft: The fields.
  ///   - context: Agents, server support and the save state.
  ///   - save: Save the fields.
  ///   - cancel: Close without saving.
  public init(
    draft: Binding<AutomationDraftState>, context: AutomationEditorContext,
    save: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void
  ) {
    _draft = draft
    self.context = context
    self.save = save
    self.cancel = cancel
  }

  /// The form.
  public var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Name", text: $draft.name)
            .accessibilityIdentifier("automation-name")
          TextField("Prompt", text: $draft.prompt, axis: .vertical)
            .lineLimit(4...10)
            .accessibilityIdentifier("automation-prompt")
          Picker("Agent", selection: $draft.agentID) {
            if draft.agentID.isEmpty { Text("Choose an agent").tag("") }
            ForEach(context.agents) { Text($0.name).tag($0.id) }
          }
          .accessibilityIdentifier("automation-agent")
        }
        Section("Schedule") { schedule }
        if context.supportsSessionModes {
          Section {
            Picker("Each run", selection: $draft.continuesSession) {
              Text("Starts a new session").tag(false)
              Text("Continues the same session").tag(true)
            }
            .accessibilityIdentifier("automation-session-mode")
          }
        }
        if let error = context.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
              .accessibilityIdentifier("automation-error")
          }
        }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
        Button(context.isEditing ? "Save" : "Create", action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!draft.canSave || context.isSaving)
          .accessibilityIdentifier("automation-save")
      }
      .padding(Theme.Spacing.large)
    }
    .frame(minWidth: 480, idealWidth: 540, minHeight: 520)
    .navigationTitle(context.isEditing ? "Edit automation" : "New automation")
  }

  @ViewBuilder private var schedule: some View {
    if let kept = draft.keptRule, draft.schedule == nil {
      LabeledContent("Repeats", value: kept)
      Button("Choose a new schedule") { draft.schedule = ScheduleChoice() }
    } else {
      ScheduleFields(choice: scheduleBinding)
      Text(context.describe(scheduleBinding.wrappedValue))
        .font(.callout).foregroundStyle(.secondary)
        .accessibilityIdentifier("automation-schedule-summary")
    }
  }

  private var scheduleBinding: Binding<ScheduleChoice> {
    Binding(
      get: { draft.schedule ?? ScheduleChoice() },
      set: { draft.schedule = $0 })
  }
}

/// The schedule picker: a preset, the time, and the custom unit, interval and days.
struct ScheduleFields: View {
  @Binding var choice: ScheduleChoice

  private static let weekdayNames = Calendar.current.shortWeekdaySymbols

  var body: some View {
    Picker("Repeats", selection: $choice.preset) {
      ForEach(ScheduleChoice.Preset.allCases) { Text($0.title).tag($0) }
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
