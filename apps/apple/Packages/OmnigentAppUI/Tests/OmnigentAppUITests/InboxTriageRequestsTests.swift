import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// Requests and comments: the items whose ids and targets come straight from a server.
@MainActor
@Suite("Inbox requests and comments")
struct InboxTriageRequestsTests {
  private typealias Fixtures = ConversationFixtures

  private func card(
    _ id: String, carrying: String = "s", target: String = "s", answered: Bool = false,
    kind: OmnigentCoreFFI.DecisionKind = .approval, detail: String = "Run it"
  ) -> OmnigentCoreFFI.DecisionCard {
    OmnigentCoreFFI.DecisionCard(
      id: id, carryingSessionId: carrying, targetSessionId: target, title: "Title", detail: detail,
      message: nil, toolInput: nil, kind: kind,
      permissions: OmnigentCoreFFI.PermissionOptions(
        allowAllEdits: false, allowAutoMode: false, permissionDirectories: [], rememberLabel: nil,
        plan: nil, command: nil, execPolicyAmendment: nil, persistModes: [], antigravity: nil,
        fileChanges: []),
      phase: nil, policyName: nil, acceptsFeedback: false, answered: answered)
  }

  /// A connection with `sessions` open, each carrying the cards `cards` lists for it.
  private func connection(
    _ sessions: [OmnigentCoreFFI.SessionSummary],
    cards: [String: [OmnigentCoreFFI.DecisionCard]] = [:]
  ) async throws -> ConnectionStore {
    let connection = try await Fixtures.connection()
    connection.sessionList.apply(.reset(sessions: sessions))
    for (session, list) in cards {
      let conversation = try #require(connection.conversation(session))
      conversation.decisions.replace(list)
    }
    return connection
  }

  private func requests(_ connection: ConnectionStore) -> [InboxItem] {
    InboxTriageMapping.state(connection: connection, readRevisions: [:]).items
      .filter { $0.decision != nil }
  }

  @Test("An answer the server refused stays on its card with the reason")
  func aRefusedAnswer() async throws {
    let connection = try await signedInStore(threeSessionServer())
    let conversation = try #require(connection.conversation("conv_a"))
    let request = card("req", carrying: "conv_a", target: "conv_a")
    conversation.decisions.replace([request])
    await conversation.decisions.resolve(request, with: .approve)
    guard
      case .failed(let message) = ConversationAdapter.decisionPhases(conversation.decisions)["req"]
    else {
      Issue.record("the card lost its failure")
      return
    }
    #expect(!message.isEmpty)
  }

  @Test("A request carried by two sessions is listed once, under its target")
  func sharedRequests() async throws {
    let open = try await connection(
      [
        Fixtures.summary("s", updatedAt: 2, title: "Parent"),
        Fixtures.summary("t", updatedAt: 1, title: "Child"),
      ],
      cards: [
        "s": [card("c", carrying: "s", target: "t")],
        "t": [card("c", carrying: "t", target: "t")],
      ])
    let items = requests(open)
    #expect(items.count == 1)
    #expect(items.first?.id == "request-t:c")
    #expect(items.first?.sessionTitle == "Child")
    open.closeConversation("s")
    open.closeConversation("t")
  }

  @Test("A request naming a session that doesn't exist falls back to the one carrying it")
  func targetThatDoesNotExist() async throws {
    let open = try await connection(
      [Fixtures.summary("s", title: "Carrier")], cards: ["s": [card("c", target: "ghost")]])
    #expect(requests(open).first?.sessionId == "s")
    #expect(requests(open).first?.sessionTitle == "Carrier")
    open.closeConversation("s")
  }

  @Test("Repeated and empty request ids don't duplicate or break the list")
  func repeatedIds() async throws {
    let open = try await connection(
      [Fixtures.summary("s")],
      cards: ["s": [card("c"), card("c"), card(""), card("", detail: "")]])
    #expect(requests(open).map(\.id).sorted() == ["request-s:", "request-s:c"])
    open.closeConversation("s")
  }

  @Test("An answered request leaves the inbox; the session is listed on its own merits")
  func answered() async throws {
    let open = try await connection(
      [Fixtures.summary("s", status: .needsResponse)], cards: ["s": [card("c", answered: true)]])
    #expect(requests(open).isEmpty)
    let all = InboxTriageMapping.state(connection: open, readRevisions: [:]).items
    #expect(all.map(\.id) == ["session-s"])
    open.closeConversation("s")
  }

