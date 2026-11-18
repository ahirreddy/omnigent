import SwiftUI

/// The schedule's frequency and time, or a rule kept as it is until a new one is chosen.
struct AutomationScheduleRows: View {
  @Binding var draft: AutomationDraftState
  let context: AutomationEditorContext
  /// The frequencies as a list, as the web's schedule menu.
  var listsFrequencies = false

  var body: some View {
    if let kept = draft.keptRule, draft.schedule == nil {
      LabeledContent("Repeats", value: kept)
      Text(
        "This schedule can\u{2019}t be edited in this form yet. Choose a frequency to replace it."
      )
      .font(.callout).foregroundStyle(Theme.failure)
      .fixedSize(horizontal: false, vertical: true)
      Button("Choose a new schedule") { draft.schedule = ScheduleChoice() }
        .accessibilityIdentifier("automation-schedule-replace")
    } else {
      ScheduleFields(
        choice: Binding(
          get: { draft.schedule ?? ScheduleChoice() }, set: { draft.schedule = $0 }),
        anchoredScheduling: context.anchoredScheduling, minuteRange: context.minuteRange,
        offersMinutes: context.offersMinutes, showsEnding: false,
        listsFrequencies: listsFrequencies)
    }
  }
}

#if os(macOS)
  /// The schedule button's menu, as the web's: "Schedule", the frequencies, then the time.
  struct AutomationScheduleMenu: View {
    @Binding var draft: AutomationDraftState
    let context: AutomationEditorContext

    var body: some View {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text("Schedule").font(Theme.Typography.section).foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        Form {
          AutomationScheduleRows(draft: $draft, context: context, listsFrequencies: true)
        }
        .formStyle(.columns)
        if let problem = context.scheduleProblem {
          Text(problem).font(.callout).foregroundStyle(Theme.failure)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(Theme.Spacing.large)
      .frame(width: 340, alignment: .leading)
      .accessibilityIdentifier("automation-schedule-menu")
    }
  }

  /// The Mac layout, as the web's dialog: the name as its title; rows of pop-ups without
  /// labels, each named by its tooltip; the instructions in a large field; Advanced settings as
  /// muted labels with their controls; Cancel and Create at the bottom.
  struct AutomationEditorDialog: View {
    let editor: AutomationEditorSheet
    @Binding var showsAdvanced: Bool
    @Binding var showsSchedule: Bool

    private var context: AutomationEditorContext { editor.context }

    var body: some View {
      VStack(spacing: 0) {
        editor.nameField
          .padding(.horizontal, Theme.Spacing.extraLarge)
          .padding(.top, Theme.Spacing.extraLarge)
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            editor.startsFrom
            if editor.showsTypeRow { typeRow }
            editor.triggerScheduleReplacement
            if editor.showsTriggerForm {
              editor.triggerOrPrompt(builder: true)
            } else {
              promptEditor
            }
            runRow
            advanced
            if let error = context.error {
              AutomationErrorBanner(message: error)
                .accessibilityIdentifier("automation-error")
            }
          }
          .padding(.horizontal, Theme.Spacing.extraLarge)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        footer
      }
      .frame(minWidth: 560, idealWidth: 720, minHeight: 520, idealHeight: 720)
      .navigationTitle(editor.title)
    }

    /// Schedule or an integration, and for a schedule its frequency and time.
    private var typeRow: some View {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack(spacing: Theme.Spacing.medium) {
          editor.triggerTypePicker.labelsHidden().frame(maxWidth: .infinity)
          if !editor.isTrigger { scheduleControl(fills: true) }
        }
        if editor.triggersUnavailable {
          Text("Integration triggers aren\u{2019}t available on this server.")
            .font(.callout).foregroundStyle(.secondary)
        }
        if !editor.isTrigger { editor.scheduleProblem }
      }
    }

    /// The schedule's summary, which opens its menu.
    private func scheduleControl(fills: Bool) -> some View {
      Button {
        showsSchedule.toggle()
      } label: {
        HStack(spacing: Theme.Spacing.small) {
          Image(systemName: "clock").foregroundStyle(.secondary)
          Text(editor.scheduleSummary).lineLimit(1)
          if fills { Spacer(minLength: 0) }
          Image(systemName: "chevron.up.chevron.down").font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: fills ? .infinity : nil)
      }
      .buttonStyle(.bordered)
      .help("Schedule")
      .accessibilityLabel("Schedule")
      .accessibilityValue(editor.scheduleSummary)
      .accessibilityIdentifier("automation-schedule")
      .popover(isPresented: $showsSchedule, arrowEdge: .bottom) {
        AutomationScheduleMenu(draft: editor.$draft, context: context)
      }
    }

    /// The instructions, in the web's large rounded field.
    private var promptEditor: some View {
      TextField(
        editor.promptLabel, text: editor.$draft.prompt, prompt: Text(editor.promptPlaceholder),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .lineLimit(8...)
      .padding(Theme.Spacing.medium)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.medium + 4, style: .continuous)
          .strokeBorder(ThemeColor.border)
      )
      .accessibilityIdentifier("automation-prompt")
    }

    /// Run on, Agent and Permissions side by side, as the web's.
    private var runRow: some View {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack(spacing: Theme.Spacing.medium) {
          editor.hostPicker.labelsHidden().frame(maxWidth: .infinity)
          editor.agentPicker.labelsHidden().frame(maxWidth: .infinity)
          if editor.offersPermissions {
            editor.permissionPicker.labelsHidden().frame(maxWidth: .infinity)
          }
        }
        editor.runNotes
      }
    }

    /// "Advanced settings (optional)", folded until opened or until one needs attention.
    private var advanced: some View {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        Button {
          withAnimation(Theme.Motion.disclosure) { showsAdvanced.toggle() }
        } label: {
          HStack(spacing: Theme.Spacing.small) {
            Text("Advanced settings").fontWeight(.medium)
            Text("(optional)").foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(showsAdvanced ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("automation-advanced")
        if showsAdvanced {
          let rows = editor.advancedRows(scheduleButton: AnyView(scheduleControl(fills: false)))
          VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
              if index > 0 { Divider() }
              HStack(spacing: Theme.Spacing.large) {
                Text(row.label).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                row.control
              }
              .frame(minHeight: 36)
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("automation-advanced-\(row.id)")
            }
          }
          VStack(alignment: .leading, spacing: Theme.Spacing.small) { editor.advancedNotes }
        }
      }
    }

    private var footer: some View {
      HStack(spacing: Theme.Spacing.small) {
        Spacer()
        Button("Cancel", role: .cancel, action: editor.cancel).keyboardShortcut(.cancelAction)
        Button(editor.saveTitle, action: editor.save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(!editor.canSave)
          .accessibilityIdentifier("automation-save")
      }
      .padding(.horizontal, Theme.Spacing.extraLarge)
      .padding(.vertical, Theme.Spacing.large)
    }
  }
#endif
