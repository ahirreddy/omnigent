import Observation
public import SwiftUI

/// The playground's "tabs" scenario: the shell with a strip of every tab kind (a pinned chat
/// that needs you, a running chat, the agent's terminal, a shell with activity, a side chat, a
/// loading browser page with audio, an agent's browser and the new-tab page), all working on
/// sample data. The chats are their sessions' primary chats, so they have no close button, and
/// any tab opens in a split view from its context menu, View > Show Split View or a drag.
public struct TabsPlayground: View {
  @State private var model: TabsPlaygroundModel
  @State private var selection: SidebarDestination?
  @State private var search = ""
  @Environment(\.remoteBrowserPreview) private var remoteBrowser

  /// Creates the scenario.
  /// - Parameter split: Start with the chat and the docs page side by side.
  public init(split: Bool = false) {
    _model = State(initialValue: TabsPlaygroundModel(split: split))
  }

  /// The scenario.
  public var body: some View {
    AppShell(
      sidebar: PreviewData.sidebar, selection: $selection, searchText: $search,
      actions: SidebarActions(sessions: SessionListActions()),
      tabs: (model.state, model.actions)
    ) { _ in
      content
    }
    .onChange(of: selection) { _, destination in
      if case .session(let id) = destination { model.openChat(id) }
    }
    .focusedSceneValue(\.tabCommands, model.commands)
  }

  @ViewBuilder private var content: some View {
    if model.state.selected != nil {
      TabSplitView(split: model.split, actions: model.actions) { pane in
        if let tab = model.tab(in: pane) { tabContent(tab) }
      }
    } else {
      NewTabPage(state: NewTabPageState(), actions: NewTabPageActions())
    }
  }

  private func tabContent(_ tab: TabItemState) -> some View {
    Group {
      switch tab.kind {
      case .chat:
        ConversationScreen(
          state: PreviewData.shellConversation, composer: PreviewData.sessionComposer,
          draft: .constant(""), showsInspector: .constant(false),
          actions: ConversationActions(), composerActions: ComposerActions(send: {}))
      case .terminal, .agentTerminal:
        SampleTerminal(title: tab.title, isAgent: tab.kind == .agentTerminal)
      case .sideChat:
        SideChatTabView(
          state: SideChatTabState(
            phase: .loaded(
              question: "Why does the refresh test flake on CI?",
              answer: """
                The test waits on a fixed 50 ms timer, but the CI runners are slower. \
                Waiting for the refresh event instead removes the race.
                """),
            sessionTitle: "Refactor token refresh and add tests"),
          openConversation: { model.openChat(PreviewData.sessionID) })
      case .browser, .agentBrowser:
        SamplePage(tab: tab)
      case .remoteBrowser:
        if let remoteBrowser { remoteBrowser } else { SamplePage(tab: tab) }
      case .newTab, .newSession, .inbox, .canvas:
        NewTabPage(
          state: NewTabPageState(
            recentSessions: Array(PreviewData.sessions.prefix(5)), canOpenBrowser: true,
            terminalNames: TabsPlaygroundModel.terminalNames),
          actions: newTabActions)
      }
    }
    .id(tab.id)
  }
}

extension TabsPlayground {
  fileprivate var newTabActions: NewTabPageActions {
    var actions = NewTabPageActions(
      newSession: {},
      newTerminal: { _, name in model.replaceSelected(.terminal, name ?? "zsh") },
      openBrowser: { model.replaceSelected(.browser, "Omnigent") },
      openSession: { model.openChat($0) })
    actions.openRemoteBrowser = { _, _ in model.replaceSelected(.remoteBrowser, "example.com") }
    return actions
  }
}

