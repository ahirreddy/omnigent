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

/// The session's terminals: the list (create and close shells) beside the selected terminal's
/// surface. Surfaces live in the session's ``TerminalStore``, so closing the sheet keeps them.
struct TerminalsSheet: View {
  let store: TerminalStore
  let permissionLevel: Int64?
  let hostID: String?
  let close: () -> Void

  @State private var selection: TerminalListItem.ID?
  @State private var surface: TerminalSurfaceController?

  var body: some View {
    let terminals = store.terminals
    NavigationSplitView {
      TerminalListView(
        items: terminals.rows.map(TerminalAdapter.item), shellChoices: ["Shell"],
        canEdit: terminalCanType(permissionLevel: permissionLevel) && !terminals.isBusy,
        errorMessage: terminals.lastError?.message ?? store.lastError.map(String.init(describing:)),
        selection: $selection,
        onCreate: { name in Task { await create(name) } },
        onClose: { id in Task { await delete(id) } }
      )
      .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    } detail: {
      if let surface {
        SessionTerminalView(controller: surface)
      } else {
        ContentUnavailableView(
          "No Terminal Selected", systemImage: "apple.terminal",
          description: Text("Choose a terminal, or create a shell."))
      }
    }
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done", action: close)
      }
    }
    #if os(macOS)
      .frame(minWidth: 820, minHeight: 540)
    #endif
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
