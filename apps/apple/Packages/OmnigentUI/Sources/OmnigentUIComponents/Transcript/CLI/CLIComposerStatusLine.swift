import SwiftUI

/// The line under the CLI composer: `model effort · ~/dir · branch · mode`, and the warning
/// count on the right. The model is a real menu, drawn as text.
struct CLIStatusLine: View {
  let state: ComposerViewState
  let actions: ComposerActions
  let warnings: [String]
  @Binding var showsWarnings: Bool
  @Environment(\.cliPalette) private var palette
  @Environment(\.composerLayoutStyle) private var layout
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      // One row whose texts truncate (the directory first, the model last). No ViewThatFits:
      // measuring several copies of the menus keeps UIKit relaying out on iPhone.
      leading
      Spacer(minLength: Theme.Spacing.medium)
      if !warnings.isEmpty {
        Button {
          showsWarnings.toggle()
        } label: {
          Text(verbatim: "\u{26A0} \(warnings.count) warning\(warnings.count == 1 ? "" : "s")")
            .foregroundStyle(palette.heading.color)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsWarnings) {
          VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(warnings, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
          }
          .padding()
          .frame(maxWidth: 360)
        }
        .accessibilityIdentifier("composer-warnings")
      }
    }
    .cliFont()
    .lineLimit(1)
    .foregroundStyle(palette.dim.color)
  }

  private var leading: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      if let configuration = state.configuration {
        CLIModelMenu(configuration: configuration, actions: actions).layoutPriority(3)
      }
      if layoutWidth == .regular, let directory = state.tray?.directory ?? state.context?.directory
      {
        separator
        Text(verbatim: directory).foregroundStyle(palette.code.color).truncationMode(.head)
      }
      if let branch = state.tray?.branch ?? state.context?.branch {
        separator
        Text(verbatim: branch).foregroundStyle(palette.link.color).layoutPriority(1)
      }
      if let modes = state.approvalModes, let mode = modes.selected {
        separator
        CLIApprovalModeMenu(modes: modes, mode: mode, select: actions.extras.selectApprovalMode)
          .layoutPriority(2)
      }
      if state.isRunning, layout == .card {
        separator
        Text(verbatim: "esc to interrupt")
      }
    }
  }

  private var separator: some View {
    Text(verbatim: " \u{00B7} ").accessibilityHidden(true)
  }
}

/// The model and effort as status-line text that opens the native picker.
private struct CLIModelMenu: View {
  let configuration: ComposerConfiguration
  let actions: ComposerActions
  @Environment(\.cliPalette) private var palette

  var body: some View {
    Menu {
      if let selectModel = actions.selectModel, !configuration.visibleModels.isEmpty {
        Picker(
          "Model",
          selection: Binding(get: { configuration.selectedModelId }, set: { selectModel($0) })
        ) {
          Text(configuration.defaultModelTitle).tag(String?.none)
          ForEach(configuration.visibleModels) { Text($0.label).tag(Optional($0.id)) }
        }
        .pickerStyle(.inline)
      }
      if let selectEffort = actions.selectEffort, !configuration.efforts.isEmpty {
        Picker(
          "Effort",
          selection: Binding<String?>(
            get: { configuration.selectedEffort }, set: { selectEffort($0) })
        ) {
          Text(configuration.defaultEffortTitle).tag(String?.none)
          ForEach(configuration.efforts, id: \.self) { (effort: String) in
            Text(ComposerConfiguration.effortLabel(effort)).tag(String?.some(effort))
          }
        }
        .pickerStyle(.inline)
      }
      if let error = configuration.errorMessage { Section { Text(error) } }
    } label: {
      Text(
        verbatim: [configuration.modelTitle, configuration.effortTitle?.lowercased()]
          .compactMap(\.self).joined(separator: " ")
      )
      .foregroundStyle(palette.strong.color)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(configuration.isApplying)
    .help("Model and effort: \(configuration.title)")
    .accessibilityLabel("Model and effort, \(configuration.title)")
    .accessibilityIdentifier("composer-configuration")
  }
}

/// The approval mode as status-line text that opens the mode picker (touch has no ⇧Tab).
private struct CLIApprovalModeMenu: View {
  let modes: ApprovalModes
  let mode: ApprovalModeOption
  let select: (@MainActor (ApprovalModeOption) -> Void)?
  @Environment(\.cliPalette) private var palette

  var body: some View {
    if let select {
      Menu {
        ForEach(modes.options.filter(\.isSwitchable)) { option in
          Button {
            select(option)
          } label: {
            if option.id == mode.id {
              Label(option.label, systemImage: "checkmark")
            } else {
              Text(option.label)
            }
          }
        }
      } label: {
        label
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("\(modes.title), \(mode.label)")
      .accessibilityIdentifier("composer-approval-mode")
    } else {
      label
    }
  }

  private var label: some View {
    Text(verbatim: mode.label)
      .foregroundStyle(mode.risk == .fullAccess ? palette.needsYou.color : palette.dim.color)
  }
}