  @Test("A question is a question; a viewer's header makes it read-only")
  func kinds() async throws {
    let open = try await connection(
      [Fixtures.summary("s")],
      cards: ["s": [card("q", kind: .choice(answerKey: "", options: []))]])
    #expect(requests(open).first?.kind == .question)
    #expect(requests(open).first?.isReadOnly == false)
    #expect(requests(open).first?.phase == .pending)
    let conversation = try #require(open.conversations["s"])
    conversation.apply(
      revision: 9,
      change: TranscriptChange(
        rows: [], header: Fixtures.header(readOnly: true), sections: nil))
    #expect(requests(open).first?.isReadOnly == true)
    open.closeConversation("s")
  }

  @Test("Summaries fall back from command to detail to title, and tolerate nothing at all")
  func summaries() {
    func text(
      detail: String, title: String = "Title",
      kind: OmnigentUIComponents.DecisionKind = .approval
    ) -> String {
      InboxTriageMapping.summaryText(
        OmnigentUIComponents.DecisionCard(
          id: "c", carryingSessionId: "s", title: title, detail: detail, kind: kind))
    }
    #expect(text(detail: "Detail") == "Detail")
    #expect(text(detail: "") == "Title")
    #expect(text(detail: "", title: "").isEmpty)
    #expect(text(detail: "", title: "", kind: .form(fields: [])).isEmpty)
    let unnamed = OmnigentUIComponents.FormField(key: "k", title: "", kind: .text)
    #expect(text(detail: "", kind: .form(fields: [unnamed, unnamed])).isEmpty)
  }

  /// A connection whose session `s` has one comment, as `comment` writes it.
  private func commented(
    _ comment: String, session: OmnigentCoreFFI.SessionSummary? = nil,
    // swiftlint:disable:next discouraged_optional_collection
    listed: [OmnigentCoreFFI.SessionSummary]? = nil
  ) async throws -> ConnectionStore {
    let connection = try await Fixtures.connection(routes: [
      "/v1/sessions/s/comments": .json("[\(comment)]")
    ])
    let source = session ?? Fixtures.summary("s", commentsCount: 1)
    connection.sessionList.apply(.reset(sessions: listed ?? [source]))
    await connection.pages?.refreshComments([source])
    return connection
  }

  private func comment(
    id: String = "c1", createdAt: String = "3", author: String? = "bob@x"
  ) -> String {
    let createdBy = author.map { #","created_by":"\#($0)""# } ?? ""
    return #"""
      {"id":"\#(id)","conversation_id":"s","path":"a.rs","start_index":0,"end_index":1,"body":"Why?","status":"draft","created_at":\#(createdAt),"updated_at":3\#(createdBy)}
      """#
  }

  private func comments(_ connection: ConnectionStore) -> [InboxItem] {
    InboxTriageMapping.state(connection: connection, readRevisions: [:]).items
      .filter { $0.kind == .comment }
  }

  @Test("A comment names its author; the core leaves out one without an author")
  func commentItems() async throws {
    let named = try await commented(comment())
    let item = try #require(comments(named).first)
    #expect(item.preview == "bob@x: Why?")
    #expect(InboxTriageMapping.commentID(item) == "c1")

    let anonymous = try await commented(comment(author: nil))
    #expect(comments(anonymous).isEmpty)
  }

  @Test("Comments on an archived or unlisted session aren't listed")
  func commentsWithoutASession() async throws {
    let source = Fixtures.summary("s", commentsCount: 1)
    #expect(comments(try await commented(comment(), session: source, listed: [])).isEmpty)
    let archived = Fixtures.summary("s", isArchived: true, commentsCount: 1)
    #expect(comments(try await commented(comment(), session: source, listed: [archived])).isEmpty)
  }

  @Test("A comment's timestamp may be either end of the 64-bit range")
  func commentTimes() async throws {
    for createdAt in [Int64.min, Int64.max, 0] {
      let listed = try await commented(comment(createdAt: String(createdAt)))
      let item = try #require(comments(listed).first)
      #expect(item.date == Date(timeIntervalSince1970: TimeInterval(createdAt)))
    }
  }

  @Test("Only a comment item with the prefix names a comment")
  func commentIDs() {
    func item(id: String, kind: InboxItem.Kind) -> InboxItem {
      InboxItem(
        id: id, kind: kind, sessionId: "s", sessionTitle: "", preview: "", date: .distantPast)
    }
    #expect(InboxTriageMapping.commentID(item(id: "comment-", kind: .comment))?.isEmpty == true)
    #expect(InboxTriageMapping.commentID(item(id: "comment-x-y", kind: .comment)) == "x-y")
    #expect(InboxTriageMapping.commentID(item(id: "other", kind: .comment)) == nil)
    #expect(InboxTriageMapping.commentID(item(id: "comment-x", kind: .unread)) == nil)
    #expect(InboxTriageMapping.commentID(item(id: "", kind: .comment)) == nil)
  }
}
