import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// Goals and Plan mode from the composer's Add menu.
@MainActor
@Suite("Goal and plan actions", .timeLimit(.minutes(1)))
struct GoalAndPlanActionsTests {
  private typealias Fixtures = ConversationFixtures
  private let goal =
    #"{"goal":{"thread_id":"t","objective":"Ship it","status":"active","token_budget":40000,"tokens_used":1200,"time_used_seconds":180}}"#

  private func codexStore(_ server: AppServer) async throws -> ConversationStore {
    let connection = try await signedInStore(server)
    let store = ConversationStore(sessionID: "conv", core: try #require(connection.core))
    store.apply(
      revision: 1,
      change: TranscriptChange(
        rows: [],
        header: Fixtures.header(
          settings: Fixtures.settings(harness: "codex-native", wrapper: "codex-native-ui")),
        sections: [Fixtures.section("collaboration", summary: "Plan")]))
    store.hydrated()
    return store
  }

  private func server() -> AppServer {
    let server = AppServer()
    server.route("/v1/sessions/conv/codex_goal", method: "GET", .json(#"{"goal":null}"#))
    server.route("/v1/sessions/conv/codex_goal", method: "PUT", .json(goal))
    server.route(
      "/v1/sessions/conv/codex_goal", method: "DELETE", .json(#"{"cleared":true}"#))
    server.route(
      "/v1/sessions/conv", method: "PATCH",
      .json(#"{"id":"conv","status":"idle","created_at":1,"labels":{}}"#))
    return server
  }

  @Test("Saving a new goal starts it and closes the sheet; Clear ends it and closes it too")
  func managedGoal() async throws {
    let server = server()
    let store = try await codexStore(server)
    final class Dismissed { var count = 0 }
    let dismissed = Dismissed()
    let actions = SessionToolsAdapter.goalActions(
      store, summary: nil, dismiss: { dismissed.count += 1 }, report: { _ in })
    actions.submit("Ship it", 40000)
    try await eventually("the save") { dismissed.count == 1 }
    #expect(server.requests("PUT", "/v1/sessions/conv/codex_goal").count == 1)
    #expect(store.tools.goal?.objective == "Ship it")
    actions.clear?()
    try await eventually("the clear") { dismissed.count == 2 }
    #expect(store.tools.goal == nil)
  }

  @Test("Pausing a goal asks the server and shows what it answered")
  func pausingAGoal() async throws {
    let server = server()
    server.route(
      "/v1/sessions/conv/codex_goal/status", method: "PATCH",
      .json(goal.replacingOccurrences(of: #""status":"active""#, with: #""status":"paused""#)))
    let store = try await codexStore(server)
    let actions = SessionToolsAdapter.goalActions(
      store, summary: nil, dismiss: {}, report: { _ in })
    actions.setActive?(false)
    try await eventually("the pause") { store.tools.goal?.status == "paused" }
    #expect(server.requests("PATCH", "/v1/sessions/conv/codex_goal/status").count == 1)
  }

  @Test("A goal that can't be cleared stays open and says why")
  func clearFails() async throws {
    let server = server()
    server.route(
      "/v1/sessions/conv/codex_goal", method: "DELETE", .json(#"{"detail":"no"}"#, status: 500))
    let store = try await codexStore(server)
    final class Dismissed { var count = 0 }
    let dismissed = Dismissed()
    let actions = SessionToolsAdapter.goalActions(
      store, summary: nil, dismiss: { dismissed.count += 1 }, report: { _ in })
    actions.clear?()
    try await eventually("the failure") { store.tools.lastError != nil }
    #expect(dismissed.count < 1)
  }

  @Test("The goal sheet opens from its presenter")
  func presenter() async throws {
    let store = try await codexStore(server())
    let view = Color.clear.modifier(
      SessionGoalPresenter(
        conversation: store, summary: nil, isPresented: .constant(true), report: { _ in }))
    let screen = OffscreenWindow(view, width: 500, height: 400)
    defer { screen.close() }
    try await settle(screen, until: "the goal to be read") { store.tools.isGoalLoaded }
    try await pause(screen)
    #expect(try screen.shownText().contains { $0.localizedCaseInsensitiveContains("goal") })
  }

  @Test("Plan mode turns on from the Add menu; a refusal says which way it failed")
  func planMode() async throws {
    let server = server()
    let store = try await codexStore(server)
    final class Reported { var messages: [String] = [] }
    let reported = Reported()
    let routes = SessionToolsAdapter.Routes(
      openSession: { _ in }, openNewSideChat: nil, showPullRequests: {}, showGoal: {},
      report: { reported.messages.append($0) })
    var extras = ComposerExtraActions()
    SessionToolsAdapter.add(to: &extras, store: store, summary: nil, routes: routes)
    let toggle = try #require(extras.togglePlan)
    #expect(extras.isPlanOn)
    #expect(extras.setGoal != nil)
    toggle()
    try await eventually("the write") { !server.requests("PATCH", "/v1/sessions/conv").isEmpty }
    let body = try #require(try server.patched("/v1/sessions/conv").first)
    #expect(body["collaboration_mode"] as? String == "default")
    try await eventually("the store to settle") { !store.tools.isBusy }

    server.route(
      "/v1/sessions/conv", method: "PATCH", .json(#"{"detail":"no"}"#, status: 500))
    toggle()
    try await eventually("the report") { !reported.messages.isEmpty }
    #expect(reported.messages.first?.hasPrefix("Could not exit Plan mode") == true)
  }
}
