import SwiftUI

/// The editor as a native form, in the web dialog's order: the name; for a new automation its
/// trigger type with the schedule's frequency and time; the instructions or a trigger's form;
/// where it runs with its agent and permissions; then Advanced settings (optional), folded. A Mac
/// shows it in a sheet with Cancel and Create at the bottom right; iOS puts them in the bar.
struct AutomationEditorForm: View {
  let editor: AutomationEditorSheet
  @Binding var showsAdvanced: Bool

  private var context: AutomationEditorContext { editor.context }

  var body: some View {
    #if os(macOS)
      VStack(spacing: 0) {
        form
        Divider()
        HStack(spacing: Theme.Spacing.small) {
          Spacer()
          Button("Cancel", role: .cancel, action: editor.cancel)
            .keyboardShortcut(.cancelAction)
          Button(editor.saveTitle, action: editor.save)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!editor.canSave)
            .accessibilityIdentifier("automation-save")
        }
        .controlSize(.large)
        .padding(Theme.Spacing.large)
      }
      .frame(minWidth: 520, idealWidth: 600, minHeight: 560, idealHeight: 720)
      .navigationTitle(editor.title)
    #else
      NavigationStack {
        form
          .navigationTitle(editor.title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", role: .cancel, action: editor.cancel)
            }
            ToolbarItem(placement: .confirmationAction) {
              Button(editor.saveTitle, action: editor.save)
                .disabled(!editor.canSave)
                .accessibilityIdentifier("automation-save")
            }
          }
      }
    #endif
  }

  private var form: some View {
    Form {
      Section { editor.nameField }
      if editor.draft.sourceSessionID != nil { Section { editor.startsFrom } }
      if editor.showsTypeRow { typeAndSchedule }
      if editor.isTrigger, context.triggerScheduleUnsupported {
        Section { editor.triggerScheduleReplacement }
      }
      if editor.showsTriggerForm {
        editor.triggerOrPrompt
      } else {
        Section(editor.promptLabel) {
          TextField(
            editor.promptLabel, text: editor.$draft.prompt,
            prompt: Text(editor.promptPlaceholder), axis: .vertical
          )
          .lineLimit(6...12)
          .labelsHidden()
          .accessibilityIdentifier("automation-prompt")
        }
      }
      Section {
        editor.hostPicker
        editor.agentPicker
        if editor.offersPermissions { editor.permissionPicker }
      } footer: {
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) { editor.runNotes }
      }
      advanced
      if let error = context.error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .accessibilityIdentifier("automation-error")
        }
      }
    }
    .formStyle(.grouped)
  }

  /// Schedule or an integration, and for a schedule its frequency and time, with what it reads
  /// as below.
  private var typeAndSchedule: some View {
    Section {
      editor.triggerTypePicker
      if !editor.isTrigger { editor.scheduleRows }
    } footer: {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        if editor.triggersUnavailable {
          Text("Integration triggers aren\u{2019}t available on this server.")
        }
        if !editor.isTrigger {
          if context.scheduleProblem == nil {
            Text(editor.scheduleSummary)
              .accessibilityIdentifier("automation-schedule-summary")
          }
          editor.scheduleProblem
        }
      }
    }
  }

  /// "Advanced settings (optional)", folded until opened or until one needs attention.
  private var advanced: some View {
    Section {
      #if os(macOS)
        Button {
          withAnimation(Theme.Motion.disclosure) { showsAdvanced.toggle() }
        } label: {
          HStack(spacing: Theme.Spacing.small) {
            Text("Advanced settings")
            Text("(optional)").foregroundStyle(.secondary)
            Spacer(minLength: 0)
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
        if showsAdvanced { advancedContent }
      #else
        DisclosureGroup(isExpanded: $showsAdvanced) {
          advancedContent
        } label: {
          HStack(spacing: Theme.Spacing.extraSmall) {
            Text("Advanced settings")
            Text("(optional)").foregroundStyle(.secondary)
          }
        }
        .accessibilityIdentifier("automation-advanced")
      #endif
    }
  }

  @ViewBuilder private var advancedContent: some View {
    ForEach(editor.advancedRows()) { row in row.formRow }
    editor.advancedNotes
  }
}