/// Sample tabs, mutated like the app's tab store.
@Observable
final class TabsPlaygroundModel {
  var tabs: [TabItemState] = [
    TabItemState(
      id: "pinned", kind: .chat, title: "Release checklist", status: .needsYou, isPinned: true),
    TabsPlaygroundModel.chatTab,
    TabItemState(
      id: "agent", kind: .agentTerminal, title: "Refactor token refresh (agent)",
      status: .running, canDuplicate: false),
    TabItemState(
      id: "zsh", kind: .terminal, title: "zsh \u{2014} client-core", subtitle: "Refactor",
      status: .terminalActivity, canDuplicate: false),
    TabItemState(
      id: "side", kind: .sideChat, title: "Why does the refresh test flake?", status: .unread),
    TabItemState(
      id: "docs", kind: .browser, title: "Omnigent Docs", status: .loading, isPlayingAudio: true,
      link: URL(string: "https://omnigent.ai/docs")),
    TabItemState(
      id: "agent-web", kind: .agentBrowser, title: "Agent Browser", subtitle: "Fix flaky SSE",
      isReadOnly: true, canDuplicate: false),
    TabItemState(
      id: "remote-web", kind: .remoteBrowser, title: "example.com", subtitle: "Fix flaky SSE",
      canDuplicate: false),
    TabItemState(id: "new", kind: .newTab, title: "New Tab", canDuplicate: false),
  ]
  /// `OMNIGENT_PLAYGROUND_TAB=<id>` starts on another tab (for example `remote-web`).
  var selectedID: String? = ProcessInfo.processInfo.environment["OMNIGENT_PLAYGROUND_TAB"] ?? "chat"
  /// The split view, when the scenario shows two panes.
  var split: TabSplitState?

  /// The sample tabs, the docs page beside the chat when `split`.
  init(split: Bool = false) {
    tabs = tabs.map(Self.grouped)
    if split { show("docs", in: .trailing) }
    if split { focus(.leading) }
  }

  /// The chats lead their sessions' tabs and cannot close.
  private static func grouped(_ tab: TabItemState) -> TabItemState {
    var tab = tab
    switch tab.id {
    case "pinned": tab.groupID = "release"
    case "chat", "agent", "zsh", "side", "agent-web", "remote-web":
      tab.groupID = PreviewData.sessionID
    default: break
    }
    tab.leadsGroup = tab.kind == .chat
    tab.isClosable = !tab.leadsGroup
    if tab.leadsGroup { tab.canDuplicate = false }
    return tab
  }

  /// Declared terminals: two for the first session, none for the second; the rest unknown.
  static var terminalNames: [String: [String]] {
    let ids = PreviewData.sessions.map(\.id)
    var names: [String: [String]] = [:]
    if let first = ids.first { names[first] = ["zsh", "bash"] }
    if ids.count > 1 { names[ids[1]] = [] }
    return names
  }

  /// The running chat, with the conversation's status line as its tooltip.
  static var chatTab: TabItemState {
    var tab = TabItemState(
      id: "chat", kind: .chat, title: "Refactor token refresh and add tests", status: .running)
    tab.statusDetail = SessionStatusLine(PreviewData.shellConversation).text
    return tab
  }
  var closed: [TabItemState] = []

  var state: TabsState {
    TabsState(
      tabs: tabs, selectedID: selectedID, recentlyClosed: closed.reversed(), split: split)
  }

  var actions: TabActions {
    var actions = TabActions(
      select: select, close: close, newTab: newTab, move: move, setPinned: setPinned,
      duplicate: duplicate, closeOthers: closeOthers, closeToRight: closeToRight)
    if !closed.isEmpty { actions.reopenClosed = reopen }
    actions.moveToNewWindow = close
    addSplit(to: &actions)
    return actions
  }

  var commands: TabCommandActions {
    var commands = TabCommandActions(newTab: newTab, selectTab: select(position:))
    if let selectedID, tabs.first(where: { $0.id == selectedID })?.isClosable == true {
      commands.closeTab = { self.close(selectedID) }
    }
    if !closed.isEmpty { commands.reopenClosedTab = reopen }
    commands.selectNextTab = { self.cycle(1) }
    commands.selectPreviousTab = { self.cycle(-1) }
    commands.count = tabs.count
    addSplit(to: &commands)
    return commands
  }

  func select(_ id: String) {
    if let split, let pane = tabs.first(where: { $0.id == id })?.pane, pane != split.focused {
      focus(pane)
    }
    selectedID = id
    syncSplit()
  }

  func select(position: Int) {
    guard !tabs.isEmpty else { return }
    let index = position >= 8 ? tabs.count - 1 : position
    if tabs.indices.contains(index) { selectedID = tabs[index].id }
  }

  func newTab() {
    add(TabItemState(id: UUID().uuidString, kind: .newTab, title: "New Tab", canDuplicate: false))
  }

  func duplicate(_ id: String) {
    guard var copy = tabs.first(where: { $0.id == id }) else { return }
    copy.id = UUID().uuidString
    add(copy)
  }

