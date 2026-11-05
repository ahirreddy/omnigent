import SwiftUI

/// The Mac's row under the pill: where the session runs on the leading side (the host picker,
/// the context line, folder, worktree and pull request) and the task indicators (background
/// tasks, sub-agents, the goal), then plain-text controls on the trailing side: model and
/// effort, approval mode, and the context ring. Each opens its menu.
struct ComposerFooter: View {
  let state: ComposerViewState
  let actions: ComposerActions
  let isEditable: Bool
  var showsContextDetails = false

  private var tray: ComposerTrayView {
    ComposerTrayView(
      tray: state.tray ?? ComposerTray(), context: state.context, actions: actions.extras,
      showsContextDetails: showsContextDetails)
  }

  /// A host the user can still choose (a new session); a locked one is in the context line.
  private var choosableHosts: ComposerHosts? {
    guard let hosts = state.hosts, !hosts.isLocked else { return nil }
    return hosts
  }

  private var indicators: ComposerTaskIndicators { state.tray?.indicators ?? .init() }

  private var hasLeading: Bool {
    choosableHosts != nil || !indicators.isEmpty
      || ((state.tray != nil || state.context != nil) && tray.hasLeadingItems)
  }

  var body: some View {
    // A narrow pane puts where it runs on its own line above the controls.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.medium) {
        leading
        Spacer(minLength: Theme.Spacing.small)
        trailing
      }
      VStack(alignment: .trailing, spacing: Theme.Spacing.extraSmall) {
        HStack(spacing: Theme.Spacing.medium) {
          leading
          Spacer(minLength: 0)
        }
        trailing
      }
    }
    .font(.callout)
    .menuStyle(.button)
    .buttonStyle(.borderless)
    .padding(.horizontal, Theme.Spacing.small)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("composer-footer")
  }

  @ViewBuilder private var leading: some View {
    if hasLeading {
      HStack(spacing: Theme.Spacing.medium) {
        // The context line names the host; the chip keeps its symbol, status and menu.
        if let hosts = choosableHosts {
          HostChip(hosts: hosts, actions: actions.extras, showsName: false).tint(.secondary)
        }
        if state.tray != nil || state.context != nil {
          tray.leadingItems.menuIndicator(.visible)
        }
        if !indicators.isEmpty {
          ComposerIndicatorsView(indicators: indicators, actions: actions.extras.indicators)
        }
      }
      .font(.caption)
      // Plain menus keep the row's caption size; borderless ones use the control font.
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("composer-tray")
    }
  }

  private var trailing: some View {
    HStack(spacing: Theme.Spacing.small) {
      if actions.extras.isPlanOn, state.purpose == .session {
        PlanModeBadge(exit: actions.extras.togglePlan)
      }
      if let configuration = state.configuration {
        ConfigurationMenu(
          configuration: configuration, actions: actions, showsAgent: state.purpose == .start
        )
        .disabled(!isEditable)
        .tint(.primary)
      }
      if let modes = state.approvalModes {
        ApprovalModeChip(modes: modes, select: actions.extras.selectApprovalMode)
          .disabled(!isEditable)
          .tint(.primary)
      }
      if let fraction = state.tray?.contextFraction {
        tray.contextUsage(fraction, showsPercent: false)
          .padding(.horizontal, Theme.Spacing.extraSmall)
      }
    }
    .fixedSize()
  }
}

/// "Plan mode" while Codex plans instead of editing (web `composer-plan-mode`); its context
/// menu leaves plan mode when the viewer may.
struct PlanModeBadge: View {
  let exit: (@MainActor () -> Void)?

  var body: some View {
    Label("Plan mode", systemImage: "doc.text")
      .font(.caption.weight(.medium))
      .foregroundStyle(.primary)
      .help("The agent plans and asks before making changes")
      .contextMenu {
        if let exit { Button("Exit Plan mode", action: exit) }
      }
      .accessibilityIdentifier("composer-plan-mode")
  }
}

/// The chrome of a composer menu: a chip on touch, plain text with a hover highlight under the
/// Mac's pill.
struct ComposerControlChrome: ViewModifier {
  @Environment(\.composerLayoutStyle) private var layout

  func body(content: Content) -> some View {
    if layout == .card {
      content
        .font(.callout)
        .padding(.horizontal, Theme.Spacing.extraSmall)
        .padding(.vertical, Theme.Spacing.tiny)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small / 2))
        .hoverHighlight(cornerRadius: Theme.Radius.small / 2)
    } else {
      content.composerChip()
    }
  }
}

/// The Mac's pill: white in light mode (lifted off every palette's canvas, as the design asks)
/// and tinted glass in dark, with a thin border and a soft shadow. Under Reduce Transparency the
/// dark pill is the theme's solid surface. A drop or keyboard focus strengthens the border.
struct ComposerPillSurface: ViewModifier {
  let isTargeted: Bool
  let isFocused: Bool
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
    content
      .background {
        if colorScheme == .light { shape.fill(.white) }
      }
      .glassSurface(in: shape)
      .overlay {
        shape.strokeBorder(
          isTargeted ? AnyShapeStyle(Theme.focus) : AnyShapeStyle(ThemeColor.border),
          lineWidth: isTargeted ? 1.5 : (isFocused ? 1 : 0.5)
        )
        .allowsHitTesting(false)
      }
      .shadow(
        color: .black.opacity(colorScheme == .light ? 0.08 : 0.3), radius: 10, x: 0, y: 3
      )
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: isFocused)
  }
}

/// The Mac's pill or the touch bar's card.
struct ComposerCardSurface: ViewModifier {
  let layout: ComposerLayoutStyle
  let isTargeted: Bool
  let isFocused: Bool

  func body(content: Content) -> some View {
    switch layout {
    case .card: content.modifier(ComposerPillSurface(isTargeted: isTargeted, isFocused: isFocused))
    case .touch: content.composerSurface(isTargeted: isTargeted, isFocused: isFocused)
    }
  }
}
