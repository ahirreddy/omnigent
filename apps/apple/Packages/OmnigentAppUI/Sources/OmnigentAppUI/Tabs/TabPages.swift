import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTerminalUI
import OmnigentUIComponents
import SwiftUI

/// A user shell in a tab. The surface lives in the session's ``TerminalStore``, so switching
/// tabs keeps its screen and scrollback. It attaches once the conversation header has the
/// caller's permission level (below owner attaches read-only).
struct TerminalTabView: View {
  let session: ServerSession
  let sessionID: String
  let terminalID: String
  let showChat: @MainActor () -> Void

  @State private var surface: TerminalSurfaceController?
  @Environment(\.isActiveTabPane) private var isActivePane

  private var store: TerminalStore? { session.terminals(of: sessionID) }
  private var header: OmnigentCoreFFI.SessionHeader? {
    session.connection.openConversation(sessionID)?.header
  }

  var body: some View {
    Group {
      if let surface {
        SessionTerminalView(controller: surface)
      } else if let store, let error = store.lastError {
        ContentUnavailableView(
          "Terminal Unavailable", systemImage: "exclamationmark.triangle",
          description: Text(String(describing: error)))
      } else if store?.terminals.rows.isEmpty == false, row == nil {
        ContentUnavailableView(
          "Terminal Closed", systemImage: "terminal",
          description: Text("This terminal is no longer running in the session."))
      } else {
        ProgressView("Attaching the terminal\u{2026}")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .modifier(TerminalPageFocus(surface: surface))
    .navigationTitle(row?.terminal.displayLabel ?? "Terminal")
    .navigationSubtitle(sessionTitle)
    .toolbar {
      if isActivePane {
        ToolbarItem(placement: .primaryAction) {
          Button("Show Chat", systemImage: TabKind.chat.systemImage, action: showChat)
            .help("Show this session's chat")
            .accessibilityIdentifier("terminal-tab-chat")
        }
      }
    }
    // A shell is not the session's terminal view, so Option-Command-\\ stays with the chat.
    .onAppear { store?.terminals.refresh() }
    .onChange(of: header?.permissionLevel, initial: true) { attach() }
    .onChange(of: store == nil) { attach() }
    .accessibilityIdentifier("terminal-tab")
  }

  private var row: TerminalRow? {
    store?.terminals.rows.first { $0.terminal.id == terminalID }
  }

  private var sessionTitle: String {
    session.connection.sessionList.sessionWithoutActivity(sessionID)?.title ?? ""
  }

  private func attach() {
    guard surface == nil, let store, let header else { return }
    surface = store.controller(
      for: terminalID, permissionLevel: header.permissionLevel, hostID: header.settings?.hostId)
  }
}

/// A side question from the transcript in its own tab.
struct SideChatTabContainer: View {
  let session: ServerSession
  let sessionID: String
  let rowID: String
  let showChat: @MainActor () -> Void

  var body: some View {
    SideChatTabView(state: state, openConversation: showChat)
  }

  private var state: SideChatTabState {
    let title =
      session.connection.sessionList.sessionWithoutActivity(sessionID)?.title ?? "the conversation"
    guard let conversation = session.connection.openConversation(sessionID) else {
      return SideChatTabState(phase: .loading, sessionTitle: title)
    }
    // The watched row alone: reading `rows` would re-render this tab for every streamed delta.
    guard let activity = conversation.watchRow(rowID).row?.activity else {
      return SideChatTabState(
        phase: conversation.header == nil ? .loading : .unavailable, sessionTitle: title)
    }
    let question = Self.detail("question", in: activity) ?? activity.summary
    return SideChatTabState(
      phase: .loaded(question: question, answer: Self.detail("answer", in: activity)),
      sessionTitle: title)
  }

  static func detail(_ id: String, in activity: OmnigentCoreFFI.Activity) -> String? {
    activity.details.first { $0.id == id }?.text
  }
}

/// A browser tab: the browser host's page, or why there is none.
struct BrowserTabContainer: View {
  let host: (any BrowserTabHosting)?
  let tab: AppTab
  let browserID: UUID
  let navigation: BrowserTabNavigation
  let changed: @MainActor () -> Void

  var body: some View {
    if let host {
      host.content(
        for: browserID, restoring: tab.browserState, navigation: navigation, onChange: changed
      )
      .id(browserID)
    } else {
      ContentUnavailableView(
        "Browser Unavailable", systemImage: "globe",
        description: Text("This build of the app has no browser."))
    }
  }
}

/// An agent's browser for a session, read-only.
struct AgentBrowserTabContainer: View {
  let host: (any BrowserTabHosting)?
  let sessionID: String
  let showChat: @MainActor () -> Void

  var body: some View {
    if let content = host?.agentContent(for: sessionID) {
      content
    } else {
      ContentUnavailableView {
        Label("No Agent Browser", systemImage: TabKind.agentBrowser.systemImage)
      } description: {
        Text("Pages the agent opens for this session appear here while it browses.")
      } actions: {
        Button("Show Chat", action: showChat)
      }
    }
  }
}
