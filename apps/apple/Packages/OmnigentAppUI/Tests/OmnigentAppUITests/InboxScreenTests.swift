import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The Inbox through its rows: opening, answering, marking read and replying.
@MainActor
@Suite("Inbox page", .serialized, .timeLimit(.minutes(1)))
struct InboxScreenTests {
  private final class Opened {
    var sessions: [String] = []
    var files: [String] = []
  }

  private typealias Screen = OffscreenWindow<AnyView>

  // Send in an expanded first row, the failure notice's Retry and the demo question's first option.
  private static let send = CGPoint(x: 905, y: 241)
  private static let retry = CGPoint(x: 899, y: 116)
  private static let firstAnswer = CGPoint(x: 730, y: 579)
  private static let refusal = "You have read-only access to this session."

  private func page(
    _ connection: ConnectionStore, defaults: UserDefaults? = nil
  ) throws -> (Screen, Opened) {
    let opened = Opened()
    let storage = try defaults ?? scratchDefaults()
    let adapter = InboxTriageAdapter(
      connection: connection, open: { opened.sessions.append($0) },
      openFile: { path, _, _ in opened.files.append(path) }, defaults: storage)
    // The store keeps seen comments in the process's defaults; each test starts with none.
    UserDefaults.standard.removeObject(forKey: adapter.seenCommentsKey)
    // The page's filter is remembered; test runs share the standard defaults, so keep it apart.
    let root = AnyView(adapter.defaultAppStorage(storage))
    return (OffscreenWindow(root, width: 1000, height: 800), opened)
  }

  private struct Page {
    let screen: Screen
    let opened: Opened
    let connection: ConnectionStore
  }

  private func demoPage() async throws -> Page {
    let session = try await connectedDemo()
    let connection = session.connection
    let (screen, opened) = try page(connection)
    // Requests list once their conversations have read them; the pinned session then leads.
    try await settle(screen, untilShowing: "Apply the sample design?", contains: true)
    return Page(screen: screen, opened: opened, connection: connection)
  }

  /// A server listing one finished session with unseen output and one with a comment.
  private func inboxServer(hasMore: Bool = false) -> AppServer {
    let server = newSessionServer()
    server.route(
      "/v1/sessions", method: "GET",
      .json(
        #"{"object":"list","data":[{"id":"conv_u","title":"Unread work","status":"idle","created_at":1,"updated_at":50,"permission_level":4,"viewer_read":{"last_seen":10,"unread":false},"viewer_last_seen":10},{"id":"conv_c","title":"Commented","status":"idle","created_at":1,"updated_at":5,"permission_level":4,"comments_count":1,"viewer_last_seen":5}],"has_more":\#(hasMore),"last_id":"conv_c"}"#
      ))
    server.route(
      "/v1/sessions/conv_u/items",
      .json(
        #"{"data":[{"id":"i1","type":"message","role":"assistant","content":[{"type":"output_text","text":"All 24 tests pass."}]}],"has_more":false}"#
      ))
    server.route(
      "/v1/sessions/conv_c/comments",
      .json(
        #"[{"id":"c1","conversation_id":"conv_c","path":"a.rs","start_index":0,"end_index":1,"body":"Why is this here?","status":"draft","created_at":3,"updated_at":3,"created_by":"bob@x"}]"#
      ))
    server.route(
      "/v1/sessions/conv_u/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    server.route("/v1/sessions/conv_u/read-state", method: "PUT", .json("{}", status: 204))
    server.route(
      "/v1/sessions/conv_u",
      .json(
        #"{"id":"conv_u","title":"Unread work","status":"idle","created_at":1,"updated_at":50,"permission_level":4}"#
      ))
    return server
  }

  private func serverPage(_ server: AppServer) async throws -> Page {
    SystemSideEffects.install()
    let connection = try await signedInStore(server)
    try await eventually("the list") { connection.sessionList.isLoaded }
    let (screen, opened) = try page(connection)
    return Page(screen: screen, opened: opened, connection: connection)
  }

  /// The rows, in the order they're listed; the newest comes first and starts expanded.
  private func rowFrames(in screen: Screen) -> [CGRect] {
    screen.controlFrames.filter { $0.width > 860 && $0.width < 870 }
  }

  private func rowMenu(_ index: Int, offering title: String, in screen: Screen) throws -> NSMenu {
    let rows = rowFrames(in: screen)
    try #require(rows.indices.contains(index), "\(screen.controlFrames)")
    let frame = rows[index]
    let menu = try #require(try screen.contextMenu(at: CGPoint(x: frame.midX, y: frame.midY)))
    guard menuTitles(menu).contains(title) else {
      throw OffscreenWindowError.notFound("\(title) in \(menuTitles(menu))")
    }
    return menu
  }

  /// Expands the row and clicks its link: first Open, second Mark as read. A row that leaves the
  /// list can't go through the context menu, whose click stays on the offscreen table.
  private func clickLink(_ index: Int, ofRow row: Int, in screen: Screen) async throws {
    let frame = try #require(rowFrames(in: screen).dropFirst(row).first)
    try screen.click(CGPoint(x: frame.midX, y: frame.midY))
    try await pause(screen)
    let links = screen.controlFrames.filter { $0.height < 20 && $0.minY > frame.minY }
    let link = try #require(links.dropFirst(index).first, "\(screen.controlFrames)")
    try screen.click(CGPoint(x: link.midX, y: link.midY))
    try await pause(screen)
  }

  private func focusReplyField(in screen: Screen) throws {
    let field = try #require(
      screen.allViews.compactMap { $0 as? NSTextField }.first {
        $0.placeholderString?.hasPrefix("Reply to") == true
      })
    screen.window.makeFirstResponder(field)
  }

