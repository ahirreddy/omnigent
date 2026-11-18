import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The Inbox rows and badge of the server's feeds: agent-posted items and automation failures,
/// shown only where `/v1/info` offers them.
@MainActor
@Suite("Inbox feeds mapping")
struct InboxFeedsMappingTests {
  private typealias Fixtures = ConversationFixtures

  private static let itemID = "0123456789abcdef0123456789abcdef"
  private static let item =
    #"{"id":"\#(itemID)","user_id":"local","source_session_id":"s1","agent_id":"a","#
    + #""kind":"reminder","title":"Renew the certificate","body_md":"> It expires Friday","#
    + #""links":[{"type":"session","ref":"s1"},{"type":"url","ref":"https://example.com/c"}],"#
    + #""actions":[{"label":"Renew","prompt":"Renew the certificate"}],"#
    + #""media":[{"type":"chart","chart":{"version":1,"type":"line","title":"Days","#
    + #""x":["a","b"],"series":[{"name":"left","values":[2,1]}],"#
    + #""highlight":{"from":"a","to":"b"},"markers":[{"x":"b","label":"now"}]}}],"#
    + #""primary_link":null,"topic":"t","dedupe_key":"v1:x","status":"unread","#
    + #""resolution":"none","feedback_text":null,"created_at":10,"resolved_at":null,"#
    + #""expires_at":null,"resolution_action":null}"#

  private func connection(offered: Bool) async throws -> ConnectionStore {
    let info =
      offered
      ? #"{"single_user":true,"accounts_enabled":false,"inbox_items_available":true,"scheduled_task_inbox":true}"#
      : #"{"single_user":true,"accounts_enabled":false}"#
    let connection = try await Fixtures.connection(routes: [
      "/v1/info": .json(info),
      "/v1/inbox/items": .json(
        #"{"data":[\#(Self.item)],"next_cursor":null,"unread_count":4,"unread_count_capped":true}"#
      ),
      "/v1/scheduled-tasks/inbox": .json(
        #"{"data":[{"task_id":"t1","task_name":"Nightly","run_id":"r1","scheduled_at":5,"#
          + #""finished_at":20,"error_code":"host_offline"}],"next_cursor":"5:t1"}"#),
    ])
    connection.sessionList.apply(
      .reset(sessions: [Fixtures.summary("s1", updatedAt: 1, title: "Cert rotation")]))
    connection.sessionList.unreadIDs = []
    let pages = try #require(connection.pages)
    await pages.loadOffered()
    await pages.refreshInboxFeeds()
    return connection
  }

  @Test("agent items and failures become rows with their details")
  func rows() async throws {
    let connection = try await connection(offered: true)
    let state = InboxTriageMapping.state(connection: connection, readRevisions: [:])
    let suggestion = try #require(state.items.first { $0.kind == .suggestion })
    #expect(suggestion.id == "suggestion-\(Self.itemID)")
    #expect(suggestion.preview == "It expires Friday")
    #expect(suggestion.isUnread)
    let details = try #require(suggestion.suggestion)
    #expect(details.kindLabel == "Reminder")
    #expect(details.actions == ["Renew"])
    #expect(details.links.map(\.title) == ["Open session", "https://example.com/c"])
    #expect(details.links.first?.sessionID == "s1")
    #expect(details.sourceTitle == "Cert rotation")
    #expect(details.dismissChoices.map(\.title).first == "Already done")
    let chart = try #require(details.charts.first)
    #expect(chart.highlight == 0...1)
    #expect(chart.markers == [1: "now"])

    let failure = try #require(state.items.first { $0.kind == .automationFailure })
    #expect(failure.automationFailure?.automationID == "t1")
    #expect(failure.preview == "Host \u{00B7} The host was offline.")
    #expect(failure.date == Date(timeIntervalSince1970: 20))
    #expect(state.hasMoreAutomations && !state.hasMoreSuggestions)
    #expect(state.unreadSuggestionCount == 4 && state.unreadSuggestionsCapped)
  }

  @Test("a server that offers neither feed lists neither, and they are never read")
  func notOffered() async throws {
    let connection = try await connection(offered: false)
    let state = InboxTriageMapping.state(connection: connection, readRevisions: [:])
    #expect(!state.items.contains { $0.kind == .suggestion || $0.kind == .automationFailure })
  }

  @Test("the badge adds unread agent items and failures, and says when there may be more")
  func badge() async throws {
    let connection = try await connection(offered: true)
    let list = connection.sessionList
    let counts = SidebarAdapter.counts(list.attentionTotals, list: list, pages: connection.pages)
    // One failure and four unread items, capped: "5+".
    #expect(counts.inbox == 5)
    #expect(counts.inboxIsAtLeast)
    #expect(counts.inboxBadge == "5+")

    connection.pages?.feeds.markFailureRead("r1")
    let read = SidebarAdapter.counts(list.attentionTotals, list: list, pages: connection.pages)
    #expect(read.inbox == 4)

    let none = try await self.connection(offered: false)
    let plain = SidebarAdapter.counts(
      none.sessionList.attentionTotals, list: none.sessionList, pages: none.pages)
    #expect(plain.inbox == 0 && plain.inboxBadge == nil)
  }

  @Test("unread sessions count once each; one needing you counts as its approvals")
  func sessionCounts() async throws {
    let connection = try await Fixtures.connection()
    connection.sessionList.apply(
      .reset(sessions: [
        Fixtures.summary("idle", updatedAt: 1),
        Fixtures.summary("waiting", status: .needsResponse, updatedAt: 2, pendingRequests: 2),
      ]))
    connection.sessionList.unreadIDs = ["idle", "waiting"]
    let list = connection.sessionList
    let counts = SidebarAdapter.counts(list.attentionTotals, list: list, pages: nil)
    #expect(SidebarAdapter.approvals(list.attentionTotals) == 2)
    #expect(counts.inbox == 3, "the waiting session's two approvals and the unread idle one")
  }
}
