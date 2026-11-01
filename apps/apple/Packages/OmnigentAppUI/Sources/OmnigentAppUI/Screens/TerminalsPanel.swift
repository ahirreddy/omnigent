import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTerminalUI
import OmnigentUIComponents
import SwiftUI

/// Maps the core's terminal records onto the components' and the terminal package's states.
enum TerminalAdapter {
  /// The session header's Chat/Terminal state from the core's harness terminal.
  /// - Parameter harness: `SessionTerminalsStore.harness`.
  /// - Returns: The status; `unavailable` offers "Resume sandbox".
  static func status(_ harness: HarnessTerminal) -> OmnigentUIComponents.TerminalStatus {
    switch harness {
    case .notTerminalFirst: .none
    case .startingUp: .startingUp(stage: nil)
    case .unavailable: .sandboxOffline
    case .ready: .ready
    }
  }

  /// A terminal list row.
  /// - Parameter row: The core's row.
  /// - Returns: The row.
  static func item(_ row: TerminalRow) -> TerminalListItem {
    let status: TerminalListStatus =
      switch row.status {
      case .active: .active
      case .idle: .idle
      case .exited: .exited
      case .unknown: .unknown
      }
    return TerminalListItem(
      id: row.terminal.id, title: row.terminal.displayLabel, status: status,
      isAgentTerminal: row.terminal.isAgentTerminal)
  }
}

/// The right panel's Terminals tab: a launcher. Choosing a terminal (or the agent's TUI) opens
/// it as a tab; New Terminal starts a shell and opens it. Surfaces live in the session's
/// ``TerminalStore``, so a terminal keeps its screen and scrollback across tabs.
struct TerminalsPanel: View {
  let store: TerminalStore
  let permissionLevel: Int64?
  /// Opens a terminal in a tab.
  let openTerminal: @MainActor (String) -> Void
  /// Opens the agent's TUI in a tab; `nil` when the session has none.
  let openHarness: (@MainActor () -> Void)?
  /// The terminals the agent declares (`ServerSession.declaredTerminalNames(in:)`).
  var declaredNames: DeclaredTerminals = .unknown

  @State private var selection: TerminalListItem.ID?

  var body: some View {
    let terminals = store.terminals
    VStack(spacing: 0) {
      if let openHarness {
        Button(action: openHarness) {
          Label("Agent Terminal", systemImage: TabKind.agentTerminal.systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help("Open the agent's terminal in a tab")
        .accessibilityIdentifier("terminals.open-harness")
        Divider()
      }
      if declaredNames == .names([]) {
        Label("This agent declares no terminals.", systemImage: "terminal")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .accessibilityIdentifier("terminals.none-declared")
      }
      TerminalListView(
        items: terminals.rows.map(TerminalAdapter.item), shellChoices: declaredNames.choices,
        canEdit: terminalCanType(permissionLevel: permissionLevel) && !terminals.isBusy,
        errorMessage: terminals.lastError?.message ?? store.lastError.map(String.init(describing:)),
        selection: $selection,
        onCreate: { name in Task { await create(name) } },
        onClose: { id in Task { await delete(id) } }
      )
      .listStyle(.plain)
      Text("Choose a terminal to open it as a tab.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    }
    .onAppear { terminals.refresh() }
    .onChange(of: selection) { _, id in
      guard let id else { return }
      selection = nil
      if case .ready(let harness) = store.terminals.harness, harness.id == id, let openHarness {
        openHarness()
      } else {
        openTerminal(id)
      }
    }
  }

  private func create(_ name: String) async {
    if let created = await store.terminals.create(name) { openTerminal(created.id) }
  }

  private func delete(_ id: String) async {
    store.close(id)
    await store.terminals.delete(id)
  }
}
