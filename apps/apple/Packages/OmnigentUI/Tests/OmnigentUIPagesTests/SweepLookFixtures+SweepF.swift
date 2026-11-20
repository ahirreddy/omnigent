import Foundation
import OmnigentWorkspaceUI
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for the screens sweep F added.
@MainActor
extension SweepLookFixtures {
  /// The Terminal view split three ways: the agent's pane, and two shells stacked on the right
  /// with the lower one focused, under the toolbar's split actions.
  static var terminalSplit: some View {
    let suite = "sweep-f-terminal-split"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    defaults.removePersistentDomain(forName: suite)
    let panes = TerminalSplitPanes(sessionID: "conv_split", defaults: defaults)
    panes.split(with: "shell_1", axis: .columns)
    panes.split(with: "shell_2", axis: .rows)
    let controls = TerminalSplitControls(
      panes: panes, shells: ["zsh", "bash"], isBusy: false, split: { _, _ in }, close: { _ in })
    return VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Spacer()
        TerminalSplitToolbarItems(controls: controls)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .padding(Theme.Spacing.small)
      Divider()
      TerminalSplitView(
        state: panes.state, resize: { _, _ in }, pane: { key in FixtureTerminalPane(key: key) })
    }
  }
}

extension SweepLookFixtures {
  /// Drafts with a known command and a tagged path, and a shell command, each tinted.
  static var composerTints: some View {
    var state = ComposerViewState(purpose: .session)
    state.slashCommands = [SlashCommand(name: "review"), SlashCommand(name: "compact")]
    state.mentions = ["Sources/Store.swift"]
    var shell = ComposerViewState(purpose: .session)
    shell.shellHint = ComposerShellHint()
    return VStack(spacing: Theme.Spacing.large) {
      ComposerView(
        draft: .constant("/review the paging in @Sources/Store.swift"), state: state,
        actions: ComposerActions(send: {}))
      ComposerView(
        draft: .constant("!git log --oneline -5"), state: shell, actions: ComposerActions(send: {}))
    }
    .frame(maxWidth: 640)
    .padding(Theme.Spacing.medium)
  }
}

extension SweepLookFixtures {
  /// The session overview's rows for a workspace with uncommitted changes.
  static var overviewChanges: some View {
    Form {
      LabeledContent("Session cost", value: "$1.27")
      LabeledContent("Tokens", value: "184.2K")
      SessionOverviewChangeRows(
        list: ChangesList(
          files: [
            ChangedFile(path: "Sources/Store.swift", status: .modified, linesAdded: 42),
            ChangedFile(path: "Sources/Paging.swift", status: .created, linesAdded: 120),
            ChangedFile(path: "Sources/Old.swift", status: .deleted, linesRemoved: 31),
          ],
          totals: ChangeTotals(
            created: 1, modified: 1, deleted: 1, linesAdded: 162, linesRemoved: 31)))
    }
    .formStyle(.grouped)
    .frame(width: 300)
  }
}

/// A terminal's look without a surface: monospaced lines on the terminal background.
private struct FixtureTerminalPane: View {
  let key: TerminalPaneKey
  @Environment(\.colorScheme) private var colorScheme

  private var lines: [String] {
    switch key {
    case .agent:
      [
        "> Refactor the session store", "", "  Read Sources/Store.swift (212 lines)",
        "  Edited Sources/Store.swift +18 -6", "", "  Done. The store now pages its rows.",
      ]
    case .shell(let id) where id == "shell_1": ["~/project $ git status --short", " M Store.swift"]
    case .shell: ["~/project $ swift test --filter Store", "Test run with 12 tests passed"]
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in Text(line) }
      Spacer(minLength: 0)
    }
    .font(.system(size: 12, design: .monospaced))
    .foregroundStyle(colorScheme == .dark ? Color(white: 0.85) : Color(white: 0.15))
    .padding(8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(white: colorScheme == .dark ? 0.04 : 1))
  }
}
