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

/// The right panel's Terminals tab: the session's terminals (create and close shells) above the
/// selected terminal's surface. Surfaces live in the session's ``TerminalStore``, so switching
/// tabs or closing the panel keeps their screens and scrollback.
struct TerminalsPanel: View {
  let store: TerminalStore
  let permissionLevel: Int64?
  let hostID: String?

  @State private var selection: TerminalListItem.ID?
  @State private var surface: TerminalSurfaceController?

  var body: some View {
    let terminals = store.terminals
    VStack(spacing: 0) {
      TerminalListView(
        items: terminals.rows.map(TerminalAdapter.item), shellChoices: ["Shell"],
        canEdit: terminalCanType(permissionLevel: permissionLevel) && !terminals.isBusy,
        errorMessage: terminals.lastError?.message ?? store.lastError.map(String.init(describing:)),
        selection: $selection,
        onCreate: { name in Task { await create(name) } },
        onClose: { id in Task { await delete(id) } }
      )
      .listStyle(.plain)
      // The list takes the whole tab until a terminal is attached, then yields to its surface.
      .frame(minHeight: 96, idealHeight: 160, maxHeight: surface == nil ? .infinity : 200)
      if let surface {
        Divider()
        SessionTerminalView(controller: surface)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear { terminals.refresh() }
    .onChange(of: selection) { _, id in
      surface = id.flatMap {
        store.controller(for: $0, permissionLevel: permissionLevel, hostID: hostID)
      }
    }
  }

  private func create(_ name: String) async {
    if let created = await store.terminals.create(name) { selection = created.id }
  }

  private func delete(_ id: String) async {
    store.close(id)
    if selection == id { selection = nil }
    await store.terminals.delete(id)
  }
}
