import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentStores

private func decisionCard(_ id: String) -> DecisionCard {
  DecisionCard(
    id: id, carryingSessionId: "conv_a", targetSessionId: "conv_a", title: "Run it?",
    detail: "", message: "", toolInput: nil, kind: .approval,
    permissions: PermissionOptions(
      allowAllEdits: false, allowAutoMode: false, permissionDirectories: [], rememberLabel: nil,
      plan: nil, command: nil, execPolicyAmendment: nil, persistModes: [], antigravity: nil,
      fileChanges: []),
    phase: nil, policyName: nil, acceptsFeedback: false, answered: false)
}

/// Reads and answers whose failures the user would otherwise lose.
@MainActor
@Suite("Other store failures", .timeLimit(.minutes(1)))
struct StoreFailureTests {
  @Test("A refused answer is kept on its card, and the optimistic running status goes back")
  func decisionRefused() async throws {
    let server = RouteServer()
    server.route("/v1/sessions", .json(singleSessionList))
    let store = try await connectedStore(server)
    try await eventually("the list") { store.sessionList.session("conv_a") != nil }
    let conversation = try #require(store.conversation("conv_a"))
    let card = decisionCard("d1")
    conversation.decisions.replace([card])

    await conversation.decisions.resolve(card, with: .decline)
    #expect(conversation.decisions.errors["d1"] != nil)
    #expect(conversation.decisions.resolving.isEmpty)
    #expect(store.sessionList.session("conv_a")?.status == .idle)
  }

  @Test("A status expectation for a session the list doesn't know does nothing")
  func unknownSessionExpectation() {
    let list = SessionListStore()
    let expectation = ListStatusExpectation(list: list, sessionID: "nobody")
    expectation.expect(.running).withdraw()
    #expect(list.session("nobody") == nil)
  }

  @Test("With no server, editing a session explains why nothing happened")
  func editWithoutCore() async {
    let list = SessionListStore()
    #expect(await !list.setArchived("conv_a", true))
    #expect(list.editError?.message.contains("Connect to a server") == true)
    list.dismissEditError()
    #expect(list.editError == nil)
  }

