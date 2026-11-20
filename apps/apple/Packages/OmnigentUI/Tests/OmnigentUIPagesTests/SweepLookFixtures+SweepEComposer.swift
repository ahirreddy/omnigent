import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for the composer and Automations screens sweep E changed.
@MainActor
extension SweepLookFixtures {
  /// A Codex native draft that runs as a shell command, with the agent working and two
  /// background shells still running.
  static var shellComposer: some View {
    var state = ComposerViewState(purpose: .session)
    state.isRunning = true
    state.shellHint = ComposerShellHint()
    var tray = ComposerTray()
    tray.indicators = ComposerTaskIndicators(backgroundTasks: 2)
    tray.indicators.agentWorking = true
    state.tray = tray
    return VStack(spacing: Theme.Spacing.large) {
      ComposerView(
        draft: .constant("!git status --short"), state: state,
        actions: ComposerActions(send: {}))
      ComposerView(
        draft: .constant("!ls @src/app.swift"), state: refusedShell,
        actions: ComposerActions(send: {}))
    }
    .frame(maxWidth: 640)
    .padding(Theme.Spacing.medium)
  }

  private static var refusedShell: ComposerViewState {
    var state = ComposerViewState(purpose: .session)
    state.mentions = ["src/app.swift"]
    state.shellHint = ComposerShellHint(
      refusal: "Shell commands can't include @mentions; remove them or drop the leading `!`.")
    return state
  }

  /// The Automations list with its Sort By menu beside the filter.
  static var automationsSorted: some View {
    var actions = AutomationsActions()
    actions.filter = { _, _ in }
    actions.sort = { _ in }
    actions.clone = { _ in }
    actions.edit = { _ in }
    actions.create = {}
    return AutomationsView(state: PreviewData.automations, actions: actions)
  }
}
