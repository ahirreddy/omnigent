import SwiftUI

/// A workflow sheet's native chrome: on a Mac the form with Cancel and the action at its bottom
/// right; on iOS a navigation bar holding them.
struct WorkflowSheetChrome<Content: View>: View {
  let title: String
  let actionTitle: String
  let canSubmit: Bool
  var isSubmitting = false
  var blockedReason: String?
  let submit: @MainActor () -> Void
  let cancel: @MainActor () -> Void
  var actionIdentifier = "workflow-sheet-submit"
  @ViewBuilder let content: () -> Content

  var body: some View {
    #if os(macOS)
      VStack(spacing: 0) {
        // A Mac sheet draws no navigation title, so the sheet names itself.
        Text(title).font(.headline)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.Spacing.extraLarge)
          .padding(.top, Theme.Spacing.large)
          .accessibilityAddTraits(.isHeader)
        Form { content() }.formStyle(.grouped)
        Divider()
        HStack(spacing: Theme.Spacing.small) {
          if isSubmitting { ProgressView().controlSize(.small) }
          Spacer()
          Button("Cancel", role: .cancel, action: cancel)
            .keyboardShortcut(.cancelAction)
            .disabled(isSubmitting)
          Button(actionTitle, action: submit)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .help(blockedReason ?? "")
            .accessibilityIdentifier(actionIdentifier)
        }
        .controlSize(.large)
        .padding(Theme.Spacing.large)
      }
      .frame(minWidth: 460, idealWidth: 520, minHeight: 340)
      .navigationTitle(title)
    #else
      NavigationStack {
        Form { content() }
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel", role: .cancel, action: cancel).disabled(isSubmitting)
            }
            ToolbarItem(placement: .confirmationAction) {
              if isSubmitting {
                ProgressView()
              } else {
                Button(actionTitle, action: submit)
                  .disabled(!canSubmit)
                  .accessibilityIdentifier(actionIdentifier)
              }
            }
          }
      }
    #endif
  }
}

/// New workflow (web `NewWorkflowDialog`): a name and what it should do. Create draft saves a
/// workflow without steps, whose page then opens with its planning chat.
struct NewWorkflowSheet: View {
  /// The server's limits on a workflow's name and description.
  static let nameLimit = 80
  static let descriptionLimit = 2_000

  let create: (@MainActor (NewWorkflowDraft) async -> String?)?
  let nameTaken: (@MainActor (String) -> Bool)?
  let close: @MainActor () -> Void
  @State private var draft = NewWorkflowDraft()
  @State private var isSaving = false
  @State private var error: String?
  @FocusState private var nameFocused: Bool

  var body: some View {
    WorkflowSheetChrome(
      title: "New workflow", actionTitle: "Create draft", canSubmit: canCreate,
      isSubmitting: isSaving, submit: submit, cancel: close,
      actionIdentifier: "new-workflow-create"
    ) {
      Section {
        TextField("Name", text: $draft.name, prompt: Text("Name this workflow"))
          .focused($nameFocused)
          .onChange(of: draft.name) { _, name in
            if name.count > Self.nameLimit { draft.name = String(name.prefix(Self.nameLimit)) }
          }
          .accessibilityIdentifier("new-workflow-name")
      } header: {
        Text("Create a draft, then shape its plan with an agent beside the workflow.")
          .textCase(nil)
      } footer: {
        if isTaken {
          Text("You already have a workflow with this name.")
            .foregroundStyle(Theme.warning)
            .accessibilityIdentifier("new-workflow-name-taken")
        }
      }
      Section("What should it do?") {
        TextField(
          "What should it do?", text: $draft.description,
          prompt: Text(
            "Run the test suite a few times, file an issue for each flaky test, and fix the clear ones"
          ),
          axis: .vertical
        )
        .lineLimit(5...10)
        .labelsHidden()
        .onChange(of: draft.description) { _, text in
          if text.count > Self.descriptionLimit {
            draft.description = String(text.prefix(Self.descriptionLimit))
          }
        }
        .accessibilityIdentifier("new-workflow-description")
      }
      if let error {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.failure)
            .accessibilityIdentifier("new-workflow-error")
        }
      }
    }
    .interactiveDismissDisabled(isSaving)
    .onAppear { nameFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("new-workflow-sheet")
  }

  private var trimmedName: String { draft.name.trimmingCharacters(in: .whitespacesAndNewlines) }

  private var isTaken: Bool { !trimmedName.isEmpty && nameTaken?(trimmedName) == true }

  private var canCreate: Bool {
    let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmedName.isEmpty && !description.isEmpty && !isTaken && !isSaving
      && create != nil
  }

  private func submit() {
    guard canCreate, let create else { return }
    isSaving = true
    error = nil
    let request = draft
    Task {
      let failure = await create(request)
      isSaving = false
      if let failure {
        error = failure
      } else {
        close()
      }
    }
  }
}
