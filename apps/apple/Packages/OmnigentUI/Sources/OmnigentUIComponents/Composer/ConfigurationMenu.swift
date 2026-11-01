import SwiftUI

/// The harness, model and reasoning picker shown in the composer toolbar.
struct ConfigurationMenu: View {
  let configuration: ComposerConfiguration
  let actions: ComposerActions
  var isCompact = false

  private var visibleModels: [ModelOption] { configuration.modelOptions.filter { !$0.hidden } }

  private var modelLabel: String {
    configuration.selectedModel?.label ?? "Default"
  }

  private var title: String {
    if let effort = configuration.selectedEffort {
      return "\(modelLabel) \u{00B7} \(Self.effortLabel(effort))"
    }
    return modelLabel
  }

  /// The web's effort labels: "Low", "Medium", "High", "xHigh", "Max".
  static func effortLabel(_ effort: String) -> String {
    switch effort.lowercased() {
    case "xhigh", "x-high", "extra_high": "xHigh"
    default: effort.prefix(1).uppercased() + effort.dropFirst()
    }
  }

  private func effortPicker(_ select: @escaping @MainActor (String?) -> Void) -> some View {
    let selection = Binding<String?>(get: { configuration.selectedEffort }, set: { select($0) })
    return Picker("Effort", selection: selection) {
      Text("Default").tag(String?.none)
      ForEach(configuration.efforts, id: \.self) { (effort: String) in
        Text(Self.effortLabel(effort)).tag(String?.some(effort))
      }
    }
    .pickerStyle(.inline)
  }

  var body: some View {
    Menu {
      if let selectModel = actions.selectModel {
        Section("Models") {
          Picker(
            "Model",
            selection: Binding(
              get: { configuration.selectedModelId },
              set: { selectModel($0) })
          ) {
            Text("Default").tag(String?.none)
            ForEach(visibleModels) { option in
              Text(option.label).tag(Optional(option.id))
            }
          }
          .pickerStyle(.inline)
        }
      }
      if let selectEffort = actions.selectEffort, !configuration.efforts.isEmpty {
        Section("Effort") { effortPicker(selectEffort) }
      }
      if let selectAgent = actions.selectAgent, !configuration.harnessChoices.isEmpty {
        Section("Harnesses") {
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
      HStack(spacing: Theme.Spacing.extraSmall) {
        HarnessGlyph(harness: configuration.harness, size: 15)
        Text(modelLabel)
          .font(Theme.Typography.label)
          .lineLimit(1)
          .truncationMode(.middle)
          .frame(maxWidth: isCompact ? Theme.Control.compactModelWidth : Theme.Control.modelWidth)
        if let effort = configuration.selectedEffort, !isCompact {
          Text(Self.effortLabel(effort))
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
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .composerChip()
    .fixedSize()
    .disabled(configuration.isApplying)
    .help("Model and effort: \(title) (Control-Shift-M)")
    .accessibilityLabel("Model and effort, \(title)")
    .accessibilityIdentifier("composer-configuration")
  }
}
