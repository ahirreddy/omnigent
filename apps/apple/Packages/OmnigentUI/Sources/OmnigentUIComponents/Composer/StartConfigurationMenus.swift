import SwiftUI

/// A new session's choices on the Mac, each its own menu and in the order they are made: the
/// agent (led by its harness's mark in color), then that agent's model, then the model's effort.
struct StartConfigurationMenus: View {
  let menu: ConfigurationMenu

  private var configuration: ComposerConfiguration { menu.configuration }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      chip(identifier: "composer-configuration", name: "Agent", value: configuration.agentTitle) {
        menu.agentChoices
      } label: {
        HarnessIcon(
          harness: configuration.harness ?? configuration.selectedAgent?.harness, style: .color,
          size: 14)
        Text(configuration.agentTitle).lineLimit(1)
      }
      if menu.actions.selectModel != nil, offersModels {
        chip(identifier: "composer-model-menu", name: "Model", value: configuration.modelTitle) {
          menu.modelChoices
        } label: {
          Text(configuration.modelTitle)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: Theme.Control.modelWidth)
        }
      }
      if menu.actions.selectEffort != nil, !configuration.efforts.isEmpty {
        chip(
          identifier: "composer-effort-menu", name: "Effort",
          value: configuration.effortTitle ?? configuration.defaultEffortTitle
        ) {
          menu.effortChoices
        } label: {
          Text(configuration.effortTitle ?? "Effort").lineLimit(1)
        }
        .disabled(configuration.isSmartRoutingOn)
      }
      if configuration.isApplying {
        ProgressView().controlSize(.mini)
      } else if let error = configuration.errorMessage {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.warning)
          .imageScale(.small)
          .help(error)
          .accessibilityLabel("Model list unavailable")
      }
    }
  }

  /// Models to choose from, or Smart Routing to turn on in their place.
  private var offersModels: Bool {
    !configuration.visibleModels.isEmpty || configuration.smartRouting != .unavailable
  }

  private func chip(
    identifier: String, name: String, value: String,
    @ViewBuilder choices: () -> some View, @ViewBuilder label: () -> some View
  ) -> some View {
    Menu {
      // A busy session refuses every change here, so the choices say why and take no click.
      if let reason = configuration.busyReason {
        Section { Text(reason) }
      }
      choices().disabled(configuration.busyReason != nil)
    } label: {
      HStack(spacing: Theme.Spacing.extraSmall) {
        label()
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .combine)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .modifier(ComposerControlChrome())
    .fixedSize()
    .disabled(configuration.isApplying)
    .help("\(name): \(value)")
    .accessibilityLabel("\(name), \(value)")
    .accessibilityIdentifier(identifier)
  }
}
