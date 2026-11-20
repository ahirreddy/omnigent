import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for sweep G's outbox, prompt and terminal screens.
@MainActor
extension SweepLookFixtures {
  /// The composer over requests kept across a relaunch: one the server is slow to answer, one
  /// that may have reached the agent before the app closed, and one another account would send.
  static var outboxSaved: some View {
    var state = ComposerViewState(purpose: .session)
    state.designRequests = [
      DesignRequestRow(
        id: UUID(), tool: .annotate, label: "Annotate button \"Buy now\"", state: .slow),
      DesignRequestRow(
        id: UUID(), tool: .draw, label: "Draw: Tighten the header",
        state: .failed(
          "The app closed before this was confirmed sent, so it may have reached the agent. "
            + "Look in the chat: if it isn't there, Retry sends it.", canRetry: true)),
      DesignRequestRow(
        id: UUID(), tool: .annotate, label: "Annotate h1 \"Your order\"",
        state: .failed(
          "Another account is signed in now, so this wasn't sent. Sign back in as the account "
            + "that made it to Retry, or Remove it.", canRetry: true)),
    ]
    var actions = ComposerActions(send: {})
    actions.extras.designRequests = DesignRequestActions(retry: { _ in }, remove: { _ in })
    return ComposerView(draft: .constant(""), state: state, actions: actions)
      .frame(maxWidth: 640)
      .padding(Theme.Spacing.medium)
  }

  /// Sent prompts whose leading command the session knows, tinted in the chat bubble and in
  /// the CLI transcript; an unknown one stays plain.
  static var promptCommand: some View {
    let commands = [SlashCommand(name: "review"), SlashCommand(name: "compact")]
    return VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      MessageRowView(
        row: Row(id: "command", role: .user, text: "/review the paging in the session store"),
        decoration: MessageDecoration())
      MessageRowView(
        row: Row(id: "unknown", role: .user, text: "/unknown stays as typed"),
        decoration: MessageDecoration())
      CLIUserText(text: "/compact keep the decisions", tintsCommand: true)
        .padding(Theme.Spacing.small)
        .background { CLICanvas() }
        .transcriptAppearance(TranscriptAppearance(style: .cli))
        .cliPalette()
    }
    .environment(\.promptCommands, commands)
    .padding(Theme.Spacing.medium)
  }

  /// A split Terminal view while the agent's terminal is down: the shell keeps its pane, the
  /// agent's says it's unavailable, and a band above says why with Resume.
  static var terminalKept: some View {
    TerminalPane(
      status: .harnessNotRunning, keepsPanes: true, resume: {},
      content: {
        HStack(spacing: 1) {
          ContentUnavailableView("Terminal Unavailable", systemImage: "apple.terminal")
            .background(.background)
          Text("$ git status\nOn branch main\nnothing to commit, working tree clean\n$ ")
            .font(.system(size: 12, design: .monospaced))
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
        }
        .background(.separator)
      })
  }
}