  @Test("Open session opens the row's session")
  func opening() async throws {
    let page = try await demoPage()
    let screen = page.screen
    let opened = page.opened
    defer { screen.close() }
    try screen.choose(
      "Open session",
      in: rowMenu(0, offering: "Open session", in: screen))
    #expect(opened.sessions == ["demo-design"])
  }

  @Test("Answering a question in its row answers the session's request")
  func answeringInTheRow() async throws {
    let page = try await demoPage()
    let screen = page.screen
    let connection = page.connection
    defer { screen.close() }
    let conversation = try #require(connection.conversations["demo-question"])
    try await settle(screen, until: "the request") { !conversation.decisions.pending.isEmpty }
    try await pause(screen)
    let question = try #require(rowFrames(in: screen).last)
    try screen.click(CGPoint(x: question.midX, y: question.midY))
    try await settle(screen, untilShowing: "Approvals first")
    try screen.click(Self.firstAnswer)
    try await settle(screen, until: "the answer") { conversation.decisions.pending.isEmpty }
  }

  @Test("A session with unseen output previews it; Mark as read tells the server")
  func markingRead() async throws {
    let server = inboxServer()
    let screen = try await serverPage(server).screen
    defer { screen.close() }
    try await settle(screen, untilShowing: "Unread work · ", contains: true)
    try await settle(screen, untilShowing: "All 24 tests pass.", contains: true)
    try screen.choose(
      "Mark as read", in: rowMenu(0, offering: "Mark as read", in: screen))
    try await settle(screen, until: "the read mark") {
      !server.requests("PUT", "/v1/sessions/conv_u/read-state").isEmpty
    }
  }

