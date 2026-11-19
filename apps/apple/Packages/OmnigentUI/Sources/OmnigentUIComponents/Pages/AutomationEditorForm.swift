#if !os(macOS)
  import SwiftUI

  /// The iOS layout: the web dialog's order as a form, with Cancel and Create in the bar.
  struct AutomationEditorForm: View {
    let editor: AutomationEditorSheet
    @Binding var showsAdvanced: Bool

    private var context: AutomationEditorContext { editor.context }

    var body: some View {
      NavigationStack {
        Form {
          Section { editor.nameField }
          if editor.draft.sourceSessionID != nil { Section { editor.startsFrom } }
          if editor.showsTypeRow {
            Section {
              editor.triggerTypePicker
            } footer: {
              if editor.triggersUnavailable {
                Text("Integration triggers aren\u{2019}t available on this server.")
              }
            }
          }
          // A phone has no room for the web's schedule menu: its rows are a section.
          if !editor.isTrigger {
            Section("Schedule") {
              editor.scheduleRows(listsFrequencies: false)
              editor.scheduleProblem
            }
          }
          if editor.isTrigger, context.triggerScheduleUnsupported {
            Section { editor.triggerScheduleReplacement }
          }
          if editor.showsTriggerForm {
            editor.triggerOrPrompt(builder: false)
          } else {
            Section(editor.promptLabel) {
              TextField(
                editor.promptLabel, text: editor.$draft.prompt,
                prompt: Text(editor.promptPlaceholder), axis: .vertical
              )
              .lineLimit(5...12)
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
          Section {
            DisclosureGroup(isExpanded: $showsAdvanced) {
              ForEach(editor.advancedRows()) { row in
                LabeledContent(row.label) { row.control }
              }
              editor.advancedNotes
            } label: {
              HStack(spacing: Theme.Spacing.extraSmall) {
                Text("Advanced settings")
                Text("(optional)").foregroundStyle(.secondary)
              }
            }
            .accessibilityIdentifier("automation-advanced")
          }
          if let error = context.error {
            Section {
              Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.failure)
                .accessibilityIdentifier("automation-error")
            }
          }
        }
        .formStyle(.grouped)
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
    }
  }
#endif
