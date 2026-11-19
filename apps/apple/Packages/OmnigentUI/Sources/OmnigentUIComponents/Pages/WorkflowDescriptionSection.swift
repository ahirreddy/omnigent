import SwiftUI

/// A workflow's description (web `WorkflowDescription`): three lines with a chevron for the rest,
/// and a pencil that edits it in place. While the planning chat proposes a different one, both
/// show to choose from: Save plan keeps the current one unless the proposal's is chosen.
struct WorkflowDescriptionSection: View {
  let state: WorkflowDetailState
  let actions: WorkflowDetailActions
  @State private var expanded = false
  /// The text being edited, and what the editor opened with; `nil` while it shows.
  @State private var draft: String?
  @State private var draftStart = ""
  @State private var isSaving = false
  @State private var error: String?
  @State private var confirmingDiscard = false
  @FocusState private var editorFocused: Bool

  /// More than this many characters, or more than three lines, may be cut off.
  private static let foldedLength = 240

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      heading
      if draft != nil {
        editor
      } else if let proposed = state.proposedDescription {
        choices(proposed)
      } else {
        Text(state.description)
          .foregroundStyle(.primary.opacity(0.9))
          .lineLimit(expanded ? nil : 3)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("workflow-detail-description")
      }
    }
    .confirmationDialog("Discard your description changes?", isPresented: $confirmingDiscard) {
      Button("Discard Changes", role: .destructive) { close() }
    }
  }

  private var mayFold: Bool {
    state.description.count > Self.foldedLength
      || state.description.split(separator: "\n", omittingEmptySubsequences: false).count > 3
  }

  private var heading: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      if draft == nil, state.proposedDescription == nil, mayFold {
        Button {
          withAnimation(Theme.Motion.disclosure) { expanded.toggle() }
        } label: {
          HStack(spacing: Theme.Spacing.extraSmall) {
            Image(systemName: "chevron.down")
              .font(.caption.weight(.semibold))
              .rotationEffect(.degrees(expanded ? 0 : -90))
            Text("Description")
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("workflow-detail-description-toggle")
      } else {
        Text("Description")
      }
      if draft == nil, !state.isReadOnly, actions.saveDescription != nil {
        Button("Edit description", systemImage: "pencil", action: edit)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .imageScale(.small)
          .help("Edit description")
          .accessibilityIdentifier("workflow-detail-edit-description")
      }
    }
    .font(AutomationStyle.sectionTitle)
    .foregroundStyle(.secondary)
    .accessibilityAddTraits(.isHeader)
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      TextField(
        "Workflow description", text: Binding(get: { draft ?? "" }, set: { draft = $0 }),
        axis: .vertical
      )
      .lineLimit(4...12)
      .textFieldStyle(.roundedBorder)
      .focused($editorFocused)
      .disabled(isSaving)
      .onChange(of: draft) { _, text in
        if let text, text.count > NewWorkflowSheet.descriptionLimit {
          draft = String(text.prefix(NewWorkflowSheet.descriptionLimit))
        }
      }
      .onKeyPress(.escape) {
        cancel()
        return .handled
      }
      .accessibilityIdentifier("workflow-description-editor")
      if let error {
        Text("Couldn\u{2019}t save the description. \(error)").font(.callout)
          .foregroundStyle(Theme.failure)
          .accessibilityIdentifier("workflow-description-error")
      }
      HStack(spacing: Theme.Spacing.small) {
        Button("Save", action: save)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.return, modifiers: .command)
          .disabled(
            isSaving || (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
          .accessibilityIdentifier("workflow-description-save")
        Button("Cancel", action: cancel)
          .disabled(isSaving)
          .accessibilityIdentifier("workflow-description-cancel")
        if isSaving { ProgressView().controlSize(.small) }
      }
      .controlSize(.small)
    }
  }

  /// Keep current or Use proposed, as radio cards.
  private func choices(_ proposed: String) -> some View {
    let layout =
      layoutCompact
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.medium))
      : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Spacing.medium))
    return layout {
      choice(
        "Keep current", text: state.description, chosen: !state.usesProposedDescription,
        identifier: "workflow-detail-keep-description"
      ) { actions.chooseProposedDescription?(false) }
      choice(
        "Use proposed", text: proposed, chosen: state.usesProposedDescription,
        identifier: "workflow-detail-use-proposed-description"
      ) { actions.chooseProposedDescription?(true) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Description")
  }

  @Environment(\.layoutWidth) private var layoutWidth
  private var layoutCompact: Bool { layoutWidth == .compact }

  private func choice(
    _ label: String, text: String, chosen: Bool, identifier: String,
    select: @escaping @MainActor () -> Void
  ) -> some View {
    Button(action: select) {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        HStack {
          Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .accessibilityHidden(true)
        }
        Text(text).font(.callout).foregroundStyle(.primary.opacity(0.9))
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(Theme.Spacing.medium)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .automationCard(isHighlighted: chosen)
      .overlay {
        if chosen {
          RoundedRectangle(cornerRadius: AutomationStyle.cardRadius, style: .continuous)
            .strokeBorder(.tint, lineWidth: 1.5)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(chosen ? [.isSelected] : [])
    .accessibilityIdentifier(identifier)
  }

  /// The editor starts from the chosen wording.
  private func edit() {
    let start =
      state.usesProposedDescription
      ? (state.proposedDescription ?? state.description)
      : state.description
    draftStart = start
    draft = start
    error = nil
    editorFocused = true
  }

  private func cancel() {
    let changed =
      (draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      != draftStart.trimmingCharacters(in: .whitespacesAndNewlines)
    if changed {
      confirmingDiscard = true
    } else {
      close()
    }
  }

  private func close() {
    draft = nil
    error = nil
  }

  private func save() {
    guard let text = draft, let saveDescription = actions.saveDescription else { return }
    isSaving = true
    error = nil
    Task {
      let failure = await saveDescription(text)
      isSaving = false
      if let failure {
        error = failure
        editorFocused = true
      } else {
        close()
      }
    }
  }
}

/// An automation that runs the workflow: its name opening its page, its Paused pill, and its
/// schedule with when it next and last ran.
struct WorkflowAutomationRow: View {
  let row: WorkflowAutomationRowState
  let open: @MainActor () -> Void
  @State private var isHovered = false

  var body: some View {
    Button(action: open) {
      HStack(alignment: .top, spacing: Theme.Spacing.medium) {
        Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 20)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          HStack(spacing: Theme.Spacing.small) {
            Text(row.name).lineLimit(1)
            if row.isPaused {
              Text("Paused").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            }
          }
          HStack(spacing: 0) {
            Text(row.schedule)
            if let last = row.lastRun {
              Text(" \u{00B7} ")
              Text(last).foregroundStyle(
                row.lastRunFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
          }
          .font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.small)
      .background(
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
          .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .accessibilityIdentifier("workflow-automation-\(row.id)")
  }
}
