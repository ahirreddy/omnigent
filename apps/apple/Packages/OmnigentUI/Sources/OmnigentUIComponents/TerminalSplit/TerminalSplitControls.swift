public import SwiftUI

/// What a session's split Terminal view offers its owner (`splittable_terminal_view_ui`): Split
/// Right and Split Down with a shell the agent declares, and Close Pane.
public struct TerminalSplitControls {
  /// The session's split.
  public let panes: TerminalSplitPanes
  /// The shells a split can start, the default (the remembered one) first.
  public var shells: [String]
  /// A shell is being created or closed, so the split actions wait.
  public var isBusy: Bool
  /// Starts `shell` and splits the focused pane with it along `axis`.
  public var split: @MainActor (TerminalSplitAxis, String) -> Void
  /// Closes a shell pane: asks before ending a running shell, and drops a pane whose shell is
  /// gone.
  public var close: @MainActor (TerminalPaneKey) -> Void

  /// Creates the controls.
  /// - Parameters:
  ///   - panes: The session's split.
  ///   - shells: The shells, default first.
  ///   - isBusy: A create or close is in flight.
  ///   - split: Splits with a new shell.
  ///   - close: Closes a shell pane.
  public init(
    panes: TerminalSplitPanes, shells: [String], isBusy: Bool,
    split: @escaping @MainActor (TerminalSplitAxis, String) -> Void,
    close: @escaping @MainActor (TerminalPaneKey) -> Void
  ) {
    self.panes = panes
    self.shells = shells
    self.isBusy = isBusy
    self.split = split
    self.close = close
  }

  /// Adds the Conversation menu's split items: listed while the session offers the split,
  /// enabled while its Terminal view shows (as the web's chords work only with its buttons).
  /// - Parameters:
  ///   - actions: The menu's actions.
  ///   - isShown: The Terminal view shows.
  public func addCommands(to actions: inout SessionCommandActions, isShown: Bool) {
    actions.offersTerminalSplit = true
    guard isShown else { return }
    if !isBusy, let shell = shells.first {
      actions.splitTerminalRight = { split(.columns, shell) }
      actions.splitTerminalDown = { split(.rows, shell) }
    }
    guard let state = panes.state else { return }
    let panes = panes
    actions.nextTerminalPane = { panes.cycle(by: 1) }
    actions.previousTerminalPane = { panes.cycle(by: -1) }
    if state.focused != .agent {
      let focused = state.focused
      actions.closeTerminalPane = { close(focused) }
    }
  }
}

/// The Terminal view's toolbar items: Split Right and Split Down, each a menu of the shells
/// with the default first, and Close Pane while a shell pane has the focus.
struct TerminalSplitToolbarItems: View {
  let controls: TerminalSplitControls

  /// The toolbar widths the items take, in button widths.
  static let width = 3

  var body: some View {
    menu("Split Right", systemImage: "rectangle.split.2x1", axis: .columns)
    menu("Split Down", systemImage: "rectangle.split.1x2", axis: .rows)
    if let focused = controls.panes.state?.focused, focused != .agent {
      Button("Close Pane", systemImage: "xmark.rectangle") { controls.close(focused) }
        .help("Close the focused shell pane")
        .accessibilityIdentifier("terminal-close-pane")
    }
  }

  private func menu(_ title: String, systemImage: String, axis: TerminalSplitAxis) -> some View {
    let shortcut =
      axis == .columns ? AppShortcuts.splitTerminalRight : AppShortcuts.splitTerminalDown
    return Menu(title, systemImage: systemImage) {
      Section("\(title) with") {
        ForEach(Array(controls.shells.enumerated()), id: \.element) { index, shell in
          Button(index == 0 ? "\(shell) (default)" : shell) { controls.split(axis, shell) }
        }
      }
    }
    .menuIndicator(.hidden)
    .disabled(controls.isBusy || controls.shells.isEmpty)
    .help("\(title) (\(AppShortcuts.text(shortcut)))")
    .accessibilityIdentifier(axis == .columns ? "terminal-split-right" : "terminal-split-down")
  }
}
