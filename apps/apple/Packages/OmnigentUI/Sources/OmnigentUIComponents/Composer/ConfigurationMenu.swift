import SwiftUI

/// The agent, model and effort picker in the composer toolbar, in that order. Only the selected
/// agent's models and the selected model's efforts are offered, and a default always says what
/// it resolves to. Approval mode is a separate chip: nothing here changes permissions.
struct ConfigurationMenu: View {
  let configuration: ComposerConfiguration
  let actions: ComposerActions
  var isCompact = false
  /// The agent's symbol only, for the tightest touch row; the name is in the label and menu.
  var showsModel = true
  @Environment(\.composerLayoutStyle) private var layout

  /// The card caps the model name; the touch bar lets it take the row's free width.
  private var modelWidth: CGFloat? {
    if layout == .touch { return nil }
    return isCompact ? Theme.Control.compactModelWidth : Theme.Control.modelWidth
  }

  var body: some View {
    Menu {
      if let selectAgent = actions.selectAgent, !configuration.harnessChoices.isEmpty {
        if configuration.agentGroups.isEmpty {
          Section("Agent") { agentRows(configuration.harnessChoices, selectAgent) }
        } else {
          groupedAgentRows(selectAgent)
        }
      }
      if let selectModel = actions.selectModel, !configuration.visibleModels.isEmpty {
        Section("Model") { modelPicker(selectModel) }
      }
      if let selectEffort = actions.selectEffort, !configuration.efforts.isEmpty {
        Section("Effort") { effortPicker(selectEffort) }
      }
      if let error = configuration.errorMessage {
        Section {
          Text(error)
        }
      }
    } label: {
      label
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .composerChip()
    // On touch the model name gives way to the row's other controls.
    .fixedSize(horizontal: layout != .touch, vertical: true)
    .disabled(configuration.isApplying)
    .help("Agent, model and effort: \(configuration.title) (Control-Shift-M)")
    .accessibilityLabel("Agent, model and effort, \(configuration.title)")
    .accessibilityHint("Chooses the agent, then its model and reasoning effort")
    .accessibilityIdentifier("composer-configuration")
  }

  private var label: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      HarnessGlyph(harness: configuration.harness ?? configuration.selectedAgent?.harness, size: 15)
      if !isCompact {
        Text(configuration.agentTitle)
          .font(Theme.Typography.label)
          .lineLimit(1)
        Text("\u{00B7}").foregroundStyle(.tertiary).accessibilityHidden(true)
      }
      if showsModel {
        Text(configuration.modelTitle)
          .font(Theme.Typography.label)
          .foregroundStyle(configuration.isModelInherited ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(layout == .touch ? .tail : .middle)
          .frame(maxWidth: modelWidth)
          .layoutPriority(-1)
      }
      if let effort = configuration.effortTitle, !isCompact {
        Text(effort)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      if configuration.isApplying {
        ProgressView().controlSize(.mini)
      } else if configuration.errorMessage != nil {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.warning)
          .imageScale(.small)
          .accessibilityLabel("Model list unavailable")
      }
      Image(systemName: "chevron.down")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
    .padding(.horizontal, Theme.Spacing.extraSmall)
    .contentShape(Rectangle())
    // One element: otherwise the glyph and the text each become a menu button.
    .accessibilityElement(children: .combine)
  }

  /// The web's grouping: Harnesses (the rest under "Other…"), then Agents (custom ones under
  /// "Other…"). The submenu names the selected agent when it is inside.
  @ViewBuilder
  private func groupedAgentRows(_ select: @escaping @MainActor (String) -> Void) -> some View {
    let harnesses = choices(in: .harness)
    let otherHarnesses = choices(in: .otherHarness)
    let agents = choices(in: .agent)
    let custom = choices(in: .custom)
    if !harnesses.isEmpty || !otherHarnesses.isEmpty {
      Section("Harnesses") {
        agentRows(harnesses, select)
        if !otherHarnesses.isEmpty {
          Menu(otherTitle(otherHarnesses)) { agentRows(otherHarnesses, select) }
            .accessibilityIdentifier("composer-agent-other-harnesses")
        }
      }
    }
    let createsAgents =
      actions.extras.createAgent != nil || actions.extras.importAgentBundle != nil
    if !agents.isEmpty || !custom.isEmpty || createsAgents {
      Section("Agents") {
        agentRows(agents, select)
        if !custom.isEmpty || createsAgents {
          Menu(otherTitle(custom)) {
            agentRows(custom, select)
            if createsAgents {
              if !custom.isEmpty { Divider() }
              customAgentActions
            }
          }
          .accessibilityIdentifier("composer-agent-other-agents")
        }
      }
    }
  }

  /// Create a custom agent, or import one from a bundle (a new session only).
  @ViewBuilder private var customAgentActions: some View {
    if let createAgent = actions.extras.createAgent {
      Button("Create Custom Agent\u{2026}", systemImage: "plus", action: createAgent)
        .accessibilityIdentifier("composer-agent-create")
    }
    if let importAgentBundle = actions.extras.importAgentBundle {
      Button(
        "Import Bundle\u{2026}", systemImage: "square.and.arrow.down", action: importAgentBundle
      )
      .accessibilityIdentifier("composer-agent-import")
    }
  }

  private func choices(in group: AgentPickerGroup) -> [HarnessChoice] {
    configuration.harnessChoices.filter { configuration.agentGroups[$0.id] == group }
  }

  private func otherTitle(_ choices: [HarnessChoice]) -> String {
    guard let selected = choices.first(where: { $0.id == configuration.selectedAgentId }) else {
      return "Other\u{2026}"
    }
    return "Other\u{2026} (\(selected.name))"
  }

  @ViewBuilder
  private func agentRows(
    _ rows: [HarnessChoice], _ select: @escaping @MainActor (String) -> Void
  ) -> some View {
    ForEach(rows) { choice in
      Button {
        select(choice.id)
      } label: {
        if choice.id == configuration.selectedAgentId {
          Label(choice.name, systemImage: "checkmark")
        } else if let reason = choice.unavailableReason {
          Text(choice.name)
          Text(reason)
        } else {
          Text(choice.name)
        }
      }
      .disabled(choice.unavailableReason != nil && choice.id != configuration.selectedAgentId)
      .accessibilityIdentifier("composer-agent-\(choice.id)")
    }
  }

  private func modelPicker(_ select: @escaping @MainActor (String?) -> Void) -> some View {
    Picker(
      "Model",
      selection: Binding(get: { configuration.selectedModelId }, set: { select($0) })
    ) {
      Text(configuration.defaultModelTitle).tag(String?.none)
      ForEach(configuration.visibleModels) { option in
        Text(option.label).tag(Optional(option.id))
      }
    }
    .pickerStyle(.inline)
  }

  private func effortPicker(_ select: @escaping @MainActor (String?) -> Void) -> some View {
    Picker(
      "Effort",
      selection: Binding<String?>(get: { configuration.selectedEffort }, set: { select($0) })
    ) {
      Text(configuration.defaultEffortTitle).tag(String?.none)
      ForEach(configuration.efforts, id: \.self) { (effort: String) in
        Text(ComposerConfiguration.effortLabel(effort)).tag(String?.some(effort))
      }
    }
    .pickerStyle(.inline)
  }
}
