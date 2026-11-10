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
    let session: ServerSession
    let selection: WindowSelection
    let chatTabID: String
    let sideChatTabID: String

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
      let session = try await signedInSession(server())
      let selection = WindowSelection(.session(shown))
      let screen = try await titledWindow(session, selection: selection)
      let tabs = session.tabs.group(shown)
      let chat = try #require(tabs.tabs.first)
      tabs.open(.sideChatSession(parentID: shown, childID: hidden))
      try await settle(screen, until: "the side chat") {
        session.connection.conversations[hidden] != nil
      }
      let sideChat = try #require(tabs.selectedID)
      tabs.select(chat.id)
      let window = Self(
        screen: screen, session: session, selection: selection, chatTabID: chat.id,
        sideChatTabID: sideChat)
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

    /// Gives the keyboard to the shown chat's composer: the hidden side chat has an editor too.
    private func focusComposer() throws {
      let editors = screen.allViews.compactMap { $0 as? NSTextView }.filter(\.isEditable)
      let composers = try [Self.shown, Self.hidden].map { try conversation($0).composer }
      for editor in editors {
        _ = screen.window.makeFirstResponder(editor)
        try screen.type("x")
        screen.settle(0.1)
        if !composers[0].text.isEmpty { break }
      }
      try #require(!composers[0].text.isEmpty, "no editor reached the shown chat's composer")
      for composer in composers { composer.text = "" }
    }

    /// Shows `page` the way a sidebar row's click does: the host's selection and the window's
    /// page in one step.
    func choose(_ page: SidebarDestination) {
      selection.page = page
      session.tabs.show(page)
    }

    /// Shows the other sessions in turn until the first one shown is no longer kept open.
    func leaveUntilClosed() throws {
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
      try await pause(screen, .milliseconds(400))
      return try screen.shownText()
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