  func closeOthers(_ id: String) {
    for tab in tabs where tab.id != id && !tab.isPinned { close(tab.id) }
  }

  func closeToRight(_ id: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    for tab in tabs[(index + 1)...] where !tab.isPinned { close(tab.id) }
  }

  func openChat(_ sessionID: String) {
    let title = PreviewData.sessions.first { $0.id == sessionID }?.title ?? "Session"
    if let existing = tabs.first(where: { $0.kind == .chat && $0.title == title }) {
      selectedID = existing.id
    } else {
      add(TabItemState(id: UUID().uuidString, kind: .chat, title: title))
    }
  }

  func replaceSelected(_ kind: TabKind, _ title: String) {
    guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
    tabs[index].kind = kind
    tabs[index].title = title
  }

  private func add(_ tab: TabItemState) {
    var tab = tab
    tab.pane = split?.focused
    let index = (tabs.firstIndex { $0.id == selectedID }).map { $0 + 1 } ?? tabs.count
    tabs.insert(tab, at: max(index, tabs.count { $0.isPinned }))
    selectedID = tab.id
    syncSplit()
  }

  func close(_ id: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].isClosable else {
      return
    }
    let pane = tabs[index].pane
    closed.append(tabs.remove(at: index))
    leave(id, pane: pane, at: index)
  }

  func reopen() {
    guard let tab = closed.popLast() else { return }
    add(tab)
  }

  func move(_ id: String, to index: Int) {
    guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
    let tab = tabs.remove(at: from)
    let pinned = tabs.count { $0.isPinned }
    let bounds = tab.isPinned ? 0...pinned : pinned...tabs.count
    tabs.insert(tab, at: min(max(index, bounds.lowerBound), bounds.upperBound))
  }

  func setPinned(_ id: String, _ pinned: Bool) {
    guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
    var tab = tabs.remove(at: from)
    tab.isPinned = pinned
    tabs.insert(tab, at: tabs.count { $0.isPinned })
  }

  private func cycle(_ step: Int) {
    guard !tabs.isEmpty else { return }
    let current = tabs.firstIndex { $0.id == selectedID } ?? 0
    selectedID = tabs[(current + step + tabs.count) % tabs.count].id
  }
}

/// A shell's look, for the scenario.
private struct SampleTerminal: View {
  let title: String
  let isAgent: Bool

  var body: some View {
    let lines =
      isAgent
      ? [
        "\u{256D}\u{2500} Claude Code \u{2500}\u{256E}", "> Re-running the expiry test",
        "  \u{2713} cargo test -p omnigent-core refresh (14 passed)",
        "  \u{2026} writing tests/refresh_expiry.rs",
      ]
      : [
        "~/src/omnigent/client-core main", "$ cargo test -p omnigent-core",
        "   Compiling omnigent-core",
        "running 214 tests", "test refresh::expiry ... ok", "$ \u{2588}",
      ]
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        Text(verbatim: line)
      }
      Spacer(minLength: 0)
    }
    .font(.system(.callout, design: .monospaced))
    .foregroundStyle(.primary)
    .padding(Theme.Spacing.large)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // The terminal surface's own dark background (`SessionTerminalView`).
    .background(Color(white: 0.04))
    .environment(\.colorScheme, .dark)
    .navigationTitle(title)
  }
}

/// A web page's look, for the scenario.
private struct SamplePage: View {
  let tab: TabItemState

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Group {
          Image(systemName: "chevron.left")
          Image(systemName: "chevron.right")
          Image(systemName: "arrow.clockwise")
        }
        .accessibilityHidden(true)
        Text(tab.link?.absoluteString ?? "https://example.com")
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Theme.Spacing.small)
          .padding(.vertical, Theme.Spacing.extraSmall)
          .background(ThemeColor.hover, in: Capsule())
      }
      .foregroundStyle(.secondary)
      .padding(Theme.Spacing.small)
      if tab.kind == .agentBrowser {
        Label("The agent is browsing. This view is read-only.", systemImage: "eye")
          .font(.callout)
          .frame(maxWidth: .infinity)
          .padding(Theme.Spacing.small)
          .background(Theme.info.opacity(0.12))
      }
      Divider()
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        Text(tab.title).font(.largeTitle.weight(.semibold))
        Text("Omnigent runs coding agents on your servers and keeps you in the loop.")
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(Theme.Spacing.section)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(.background)
    }
    .navigationTitle(tab.title)
  }
}