  @Test("Moving a pin writes the new order, and a refusal is reported")
  func movesPins() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions",
      .json(
        #"{"object":"list","has_more":false,"data":[{"id":"p0","status":"idle","created_at":1,"permission_level":4,"labels":{"omnigent.pinned":"1000"}},{"id":"p1","status":"idle","created_at":1,"permission_level":4,"labels":{"omnigent.pinned":"2000"}}]}"#
      ))
    let store = try await connectedStore(server)
    try await eventually("the list") { store.sessionList.session("p1")?.isPinned == true }

    let pinned = { (id: String, stamp: String) -> HttpResponse in
      .json(
        #"{"id":"\#(id)","status":"idle","created_at":1,"permission_level":4,"labels":{"omnigent.pinned":"\#(stamp)"}}"#
      )
    }
    server.route("/v1/sessions/p0", pinned("p0", "1000"))
    server.route("/v1/sessions/p1", pinned("p1", "2000"))
    server.fail("/v1/sessions/p0", method: "PATCH", status: 400)
    server.fail("/v1/sessions/p1", method: "PATCH", status: 400)
    #expect(await !store.sessionList.movePin("p0", slotOf: "p1"))
    #expect(!server.requests(method: "PATCH").isEmpty)
    #expect(store.sessionList.editError != nil)

    server.route("/v1/sessions/p0", method: "PATCH", pinned("p0", "3000"))
    server.route("/v1/sessions/p1", method: "PATCH", pinned("p1", "2000"))
    let moved = await store.sessionList.movePin("p0", slotOf: "p1")
    #expect(moved, "\(String(describing: store.sessionList.editError))")
    let write = try #require(server.requests(method: "PATCH").last)
    #expect(try server.body(of: write)["labels"] != nil)
  }

  @Test("Marking a session seen reports a refusal so the unread dot's stuck state is explained")
  func markSeenRefused() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions",
      .json(
        #"{"object":"list","has_more":false,"data":[{"id":"conv_a","status":"idle","created_at":1,"updated_at":50,"permission_level":4,"owner":"local","viewer_last_seen":1}]}"#
      ))
    server.fail("/v1/sessions/conv_a/read-state", status: 500)
    let store = try await connectedStore(server)
    try await eventually("the unread mark") { store.sessionList.unreadIDs.contains("conv_a") }
    store.dismissIssues()
    #expect(await !store.markSeen("conv_a"))
    #expect(!store.issues.isEmpty)
  }

  @Test(
    "A recovery the server didn't take says so, in words for what was asked",
    arguments: [
      (FailureRecovery.resume, #"{"recovered":false}"#, "already connected"),
      (FailureRecovery.continue, #"{"queued":false}"#, "not accepted"),
    ])
  func recoveryNotTaken(recovery: FailureRecovery, answer: String, expected: String) async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions/conv_a",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#))
    server.route("/v1/sessions/conv_a/events", method: "POST", .json(answer))
    let store = try await connectedStore(server)
    let conversation = try #require(store.conversation("conv_a"))
    await conversation.recoverTurn(recovery)
    #expect(conversation.errors.last?.message.contains(expected) == true)
  }

  @Test("Agent info loads once it reads, and a repeat changes nothing")
  func agentInfo() async throws {
    let server = RouteServer()
    server.route(
      "/v1/agents/agent_1",
      .json(#"{"id":"agent_1","name":"Reviewer","harness":"codex-native"}"#))
    server.route(
      "/v1/sessions/conv_a/policies", .json(#"{"object":"list","data":[],"has_more":false}"#))
    let store = try await connectedStore(server)
    let conversation = try #require(store.conversation("conv_a"))
    await conversation.loadAgentInfo(agentID: "agent_1")
    #expect(conversation.errors.isEmpty, "\(conversation.errors)")
    #expect(conversation.agentInfo != nil)
  }

  @Test("Features that can't be read are kept, and retried on the next call")
  func panelFeatures() async throws {
    let server = RouteServer()
    let store = try await connectedStore(server)
    let panel = try #require(store.makePanelStore("conv_a"))
    server.fail("/v1/info")
    await panel.loadFeatures()
    #expect(panel.featuresError != nil)
    #expect(!panel.offersPullRequests)

    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
    await panel.loadFeatures()
    #expect(panel.featuresError == nil)
    #expect(panel.offersPullRequests)
  }

  @Test("After a turn, pull requests re-read only if the panel has shown them")
  func refreshIfShown() async throws {
    let server = RouteServer()
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
    let list = "/v1/sessions/conv_a/pull-requests"
    server.route(list, .json(#"{"object":"list","data":[],"has_more":false,"synced":true}"#))
    let store = try await connectedStore(server)
    let panel = try #require(store.makePanelStore("conv_a"))
    await panel.refreshPullRequestsIfShown()
    #expect(server.requests(to: list).isEmpty)

    await panel.reloadPullRequests()
    let reads = server.requests(to: list).count
    await panel.refreshPullRequestsIfShown()
    #expect(server.requests(to: list).count == reads + 1)
  }

  @Test("A pull request's detail and files each show their own read failure")
  func pullRequestReadFailures() async throws {
    let server = RouteServer()
    let github = "/v1/sessions/conv_a/resources/github"
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
    server.fail(github)
    let store = try await connectedStore(server)
    let panel = try #require(store.makePanelStore("conv_a"))
    let url = "https://github.com/o/r/pull/7"
    await panel.showPullRequest(url)
    guard case .failed = panel.detail else {
      Issue.record("detail: \(panel.detail)")
      return
    }

    server.route(
      github,
      .json(
        #"{"object":"session.github.info","available":true,"selected_pr_url":"https://github.com/o/r/pull/7","prs":[],"pr":{"number":7,"title":"Fix","state":"OPEN","url":"https://github.com/o/r/pull/7"}}"#
      ))
    server.fail("\(github)/diff")
    await panel.showPullRequest(url)
    #expect(panel.detail.value?.pullRequest?.number == 7)
    guard case .failed = panel.files else {
      Issue.record("files: \(panel.files)")
      return
    }
  }

  @Test("Comments go to the agent as one request; a refusal is thrown to the caller")
  func commentsToAgent() async throws {
    let server = RouteServer()
    let path = "/v1/sessions/conv_a/comments/send"
    server.fail(path, method: "POST")
    let store = try await connectedStore(server)
    let workspace = try #require(store.workspace("conv_a"))
    await #expect(throws: WorkspaceFailure.self) {
      try await workspace.sendCommentsToAgent(["c1"])
    }

    server.route(path, method: "POST", .json(#"{"formatted_message":"Please review."}"#))
    server.route(
      "/v1/sessions/conv_a",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#))
    server.route("/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":true}"#))
    try await workspace.sendCommentsToAgent(["c1", "c2"])
    let sent = try #require(server.requests(to: path, method: "POST").last)
    #expect(try server.body(of: sent)["comment_ids"] as? [String] == ["c1", "c2"])
  }

  @Test("A sub-agent's finished turn is rolled up under its parent, named by the parent's title")
  func childNotification() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions",
      .json(
        #"{"object":"list","has_more":false,"data":[{"id":"parent","title":"Refactor auth","status":"idle","created_at":1,"permission_level":4},{"id":"child","title":"Helper","status":"idle","created_at":1,"permission_level":4,"parent_session_id":"parent"}]}"#
      ))
    let store = try await connectedStore(server)
    try await eventually("the rows") { store.sessionList.parent(of: "child") == "parent" }
    store.apply(
      .notification(
        notification: AttentionNotification(
          sessionId: "child", kind: .completed, title: "Helper", body: "Done")))
    let notifications = try #require(store.notifications)
    #expect(notifications.pending.map(\.sessionId) == ["parent"])
    #expect(notifications.pending.first?.title == "Refactor auth")
  }

  @Test("Permission to notify is remembered and passed to the core")
  func notificationPermission() async throws {
    let store = try await connectedStore(RouteServer())
    let notifications = try #require(store.notifications)
    notifications.setAllowed(true)
    #expect(notifications.isAllowed)
    notifications.setAllowed(false)
    #expect(!notifications.isAllowed)
  }
}
