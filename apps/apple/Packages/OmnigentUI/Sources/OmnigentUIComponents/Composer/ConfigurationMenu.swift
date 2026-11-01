import SwiftUI

/// The harness, model and reasoning picker shown in the composer toolbar.
struct ConfigurationMenu: View {
  let configuration: ComposerConfiguration
  let actions: ComposerActions

  private var visibleModels: [ModelOption] { configuration.modelOptions.filter { !$0.hidden } }

  private var modelLabel: String {
    configuration.selectedModel?.label
      ?? configuration.modelOptions.first(where: \.isDefault).map { "Default (\($0.label))" }
      ?? "Default model"
  }

  private var title: String {
    if let effort = configuration.selectedEffort {
      return "\(modelLabel) \u{00B7} \(effort.capitalized)"
    }
    return modelLabel
  }

  var body: some View {
    Menu {
      if let selectModel = actions.selectModel {
        Section("Model") {
          Picker(
            "Model",
            selection: Binding(
              get: { configuration.selectedModelId },
              set: { selectModel($0) })
          ) {
            Text("Harness Default").tag(String?.none)
            ForEach(visibleModels) { option in
              Text(option.label).tag(Optional(option.id))
            }
          }
          .pickerStyle(.inline)
        }
      }
      if let selectEffort = actions.selectEffort, !configuration.efforts.isEmpty {
        Section("Reasoning") {
          Picker(
            "Reasoning",
            selection: Binding(
              get: { configuration.selectedEffort },
              set: { selectEffort($0) })
          ) {
            Text("Model Default").tag(String?.none)
            ForEach(configuration.efforts, id: \.self) { effort in
              Text(effort.capitalized).tag(Optional(effort))
            }
          }
          .pickerStyle(.inline)
        }
      }
      if let selectAgent = actions.selectAgent, !configuration.harnessChoices.isEmpty {
        Section("Harness") {
          ForEach(configuration.harnessChoices) { choice in
            Button {
              selectAgent(choice.id)
            } label: {
              if choice.id == configuration.selectedAgentId {
                Label(choice.name, systemImage: "checkmark")
              } else {
                Text(choice.name)
              }
            }
          }
        }
      }
      if let error = configuration.errorMessage {
        Section {
          Text(error)
        }
      }
    } label: {
      HStack(spacing: 6) {
        HarnessGlyph(harness: configuration.harness, size: 16)
        Text(title)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        if configuration.isApplying {
          ProgressView().controlSize(.mini)
        } else if configuration.errorMessage != nil {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.attention)
            .imageScale(.small)
            .accessibilityLabel("Model list unavailable")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(.quaternary.opacity(0.6), in: Capsule())
      .contentShape(Capsule())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(configuration.isApplying)
    .help("Model and reasoning: \(title)")
    .accessibilityLabel("Model and reasoning, \(title)")
    .accessibilityIdentifier("composer-configuration")
  }
}