  @Test("A reply sends what's typed and says so; a refused one says why and editing clears it")
  func replying() async throws {
    let server = inboxServer()
    server.route(
      "/v1/sessions/conv_u/events", method: "POST", .json(#"{"detail":"refused"}"#, status: 403))
    let screen = try await serverPage(server).screen
    defer { screen.close() }
    try await settle(screen, untilShowing: "Unread work · ", contains: true)
    try await settle(screen, untilShowing: "bob@x: Why is this here?")
    try focusReplyField(in: screen)
    try screen.type("ship it")
    try await pause(screen)
    try screen.click(Self.send)
    try await settle(screen, untilShowing: Self.refusal, contains: true)

    try focusReplyField(in: screen)
    try screen.type("ship it!")
    try await settle(screen, until: "the error to clear") {
      (try? screen.shownText().contains { $0.contains(Self.refusal) }) == false
    }

    server.route(
      "/v1/sessions/conv_u/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    try screen.click(Self.send)
    try await settle(screen, untilShowing: "Reply sent to Unread work")
    let bodies = try server.posted("/v1/sessions/conv_u/events")
    #expect("\(bodies.last ?? [:])".contains("ship it!"))
  }

  @Test("Open file shows the comment's file and clears it from the Inbox")
  func openingAComment() async throws {
    let server = inboxServer()
    let page = try await serverPage(server)
    let screen = page.screen
    let opened = page.opened
    let connection = page.connection
    defer { screen.close() }
    try await settle(screen, untilShowing: "bob@x: Why is this here?")
    try await clickLink(0, ofRow: 1, in: screen)
    #expect(opened.files == ["a.rs"])
    #expect(opened.sessions == ["conv_c"])
    #expect(connection.pages?.seenCommentIDs.contains("c1") == true)
  }

  @Test("Mark as read clears a comment on this device")
  func markingACommentRead() async throws {
    let page = try await serverPage(inboxServer())
    let screen = page.screen
    let connection = page.connection
    defer { screen.close() }
    try await settle(screen, untilShowing: "bob@x: Why is this here?")
    try await clickLink(1, ofRow: 1, in: screen)
    #expect(connection.pages?.seenCommentIDs.contains("c1") == true)
    try await settle(screen, until: "the row to leave") {
      (try? screen.shownText().contains { $0.contains("Why is this here?") }) == false
    }
  }

  @Test("A comment read that fails says so, and Retry reads again")
  func retrying() async throws {
    let server = inboxServer()
    server.route("/v1/sessions/conv_c/comments", .json(#"{"detail":"down"}"#, status: 500))
    let screen = try await serverPage(server).screen
    defer { screen.close() }
    try await settle(screen, untilShowing: "Retry")
    server.route(
      "/v1/sessions/conv_c/comments",
      .json(
        #"[{"id":"c1","conversation_id":"conv_c","path":"a.rs","start_index":0,"end_index":1,"body":"Why is this here?","status":"draft","created_at":3,"updated_at":3,"created_by":"bob@x"}]"#
      ))
    try screen.click(Self.retry)
    try await settle(screen, untilShowing: "bob@x: Why is this here?")
  }

  @Test("Marking read keeps a local mark for a waiting session, in this page's defaults")
  func aWaitingRowKeepsALocalMark() async throws {
    let session = try await connectedDemo()
    let connection = session.connection
    connection.notifications?.badge(["demo-question"])
    let defaults = try scratchDefaults()
    let (screen, _) = try page(connection, defaults: defaults)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Apply the sample design?", contains: true)
    try screen.choose("Mark as read", in: rowMenu(1, offering: "Mark as read", in: screen))
    let key = defaults.dictionaryRepresentation().keys.first {
      $0.hasPrefix("omnigent.inbox.read.")
    }
    #expect(key != nil, "the mark must be kept")
    #expect((defaults.dictionary(forKey: key ?? "") as? [String: Double])?.count == 1)
  }

  @Test("Closing the page lets go of the conversations it opened")
  func closingReleases() async throws {
    let page = try await demoPage()
    let screen = page.screen
    let connection = page.connection
    #expect(connection.conversations["demo-question"] != nil)
    screen.close()
    try await pause(screen, .milliseconds(30))
    #expect(connection.conversations["demo-question"] == nil)
  }
}
