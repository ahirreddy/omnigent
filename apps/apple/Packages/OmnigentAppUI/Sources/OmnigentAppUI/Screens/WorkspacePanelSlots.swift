import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// The right panel's content for one conversation, as the web's workspace rail has it: Files,
/// Changes and Search over the core's workspace reads, files and diffs opening as panel tabs,
/// the stored pull requests, and "Open new" for terminals and browsers, which open as window
/// tabs.
struct WorkspacePanelSlots {
  let workspace: WorkspaceBrowserModel?
  let panel: SessionPanelStore?
  let terminals: TerminalStore?
  let tabRoutes: ConversationTabRoutes?
  let terminalNames: DeclaredTerminals
  let permissionLevel: Int64?
  /// Starts a side chat; `nil` hides it.
  var newSideChat: (@MainActor () -> Void)?
  /// Inserts a path reference into the composer.
  let mention: (@MainActor (String) -> Void)?

  var slots: WorkspaceSlots {
    var slots = WorkspaceSlots()
    // Read when the panel draws, so terminal list changes redraw only the panel.
    if tabRoutes != nil { slots.openNew = { openNew } }
    if let panel {
      slots.pullRequests = PullRequestAdapter.state(panel)
      slots.refreshPullRequests = { Task { await panel.reloadPullRequests() } }
    }
    guard let workspace else { return slots }
    let actions = WorkspaceActions(mention: mention)
    slots.files = AnyView(
      FileTreeView(model: workspace.tree, source: workspace.source, actions: actions))
    let openDiff: (ChangedFile) -> Void = { file in
      Task { await workspace.open(.diff(path: file.path)) }
    }
    slots.changes = AnyView(
      ChangedFilesList(
        model: workspace.changes, source: workspace.source, actions: actions, onOpen: openDiff))
    if panel?.offersContentSearch == true {
      let openMatch: (OmnigentWorkspaceUI.ContentMatch) -> Void = { match in
        Task { await workspace.open(.file(path: match.path, line: match.line)) }
      }
      slots.search = AnyView(
        ContentSearchPanel(
          model: workspace.search, source: workspace.source, actions: actions, onOpen: openMatch))
    }
    slots.documents = Self.documents(workspace, actions: actions)
    return slots
  }

  /// The open files and diffs as panel tabs.
  static func documents(_ workspace: WorkspaceBrowserModel, actions: WorkspaceActions)
    -> InspectorDocuments
  {
    let find = { (id: String) in workspace.openDocuments.first { $0.tabID == id } }
    return InspectorDocuments(
      tabs: workspace.openDocuments.map(tab),
      selected: workspace.document?.tabID,
      select: { id in
        guard let document = find(id) else { return }
        Task { await workspace.open(document) }
      },
      close: { id in
        guard let document = find(id) else { return }
        Task { await workspace.close(document) }
      },
      showPanel: { workspace.hideDocument() },
      content: AnyView(WorkspaceDocumentView(model: workspace, actions: actions)))
  }

  /// A file tab shows the file's symbol; a diff tab the changes symbol.
  static func tab(_ document: WorkspaceDocument) -> InspectorDocumentTab {
    let name = WorkspacePaths.name(of: document.path)
    switch document {
    case .file:
      return InspectorDocumentTab(
        id: document.tabID, title: name, detail: document.path,
        systemImage: FileIcons.symbol(forName: name))
    case .diff:
      return InspectorDocumentTab(
        id: document.tabID, title: name, detail: "\(document.path) (changes)",
        systemImage: "plus.forwardslash.minus")
    }
  }

  /// "Open new": the agent's terminal, a new shell per declared terminal, the session's running
  /// shells, and a browser. Each opens as a window tab.
  private var openNew: [InspectorMenuSection] {
    guard let tabRoutes else { return [] }
    var sections: [InspectorMenuSection] = []
    if let newSideChat {
      sections.append(
        InspectorMenuSection(
          id: "chat",
          items: [
            InspectorMenuItem(
              id: "side-chat", title: "Side Chat", systemImage: "bubble.left.and.bubble.right",
              action: newSideChat)
          ]))
    }
    if let terminals {
      var items: [InspectorMenuItem] = []
      if case .ready = terminals.terminals.harness {
        items.append(
          InspectorMenuItem(
            id: "harness", title: "Agent Terminal", systemImage: TabKind.agentTerminal.systemImage,
            action: tabRoutes.openHarness))
      }
      if let newTerminal = tabRoutes.newTerminal {
        let canStart = terminalCanType(permissionLevel: permissionLevel)
        for name in terminalNames.choices {
          items.append(
            InspectorMenuItem(
              id: "new-\(name)", title: "Shell (\(name))", systemImage: "terminal",
              isEnabled: canStart
            ) { newTerminal(name) })
        }
      }
      sections.append(InspectorMenuSection(id: "new", items: items))
      let running = terminals.terminals.userShells.map { row in
        InspectorMenuItem(
          id: "open-\(row.terminal.id)", title: row.terminal.displayLabel,
          systemImage: "apple.terminal"
        ) { tabRoutes.openTerminal(row.terminal.id) }
      }
      if !running.isEmpty {
        sections.append(InspectorMenuSection(id: "running", title: "Terminals", items: running))
      }
    }
    if let openBrowser = tabRoutes.openBrowser {
      sections.append(
        InspectorMenuSection(
          id: "browser",
          items: [
            InspectorMenuItem(
              id: "browser", title: "Browser", systemImage: "globe", action: openBrowser)
          ]
        ))
    }
    return sections.filter { !$0.items.isEmpty }
  }
}
