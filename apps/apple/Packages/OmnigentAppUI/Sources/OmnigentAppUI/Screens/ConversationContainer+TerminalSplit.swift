import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentUIComponents
import SwiftUI

/// The session's Terminal view, split where its owner split it (`splittable_terminal_view_ui`):
/// Split Right and Split Down with a declared shell, Close Pane, kept per session on this device.
extension ConversationContainer {
  /// The harness's terminal, and the shells split off beside it.
  var harnessTerminal: some View {
    ConversationHarnessTerminal(
      surface: harnessSurface, harness: conversation.header?.settings?.harness,
      error: terminals?.lastError, terminals: terminals,
      split: terminalSplitPanes(isRegularWidth: isRegularWidth),
      attachShell: { [terminals, conversation] id in
        terminals?.controller(
          for: id, permissionLevel: conversation.header?.permissionLevel,
          hostID: conversation.header?.settings?.hostId)
      },
      report: { failures.append($0) })
  }

  /// Attaches the harness TUI once ready (the store keeps it), applying the default view.
  func attachHarness() {
    guard let terminals else { return }
    if terminals.terminals.harness != .notTerminalFirst { tabRoutes?.applyDefaultView?() }
    harnessSurface = terminals.harnessController(
      permissionLevel: conversation.header?.permissionLevel,
      hostID: conversation.header?.settings?.hostId)
    // The split menus list the shells the agent declares.
    let store = terminals.terminals
    if terminalSplitPanes(isRegularWidth: true) != nil, !store.knowsDeclaredTerminalNames {
      Task { await store.loadDeclaredTerminalNames() }
    }
  }

  /// Wide enough for a split Terminal view: always on a Mac.
  var isRegularWidth: Bool {
    #if os(iOS)
      sizeClass != .compact
    #else
      true
    #endif
  }

  /// The session's split, where its owner may split the Terminal view: the server offers it,
  /// the session is terminal-first with its agent's pane up, and the width is not compact.
  /// - Parameter isRegularWidth: The window is wide enough for panes (always on a Mac).
  /// - Returns: The split, or `nil` to show the agent's pane alone.
  func terminalSplitPanes(isRegularWidth: Bool) -> TerminalSplitPanes? {
    guard offersTerminalSplit, isRegularWidth, let terminals, isSessionOwner,
      case .ready = terminals.terminals.harness
    else { return nil }
    return terminalSplits.panes(of: conversation.sessionID)
  }

  /// The toolbar's and menus' split actions; `nil` where the split isn't offered or the agent
  /// declares no shells.
  /// - Parameters:
  ///   - isRegularWidth: The window is wide enough for panes.
  ///   - report: Shows a failure.
  /// - Returns: The controls.
  func terminalSplitControls(
    isRegularWidth: Bool, report: @escaping @MainActor (String) -> Void
  ) -> TerminalSplitControls? {
    guard let panes = terminalSplitPanes(isRegularWidth: isRegularWidth),
      let store = terminals?.terminals
    else { return nil }
    let defaults = terminalSplits.defaults
    let shells = Self.splitShells(
      store.declaredTerminalNames, preferred: PreferredTerminal.stored(in: defaults))
    guard !shells.isEmpty else { return nil }
    return TerminalSplitControls(
      panes: panes, shells: shells, isBusy: store.isBusy,
      split: { axis, shell in
        defaults.set(shell, forKey: PreferredTerminal.key)
        Task {
          guard let created = await store.create(shell) else {
            report("Couldn\u{2019}t open a shell: \(store.lastError?.message ?? "unknown error")")
            return
          }
          panes.split(with: created.id, axis: axis)
        }
      },
      close: { key in
        guard let id = key.shellID else { return }
        // A shell the list no longer holds has nothing to end: its pane just goes.
        if store.rows.contains(where: { $0.terminal.id == id }) {
          panes.closingShell = id
        } else {
          panes.remove(key)
        }
      })
  }

  /// The declared shells with the remembered one first, as the web's split menus list them.
  static func splitShells(_ declared: [String], preferred: String?) -> [String] {
    guard let first = PreferredTerminal.resolve(declared, preferred: preferred) else { return [] }
    return [first] + declared.filter { $0 != first }
  }

  /// The viewer owns the session, so its terminals take their typing.
  var isSessionOwner: Bool {
    conversation.header?.permissionLevel.map { $0 >= 4 } ?? true
  }
}
