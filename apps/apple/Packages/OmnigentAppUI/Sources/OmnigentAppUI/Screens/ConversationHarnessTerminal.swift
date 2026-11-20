import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTerminalUI
import OmnigentUIComponents
import SwiftUI

/// The harness TUI when the core reports it ready, else the package's placeholder. Where the
/// owner split the Terminal view, the shells they split off show beside it, and keep showing
/// while the agent's terminal is down, as the web's.
struct ConversationHarnessTerminal: View {
  let surface: TerminalSurfaceController?
  let harness: String?
  /// Why the surface couldn't start.
  let error: GhosttyError?
  /// The session's terminals, for the split's shell panes.
  var terminals: TerminalStore?
  /// The session's split; `nil` shows the agent's pane alone.
  var split: TerminalSplitPanes?
  /// Attaches a shell pane's terminal.
  var attachShell: @MainActor (String) -> TerminalSurfaceController? = { _ in nil }
  /// Shows a failure.
  var report: @MainActor (String) -> Void = { _ in }

  /// Shell panes' surfaces, attached as their panes appear.
  @State private var shells: [String: TerminalSurfaceController] = [:]
  @State private var focusTask: Task<Void, Never>?

  var body: some View {
    if let split, surface != nil || split.state != nil {
      TerminalSplitView(
        state: split.state, resize: { split.resize(at: $0, to: $1) },
        pane: { key in pane(key, agent: surface) }
      )
      .modifier(TerminalPageFocus(surface: focusedSurface(agent: surface)))
      .onChange(of: shellIDs, initial: true) { attachShells() }
      .onChange(of: listedIDs, initial: true) { split.follow(listedTerminalIDs: listedIDs) }
      .onChange(of: split.state?.focused) { focusPane(agent: surface) }
      .task(id: split.sessionID) { await pruneGoneShells() }
      .modifier(CloseShellPanePrompt(split: split, terminals: terminals, report: report))
    } else if let surface {
      SessionTerminalView(controller: surface)
        .modifier(TerminalPageFocus(surface: surface))
    } else {
      VStack {
        TerminalPlaceholderView(harness: harness)
        if let error {
          Label(String(describing: error), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
  }

  @ViewBuilder
  private func pane(_ key: TerminalPaneKey, agent: TerminalSurfaceController?) -> some View {
    switch key {
    case .agent:
      if let agent {
        SessionTerminalView(controller: agent)
          .onChange(of: agent.hasKeyboardFocus) { _, has in if has { split?.focus(.agent) } }
      } else {
        ContentUnavailableView("Terminal Unavailable", systemImage: "apple.terminal")
          .accessibilityIdentifier("terminal-split-agent-unavailable")
      }
    case .shell(let id):
      if let shell = shells[id] {
        SessionTerminalView(controller: shell)
          .onChange(of: shell.hasKeyboardFocus) { _, has in if has { split?.focus(key) } }
      } else {
        ContentUnavailableView("Terminal Unavailable", systemImage: "apple.terminal")
      }
    }
  }

  /// The split's shell panes.
  private var shellIDs: [String] {
    split?.state?.layout.keys.compactMap(\.shellID) ?? []
  }

  /// Every terminal the session's list holds.
  private var listedIDs: Set<String> {
    Set(terminals?.terminals.rows.map(\.terminal.id) ?? [])
  }

  /// The focused pane's surface; with the agent's terminal down, the first shell's.
  private func focusedSurface(agent: TerminalSurfaceController?) -> TerminalSurfaceController? {
    guard let id = split?.state?.focused.shellID else {
      return agent ?? shellIDs.lazy.compactMap { shells[$0] }.first
    }
    return shells[id] ?? agent
  }

  private func attachShells() {
    for id in shellIDs where shells[id] == nil {
      if let shell = attachShell(id) { shells[id] = shell }
    }
  }

  /// A pane focused by a command or a new split takes the keyboard once it is in the window.
  private func focusPane(agent: TerminalSurfaceController?) {
    focusTask?.cancel()
    guard focusedSurface(agent: agent)?.hasKeyboardFocus == false else { return }
    focusTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(100))
      } catch {
        return
      }
      // A new split's shell attaches in the same update, so it is looked up after the wait.
      focusedSurface(agent: agent)?.focus()
    }
  }

  /// Drops panes of shells that ended while the session was closed, from a full read.
  private func pruneGoneShells() async {
    guard let split, !shellIDs.isEmpty, let store = terminals?.terminals else { return }
    // A failed read stays in the store's last error, shown in its Terminals panel; the panes
    // stay until a later list leaves them out.
    guard case .success(let listed) = await store.list() else { return }
    split.prune(keeping: Set(listed.map(\.id)))
  }
}

/// "Close shell?" before Close Pane ends a running shell, as a shell tab's close asks.
private struct CloseShellPanePrompt: ViewModifier {
  let split: TerminalSplitPanes?
  let terminals: TerminalStore?
  let report: @MainActor (String) -> Void

  func body(content: Content) -> some View {
    content.alert(
      "Close shell?",
      isPresented: Binding(
        get: { split?.closingShell != nil },
        set: { if !$0 { split?.closingShell = nil } })
    ) {
      Button("Cancel", role: .cancel) { split?.closingShell = nil }
      Button("Close Shell", role: .destructive) { closeShell() }
    } message: {
      Text(CloseShellConfirmation.message(name: name))
    }
  }

  private var name: String? {
    guard let id = split?.closingShell else { return nil }
    return terminals?.terminals.rows.first { $0.terminal.id == id }?.terminal.displayLabel
  }

  private func closeShell() {
    guard let id = split?.closingShell, let store = terminals?.terminals else { return }
    split?.closingShell = nil
    Task {
      // The pane goes once the shell leaves the session's list.
      await store.delete(id)
      if let error = store.lastError {
        report("The shell could not be closed: \(error.message)")
      }
    }
  }
}
