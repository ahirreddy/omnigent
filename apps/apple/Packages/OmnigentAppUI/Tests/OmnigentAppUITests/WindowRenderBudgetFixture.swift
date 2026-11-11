import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores
@testable import OmnigentUIComponents

#if DEBUG
  /// The mounted window the render budgets are measured in: Alpha's chat shown with a reply
  /// streaming, a side chat on Beta kept built behind it, and Gamma and Delta only in the sidebar.
  @MainActor
  struct BudgetWindow {
    let screen: OffscreenWindow<AppWindowRoot>
    let server: AppServer
    /// The window's own preferences: no other test, in this process or another, writes them.
    let preferences: UserDefaults
    let session: ServerSession
    let selection: WindowSelection
    let chatTabID: String
    let sideChatTabID: String
    /// What a step measured before it ran, for its check afterwards.
    let notes = BudgetNotes()

    static let shown = "conv_a"
    static let hidden = "conv_b"
    static let other = "conv_c"
    static let another = "conv_d"
    static let titles = [shown: "Alpha", hidden: "Beta", other: "Gamma", another: "Delta"]
    /// The streaming reply's row in Alpha's transcript.
    static let streamIndex: UInt32 = 2

    var list: SessionListStore { session.connection.sessionList }
    var tabs: TabStore { session.tabs.group(Self.shown) }
    var title: String { screen.window.title }

    func conversation(_ sessionID: String) throws -> ConversationStore {
      try #require(session.connection.conversations[sessionID])
    }

    /// The composer's editor, which holds the keyboard.
    var editor: NSTextView? { screen.window.firstResponder as? NSTextView }

    /// How long ago each session was last active, in minutes: its row's time until it changes.
    static let minutesAgo: [String: Int64] = [shown: 3, hidden: 4, other: 6, another: 8]

    /// A time `minutes` ago that reads as that many minutes for the next half minute.
    static func time(minutesAgo minutes: Int64) -> Int64 {
      Int64(Date().timeIntervalSince1970) - minutes * 60 - 20
    }

    /// A server with the titled sessions on one online host.
    private static func server() -> AppServer {
      let server = newSessionServer()
      let rows = titles.keys.sorted().map { id in
        let updated = time(minutesAgo: minutesAgo[id, default: 0])
        let row = sessionRow(id, host: "mac", workspace: "/work/\(id)", updatedAt: updated)
        return (id, #"{"title":"\#(titles[id, default: ""])","# + row.dropFirst())
      }
      let list = rows.map(\.1).joined(separator: ",")
      server.route(
        "/v1/sessions", method: "GET",
        .json(#"{"object":"list","data":[\#(list)],"has_more":false}"#))
      for (id, row) in rows { server.route("/v1/sessions/\(id)", .json(row)) }
      return server
    }

    static func open() async throws -> Self {
      let server = server()
      let preferences = try scratchDefaults()
      let session = try await signedInSession(server)
      let selection = WindowSelection(.session(shown))
      let screen = try await titledWindow(session, selection: selection, preferences: preferences)
      let tabs = session.tabs.group(shown)
      let chat = try #require(tabs.tabs.first)
      tabs.open(.sideChatSession(parentID: shown, childID: hidden))
      try await settle(screen, until: "the side chat") {
        session.connection.conversations[hidden] != nil
      }
      let sideChat = try #require(tabs.selectedID)
      tabs.select(chat.id)
      let window = Self(
        screen: screen, server: server, preferences: preferences, session: session,
        selection: selection, chatTabID: chat.id, sideChatTabID: sideChat)
      try window.feed(shown, reply: "Alpha reply", streaming: true)
      try window.feed(hidden, reply: "Beta reply", streaming: false)
      try await pause(screen, .milliseconds(400))
      try window.focusComposer()
      try await pause(screen, .milliseconds(200))
      return window
    }

    /// A question and its reply in `sessionID`'s transcript.
    func feed(_ sessionID: String, reply: String, streaming: Bool) throws {
      let store = try conversation(sessionID)
      let rows = [
        ConversationFixtures.userRow("u1", text: "Question"),
        ConversationFixtures.userRow("a1", text: "Earlier answer", role: .assistant),
        Self.reply(reply, streaming: streaming),
      ]
      let inserts = rows.enumerated().map {
        RowOp.insert(index: UInt32($0.offset), row: $0.element)
      }
      store.apply(
        revision: store.revision + 1,
        change: TranscriptChange(rows: inserts, header: nil, sections: nil))
      store.hydrated()
    }

    static func reply(_ text: String, streaming: Bool) -> OmnigentCoreFFI.Row {
      var row = ConversationFixtures.userRow("stream", text: text, role: .assistant)
      row.isStreaming = streaming
      return row
    }

    /// Gives the keyboard to `sessionID`'s composer: every chat kept built has an editor too.
    func focusComposer(of sessionID: String = shown) throws {
      let editors = screen.allViews.compactMap { $0 as? NSTextView }.filter(\.isEditable)
      let composers = session.connection.conversations.values.map(\.composer)
      let wanted = try conversation(sessionID).composer
      for editor in editors {
        _ = screen.window.makeFirstResponder(editor)
        try screen.type("x")
        screen.settle(0.1)
        if !wanted.text.isEmpty { break }
      }
      try #require(!wanted.text.isEmpty, "no editor reached \(sessionID)'s composer")
      for composer in composers { composer.text = "" }
    }

    /// Selects the sidebar row that draws `title` in the sidebar's own list, as a click on it
    /// does: the list writes the selection it was given.
    func chooseSidebarRow(_ title: String) throws {
      try sidebarList().selectRowIndexes(
        IndexSet(integer: try sidebarRow(title)), byExtendingSelection: false)
    }

    private func sidebarList() throws -> NSTableView {
      try #require(screen.allViews.lazy.compactMap { $0 as? NSTableView }.first)
    }

    /// Where the sidebar's own list draws `title`, counted from its top.
    func sidebarRow(_ title: String) throws -> Int {
      let list = try sidebarList()
      let row = try (0..<list.numberOfRows).first { row in
        guard let view = list.rowView(atRow: row, makeIfNecessary: false) else { return false }
        return try screen.shownText(under: view).contains(title)
      }
      return try #require(row, "no sidebar row \(title)")
    }

    /// The sessions whose changed files the server was asked for since the step's note.
    func changesAsked() -> [String] {
      let asked = server.http.requests.dropFirst(notes.requests).map(\.url)
      return Self.titles.keys.sorted().filter { sessionID in
        asked.contains {
          $0.hasSuffix("/v1/sessions/\(sessionID)/resources/environments/default/changes")
        }
      }
    }

    /// Chooses `sessionID`'s row in the sidebar.
    func choose(session sessionID: String) throws {
      try chooseSidebarRow(Self.titles[sessionID, default: sessionID])
    }

    /// Shows the other sessions in turn until the first one shown is no longer kept open, in a
    /// window that keeps three open: the fixture has too few sessions for a Mac's limit.
    func leaveUntilClosed() throws {
      session.tabs.liveLimit = 3
      for sessionID in [Self.other, Self.another, Self.hidden] {
        selection.page = .session(sessionID)
        screen.settle(0.3)
      }
      try #require(session.connection.conversations[Self.shown] == nil, "still open")
    }

    /// Replaces the reply `sessionID`'s transcript ends on, as its next delta does.
    func stream(_ text: String, in sessionID: String, streaming: Bool = true) throws {
      let store = try conversation(sessionID)
      let update = RowOp.update(
        index: Self.streamIndex, row: Self.reply(text, streaming: streaming))
      store.apply(
        revision: store.revision + 1,
        change: TranscriptChange(rows: [update], header: nil, sections: nil))
    }

    /// What the window draws once `reply` arrives in `sessionID`'s transcript.
    func text(afterReply reply: String, in sessionID: String) async throws -> [String] {
      if try conversation(sessionID).rows.isEmpty {
        try feed(sessionID, reply: reply, streaming: false)
      } else {
        try stream(reply, in: sessionID, streaming: false)
      }
      try await settleUntilQuiet()
      return try screen.shownText()
    }

    /// The sidebar's row under its sessions while their next page loads.
    func showLoadingMore() throws {
      list.paging.pagingChanged(hasMore: true, isLoading: true)
      screen.settle(0.2)
      let text = try screen.shownText()
      try #require(text.contains("Loading\u{2026}"), "no row for the page that is loading: \(text)")
    }

    /// Changes `sessionID`'s row the way the server's next list event would.
    func change(_ sessionID: String, _ edit: (inout OmnigentCoreFFI.SessionSummary) -> Void) throws
    {
      var row = try #require(list.session(sessionID))
      edit(&row)
      list.apply(.upsert(sessions: [row]))
    }

    /// Activity in `sessionID` that leaves its title alone: a new preview, last active `minutes` ago.
    func activity(in sessionID: String, minutesAgo minutes: Int64) throws {
      try change(sessionID) { row in
        row.preview = "Working \(minutes)"
        row.updatedAt = Self.time(minutesAgo: minutes)
      }
    }
  }
#endif
