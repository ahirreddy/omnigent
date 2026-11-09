import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

@MainActor
@Suite("Inbox triage mapping")
struct InboxTriageMappingTests {
  private typealias Fixtures = ConversationFixtures

  /// A connection listing `sessions`, every one of them unread unless `unread` says otherwise.
  private func connection(
    // swiftlint:disable:next discouraged_optional_collection
    _ sessions: [OmnigentCoreFFI.SessionSummary], unread: Set<String>? = nil,
    routes: [String: HttpResponse] = [:]
  ) async throws -> ConnectionStore {
    let connection = try await Fixtures.connection(routes: routes)
    connection.sessionList.apply(.reset(sessions: sessions))
    connection.sessionList.unreadIDs = unread ?? Set(sessions.map(\.id))
    return connection
  }

  private func state(_ connection: ConnectionStore, reads: [String: Double] = [:])
    -> InboxViewState
  {
    InboxTriageMapping.state(connection: connection, readRevisions: reads)
  }

  @Test("Sessions list newest first at the ends of the 64-bit range, ties by id")
  func extremeTimestamps() async throws {
    let inbox = state(
      try await connection([
        Fixtures.summary("min", updatedAt: .min), Fixtures.summary("max", updatedAt: .max),
        Fixtures.summary("b", updatedAt: 5), Fixtures.summary("a", updatedAt: 5),
      ]))
    #expect(inbox.items.map(\.sessionId) == ["max", "a", "b", "min"])
    #expect(inbox.items.first?.date == Date(timeIntervalSince1970: TimeInterval(Int64.max)))
    #expect(inbox.items.last?.date == Date(timeIntervalSince1970: TimeInterval(Int64.min)))
  }

  @Test("A read mark hides an item only when it is a real time at or after the item's")
  func readMarks() async throws {
    let session = Fixtures.summary("s", status: .needsResponse, updatedAt: 100)
    let listed = try await connection([session], unread: [])
    listed.notifications?.badge(["s"])
    let id = "session-s"
    // swiftlint:disable:next discouraged_optional_boolean
    func isUnread(_ read: Double) -> Bool? {
      state(listed, reads: [id: read]).items.first?.isUnread
    }
    #expect(isUnread(.nan) == true)
    #expect(isUnread(99) == true)
    #expect(isUnread(-.infinity) == true)
    #expect(isUnread(100) == false)
    #expect(isUnread(.infinity) == false)
    // A mark for an item that doesn't exist changes nothing.
    #expect(state(listed, reads: ["session-gone": 1e300]).items.first?.isUnread == true)
  }

  @Test("A session is listed only when it waits on the user or has unseen output")
  func whatIsListed() async throws {
    let inbox = state(
      try await connection(
        [
          Fixtures.summary("quiet"), Fixtures.summary("waiting", status: .needsResponse),
          Fixtures.summary("unread"), Fixtures.summary("archived", isArchived: true),
        ], unread: ["unread", "archived", "not-in-the-list"]))
    #expect(Set(inbox.items.map(\.sessionId)) == ["waiting", "unread"])
    #expect(inbox.items.first { $0.sessionId == "waiting" }?.kind == .approval)
    #expect(inbox.items.first { $0.sessionId == "unread" }?.kind == .unread)
  }

  @Test("An unread failure reads as its message; only a writer may answer in place")
  func unreadFailures() async throws {
    let inbox = state(
      try await connection([
        Fixtures.summary("failed", preview: "Failed", failureMessage: "Out of disk"),
        Fixtures.summary("kept", preview: "Partial", failureMessage: ""),
        Fixtures.summary("reader", isReadOnly: true),
      ]))
    let failed = try #require(inbox.items.first { $0.sessionId == "failed" })
    #expect(failed.preview == "Out of disk")
    #expect(failed.isError)
    #expect(failed.canReply)
    let kept = try #require(inbox.items.first { $0.sessionId == "kept" })
    #expect(kept.preview == "Partial")
    #expect(kept.isError)
    #expect(inbox.items.first { $0.sessionId == "reader" }?.canReply == false)
  }

  @Test("Enormous fields and counts pass through")
  func enormousFields() async throws {
    let long = String(repeating: "\u{1F600}a", count: 200_000)
    let inbox = state(
      try await connection([
        Fixtures.summary(
          long, status: .needsResponse, title: long, preview: long, workspace: long,
          pendingRequests: .max, commentsCount: .max),
        Fixtures.summary("other", status: .needsResponse, pendingRequests: .max),
      ]))
    #expect(inbox.items.count == 2)
    #expect(inbox.items.contains { $0.sessionTitle == long })
    #expect(inbox.needsYouCount == 2)
  }

  @Test("A host id no catalog names still reads; an empty workspace is left out")
  func executionContext() async throws {
    let configuration = Fixtures.configuration()
    let inbox = state(
      try await connection([Fixtures.summary("s", configuration: configuration)]))
    #expect(inbox.items.first?.executionContext.hasSuffix(" · Host host") == true)
    #expect(inbox.items.first?.executionContext.contains("Local Omnigent") == true)
    #expect(inbox.items.first?.executionContext.contains(" ·  ") == false)
  }

  @Test("A failed send is the item's reply phase and keeps it listed")
  func replyPhases() async throws {
    let session = Fixtures.summary("s")
    let listed = try await connection([session], unread: [])
    #expect(state(listed).items.isEmpty)
    let pages = try #require(listed.pages)
    #expect(!(await pages.reply("hello", to: session)))
    let item = try #require(state(listed).items.first)
    guard case .failed = item.reply else {
      Issue.record("expected a failed reply, got \(item.reply)")
      return
    }
    #expect(item.isUnread)
    pages.clearReply("s")
    #expect(state(listed).items.isEmpty)
  }

  @Test("A session whose output can't be read keeps its preview and counts as failed")
  func unreadableOutput() async throws {
    let unread = Fixtures.summary("unread", preview: "old")
    let listed = try await connection([unread])
    await listed.pages?.refreshLatestOutputs([unread])
    let after = state(listed)
    #expect(after.failedSessionCount == 1)
    #expect(after.items.first?.preview == "old")
  }

  @Test("Duplicate session ids keep one row")
  func duplicateSessions() async throws {
    let inbox = state(
      try await connection([
        Fixtures.summary("same", updatedAt: 1, title: "first"),
        Fixtures.summary("same", updatedAt: 2, title: "second"),
      ]))
    #expect(inbox.items.map(\.sessionId) == ["same"])
  }

  @Test("The list is assembling until it loads, and while a waiting session reads")
  func assembling() async throws {
    let empty = try await Fixtures.connection()
    #expect(!InboxTriageMapping.isAssembling(empty))
    #expect(InboxTriageMapping.isAssembling(ConnectionStore(core: try await Fixtures.core())))

    let waiting = try await connection(
      [Fixtures.summary("s", status: .needsResponse, pendingRequests: 1)], unread: [])
    #expect(!InboxTriageMapping.isAssembling(waiting))
    let conversation = try #require(waiting.conversation("s"))
    // Nothing has been read yet, since this test hasn't yielded to the core.
    #expect(InboxTriageMapping.isAssembling(waiting))
    conversation.record(.InvalidState(message: "unreadable"))
    #expect(!InboxTriageMapping.isAssembling(waiting))
    #expect(state(waiting).items.first?.preview == "unreadable")
    waiting.closeConversation("s")
  }
}
