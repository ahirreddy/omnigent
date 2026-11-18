import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Agent-posted Inbox items and automation failures: what loads, what a change shows at once,
/// and what a refusal puts back.
@MainActor
@Suite("Inbox feeds", .timeLimit(.minutes(1)))
struct InboxFeedsStoreTests {
  private static let first = "0123456789abcdef0123456789abcdef"
  private static let second = "fedcba9876543210fedcba9876543210"

  private static func item(_ id: String, status: String = "unread", extra: String = "") -> String {
    #"{"id":"\#(id)","user_id":"local","source_session_id":"\#(second)","agent_id":"a","#
      + #""kind":"followup","title":"Title \#(id.prefix(4))","body_md":"Body","links":[],"#
      + #""actions":[{"label":"Do it","prompt":"Do the thing"}],"media":[],"#
      + #""primary_link":null,"topic":"t","dedupe_key":"v1:x","status":"\#(status)","#
      + #""resolution":"none","feedback_text":null,"created_at":10,"resolved_at":null,"#
      + #""expires_at":null,"resolution_action":null\#(extra)}"#
  }

  private func feeds(_ server: RouteServer) async throws -> InboxFeedsStore {
    let store = try await connectedStore(server)
    return try #require(store.pages?.feeds)
  }

  private func page(_ items: [String], cursor: String? = nil, unread: Int = 2) -> String {
    let next = cursor.map { #""\#($0)""# } ?? "null"
    return #"{"data":[\#(items.joined(separator: ","))],"next_cursor":\#(next),"#
      + #""unread_count":\#(unread),"unread_count_capped":false}"#
  }

  @Test("items load, page by cursor, and keep the server's unread total")
  func loadsAndPages() async throws {
    let server = RouteServer()
    server.route(
      "/v1/inbox/items",
      .json(page([Self.item(Self.first)], cursor: "10:\(Self.first)", unread: 7)))
    let feeds = try await feeds(server)
    await feeds.refreshItems()
    #expect(feeds.items.map(\.id) == [Self.first])
    #expect(feeds.unreadCount == 7 && feeds.hasMoreItems && feeds.itemsLoaded)

    server.route("/v1/inbox/items", .json(page([Self.item(Self.second, status: "read")])))
    await feeds.loadMoreItems()
    #expect(feeds.items.map(\.id) == [Self.first, Self.second])
    #expect(!feeds.hasMoreItems)
    let asked = try #require(server.requests(to: "/v1/inbox/items").last?.url)
    #expect(asked.contains("after=10%3A\(Self.first)") || asked.contains("after=10:\(Self.first)"))

    server.fail("/v1/inbox/items", status: 500)
    await feeds.refreshItems()
    #expect(feeds.itemsError != nil)
    #expect(feeds.items.count == 2, "a failed read keeps what showed")
  }

  @Test("reading shows at once; a refusal puts the item and count back")
  func markRead() async throws {
    let server = RouteServer()
    server.route("/v1/inbox/items", .json(page([Self.item(Self.first)], unread: 1)))
    let feeds = try await feeds(server)
    await feeds.refreshItems()

    server.fail("/v1/inbox/items/\(Self.first)", method: "PATCH", status: 500)
    await feeds.markRead(Self.first)
    #expect(feeds.items.first?.isUnread == true)
    #expect(feeds.unreadCount == 1)
    #expect(feeds.itemWriteError != nil)

    server.route(
      "/v1/inbox/items/\(Self.first)", method: "PATCH",
      .json(
        Self.item(
          Self.first, status: "read", extra: #","unread_count":0,"unread_count_capped":false"#)
      ))
    await feeds.markRead(Self.first)
    #expect(feeds.items.first?.isUnread == false)
    #expect(feeds.unreadCount == 0)
    #expect(feeds.itemWriteError == nil)
    let sent = try #require(server.requests(to: "/v1/inbox/items/\(Self.first)").last)
    #expect(try server.body(of: sent)["status"] as? String == "read")
  }

  @Test("an action or a dismissal takes the item out; a refusal brings it back")
  func resolve() async throws {
    let server = RouteServer()
    server.route(
      "/v1/inbox/items", .json(page([Self.item(Self.first), Self.item(Self.second)], unread: 2)))
    let feeds = try await feeds(server)
    await feeds.refreshItems()

    server.fail("/v1/inbox/items/\(Self.first)", method: "PATCH", status: 400)
    #expect(await !feeds.takeAction(Self.first, index: 0))
    #expect(feeds.items.map(\.id) == [Self.first, Self.second])
    #expect(feeds.unreadCount == 2)

    server.route(
      "/v1/inbox/items/\(Self.first)", method: "PATCH",
      .json(
        Self.item(
          Self.first, status: "done", extra: #","unread_count":1,"unread_count_capped":false"#)
      ))
    #expect(await feeds.takeAction(Self.first, index: 0))
    #expect(feeds.items.map(\.id) == [Self.second])
    #expect(feeds.unreadCount == 1)
    let action = try #require(server.requests(to: "/v1/inbox/items/\(Self.first)").last)
    #expect(try server.body(of: action)["resolution"] as? String == "action_taken")
    #expect(try server.body(of: action)["resolution_action"] as? Int == 0)

    server.route(
      "/v1/inbox/items/\(Self.second)", method: "PATCH",
      .json(
        Self.item(
          Self.second, status: "dismissed", extra: #","unread_count":0,"unread_count_capped":false"#
        )
      ))
    #expect(await feeds.dismiss(Self.second, reason: .notRelevant))
    #expect(feeds.items.isEmpty)
    let dismissal = try #require(server.requests(to: "/v1/inbox/items/\(Self.second)").last)
    #expect(try server.body(of: dismissal)["resolution"] as? String == "not_relevant")
  }

  @Test("failures show once per automation, and a run marked read stays read on this device")
  func failures() async throws {
    let server = RouteServer()
    server.route(
      "/v1/scheduled-tasks/inbox",
      .json(
        #"{"data":[{"task_id":"t1","task_name":"Nightly","run_id":"r1","scheduled_at":5,"#
          + #""finished_at":9,"error_code":"host_offline"}],"next_cursor":"5:t1"}"#))
    let defaults = try #require(UserDefaults(suiteName: "feeds-\(UUID())"))
    let store = try await connectedStore(server)
    let feeds = InboxFeedsStore(core: try #require(store.core), defaults: defaults)
    feeds.bindReadFailures(key: "runs")
    await feeds.refreshFailures()
    #expect(feeds.unreadFailures.map(\.runId) == ["r1"])
    #expect(feeds.unreadFailures.first?.reason == "Host \u{00B7} The host was offline.")
    #expect(feeds.hasMoreFailures)

    // An empty page can still continue: the cursor walks automations.
    server.route("/v1/scheduled-tasks/inbox", .json(#"{"data":[],"next_cursor":null}"#))
    await feeds.loadMoreFailures()
    #expect(!feeds.hasMoreFailures)
    #expect(feeds.failures.count == 1)

    feeds.markFailureRead("r1")
    #expect(feeds.unreadFailures.isEmpty)
    let again = InboxFeedsStore(core: try #require(store.core), defaults: defaults)
    again.bindReadFailures(key: "runs")
    #expect(again.readRunIDs == ["r1"], "the mark outlives the store")
  }

  @Test("only the newest thousand read runs are kept")
  func readRunLimit() async throws {
    let store = try await connectedStore(RouteServer())
    let defaults = try #require(UserDefaults(suiteName: "feeds-\(UUID())"))
    let feeds = InboxFeedsStore(core: try #require(store.core), defaults: defaults)
    feeds.bindReadFailures(key: "runs")
    for index in 0...InboxFeedsStore.readRunLimit { feeds.markFailureRead("r\(index)") }
    #expect(feeds.readRunIDs.count == InboxFeedsStore.readRunLimit)
    #expect(!feeds.readRunIDs.contains("r0"))
    #expect(feeds.readRunIDs.contains("r\(InboxFeedsStore.readRunLimit)"))
  }
}
