import SwiftUI

/// The line under the CLI composer: `model effort · ~/dir · branch · mode`, then on the right
/// what the chat composer's row shows beside its controls (plan mode, background tasks,
/// sub-agents, goal, pull request, context use) and the warning count. Menus draw as text.
struct CLIStatusLine: View {
  let state: ComposerViewState
  let actions: ComposerActions
  let warnings: [String]
  @Binding var showsWarnings: Bool
  @Environment(\.cliPalette) private var palette
  @Environment(\.composerLayoutStyle) private var layout
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    // A phone puts the indicators on their own line rather than truncating the status away.
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      statusRow
      if layoutWidth == .compact {
        CLIStatusIndicators(state: state, actions: actions)
      }
    }
    .cliFont()
    .lineLimit(1)
    .foregroundStyle(palette.dim.color)
  }

  private var statusRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      // One row whose texts truncate (the branch first, the folder down to its name, the model
      // never). No ViewThatFits: measuring several copies of the menus keeps UIKit relaying out
      // on iPhone.
      leading
      Spacer(minLength: Theme.Spacing.medium)
      if layoutWidth != .compact {
        CLIStatusIndicators(state: state, actions: actions).layoutPriority(4)
      }
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
  }

  private var leading: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      if let configuration = state.configuration {
        CLIModelMenu(configuration: configuration, actions: actions).layoutPriority(3)
      }
      if layoutWidth == .regular, let directory = state.tray?.directory ?? state.context?.directory
      {
        separator
        CLIDirectoryText(directory: directory).foregroundStyle(palette.code.color)
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
    Text(verbatim: " \u{00B7} ").fixedSize().accessibilityHidden(true)
  }
}

/// The working directory, truncated at its head but never narrower than its last component, as
/// the web's folder chip shows the folder's name: the branch and the goal give way first.
struct CLIDirectoryText: View {
  let directory: String

  /// The shortest form shown: "…/name", the name capped at 24 characters.
  static func minimumText(_ directory: String) -> String {
    let name =
      directory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
      .map(String.init) ?? directory
    let shown = name.count > 24 ? "\u{2026}" + name.suffix(23) : name
    return shown == directory ? shown : "\u{2026}/" + shown
  }

  var body: some View {
    // The hidden copy sets the minimum width; the visible text fills whatever it is given.
    ZStack(alignment: .leading) {
      Text(verbatim: Self.minimumText(directory)).fixedSize().hidden()
      Text(verbatim: directory).truncationMode(.head)
    }
  }
}

/// The chat composer's task indicators, pull request and context use, as status-line items.
private struct CLIStatusIndicators: View {
  let state: ComposerViewState
  let actions: ComposerActions
  @Environment(\.cliPalette) private var palette

  private var showsPlan: Bool { actions.extras.isPlanOn && state.purpose == .session }

  var body: some View {
    let tray = state.tray ?? ComposerTray()
    if showsPlan || !tray.indicators.isEmpty || tray.pullRequest != nil
      || tray.contextFraction != nil
    {
      items(tray)
    }
  }

  private func items(_ tray: ComposerTray) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
      if showsPlan {
        Text(verbatim: "plan mode").foregroundStyle(palette.heading.color)
          .help("The agent plans and asks before making changes")
          .accessibilityIdentifier("composer-plan-mode")
      }
      if !tray.indicators.isEmpty {
        // The goal as its glyph alone, as the web's bar shows it; the objective is its tooltip.
        ComposerIndicatorsView(
          indicators: tray.indicators, actions: actions.extras.indicators,
          showsGoalObjective: false
        )
        .buttonStyle(.plain)
        .menuStyle(.button)
      }
      if let pullRequest = tray.pullRequest {
        ComposerPullRequestChip(
          label: pullRequest, status: tray.pullRequestStatus, preview: tray.pullRequestPreview,
          open: actions.extras.indicators.openPullRequests
        )
        .buttonStyle(.plain)
      }
      if let fraction = tray.contextFraction {
        let percent = Int((fraction * 100).rounded())
        Text(verbatim: "\(percent)% context")
          .foregroundStyle(fraction > 0.85 ? palette.needsYou.color : palette.dim.color)
          .help("Context used: \(percent)% of the context window")
          .accessibilityLabel("Context used")
          .accessibilityValue("\(percent) percent")
          .accessibilityIdentifier("composer-context-usage")
      }
    }
    .fixedSize()
    .padding(.trailing, Theme.Spacing.medium)
  }
}

/// The model and effort as status-line text that opens the native picker.
private struct CLIModelMenu: View {
  let configuration: ComposerConfiguration
  let actions: ComposerActions
  @Environment(\.cliPalette) private var palette

  var body: some View {
    Menu {
      SmartRoutingToggle(configuration: configuration, set: actions.extras.setSmartRouting)
      if let selectModel = actions.selectModel, !configuration.visibleModels.isEmpty {
        Picker(
          "Model",
          selection: Binding(get: { configuration.pickedModelId }, set: { selectModel($0) })
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
            get: { configuration.pickedEffort }, set: { selectEffort($0) })
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
      label.fixedSize()
    }
  }

  private var label: some View {
    Text(verbatim: mode.label)
      .foregroundStyle(mode.risk == .fullAccess ? palette.needsYou.color : palette.dim.color)
  }
}
