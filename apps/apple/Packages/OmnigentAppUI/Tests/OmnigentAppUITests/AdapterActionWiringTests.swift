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

/// The smaller action of each page adapter: pressing it reaches the store or the window.
@MainActor
@Suite("Adapter actions", .serialized, .timeLimit(.minutes(1)))
struct AdapterActionWiringTests {
  private final class Opened {
    var sessions: [String] = []
  }

  @Test("Usage's Retry reads the report again, and a row opens its session")
  func usageActions() async throws {
    let server = newSessionServer()
    let connection = try await signedInStore(server)
    let pages = try #require(connection.pages)
    let opened = Opened()
    let adapter = UsageAdapter(connection: connection) { opened.sessions.append($0) }
    let actions = adapter.actions(pages)
    #expect(actions.formatCost(1.5).contains("1.5"))
    actions.retry?()
    try await eventually("the usage read") { !server.requests("GET", "/v1/usage").isEmpty }
    actions.openSession?("conv_a")
    #expect(opened.sessions == ["conv_a"])
  }

  @Test("An error on Automations can be dismissed, and a run opens its session")
  func automationsActions() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/scheduled-tasks/gone", method: "DELETE", .json(#"{"detail":"nope"}"#, status: 500))
    let connection = try await signedInStore(server)
    let pages = try #require(connection.pages)
    let opened = Opened()
    let actions = AutomationsAdapter(
      connection: connection, open: { opened.sessions.append($0) }, defaults: try scratchDefaults()
    ).actions(pages)
    _ = await pages.deleteAutomation("gone")
    #expect(pages.automationError != nil)
    actions.dismissError?()
    #expect(pages.automationError == nil)
    actions.openSession?("conv_a")
    #expect(opened.sessions == ["conv_a"])
  }

  @Test("An automation's page retries its runs and dismisses its error")
  func automationDetailActions() async throws {
    let server = newSessionServer()
    server.route("/v1/scheduled-tasks/t1/runs", .json(#"{"runs":[]}"#))
    server.route(
      "/v1/scheduled-tasks/t1", method: "DELETE", .json(#"{"detail":"nope"}"#, status: 500))
    server.route(
      "/v1/scheduled-tasks", method: "GET",
      .json(
        #"{"scheduled_tasks":[{"id":"t1","name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"ag_claude","timezone":"UTC","state":"active","next_run_at":"2099-11-05T09:00:00Z"}]}"#
      ))
    let connection = try await signedInStore(server)
    let pages = try #require(connection.pages)
    await pages.loadAutomations()
    let automation = try #require(pages.automations.value?.first)
    let actions = AutomationDetailAdapter(
      pages: pages, automation: automation, open: { _ in }, back: {}, edit: {}
    ).actions
    actions.retry?()
    try await eventually("the runs") {
      !server.requests("GET", "/v1/scheduled-tasks/t1/runs").isEmpty
    }
    _ = await pages.deleteAutomation("t1")
    #expect(pages.automationError != nil)
    actions.dismissError?()
    #expect(pages.automationError == nil)
  }

  @Test("Choosing a board on the Canvas shows it")
  func canvasBoard() async throws {
    let connection = try await signedInStore(threeSessionServer())
    let canvas = try #require(connection.canvas)
    let actions = CanvasAdapter(connection: connection, open: { _ in }, newSession: {})
      .actions(canvas)
    actions.selectBoard?("second")
    #expect(canvas.activeBoard == "second")
  }

  @Test("The sandbox repository picker checks through the core and reads branches")
  func sandboxRepositoryActions() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/connections/github/repos/acme/app/branches",
      .json(#"{"object":"list","data":[{"name":"main"}],"has_more":false}"#))
    let connection = try await signedInStore(server)
    let sandboxes = connection.sandboxes()
    var repos: [SandboxRepoChoice] = []
    let actions = SandboxChoices.repositoryActions(sandboxes) { repos = $0 }
    let valid = "https://github.com/acme/app"
    #expect(actions.urlProblem("not a url", []) != nil)
    #expect(actions.urlProblem(valid, []) == nil)
    let chosen = SandboxRepoChoice(url: valid)
    #expect(actions.urlProblem(valid, [chosen]) != nil, "the same repository twice")
    #expect(actions.branchProblem(valid, "not a branch name..") != nil)
    #expect(actions.repoName(valid) == "app")
    #expect(actions.isSameRepo(valid, valid + ".git"))
    actions.setRepos([chosen])
    #expect(repos == [chosen])
    actions.loadBranches?("acme/app")
    try await eventually("the branches") {
      !server.requests("GET", "/v1/connections/github/repos/acme/app/branches").isEmpty
    }
  }

  @Test("The composer's approval menu and routing toggle reach the session, and a notice goes")
  func composerConfiguration() async throws {
    let store = try await ConversationFixtures.store()
    let composer = store.composer
    let extras = ComposerAdapter.extras(composer, isRunning: { true })
    composer.commandNotice = "Context: full"
    extras.dismissCommandNotice?()
    #expect(composer.commandNotice == nil)
    extras.selectApprovalMode?(ApprovalModeOption(id: "plan", label: "Plan", detail: ""))
    extras.setSmartRouting?(true)
    composer.text = "later"
    extras.queueDraft?()
    extras.history.sendAllQueued?()
    try await eventually("Send All to try the queued message") {
      composer.queue.items.allSatisfy { $0.state != .queued }
    }
  }

  @Test("Choosing All Time counts days the last 30 leave out")
  func usageRange() async throws {
    SystemSideEffects.install()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let today = formatter.string(from: .now)
    let server = newSessionServer()
    server.route(
      "/v1/usage",
      .json(
        #"{"object":"usage_report","cost_today":1.0,"daily_costs":[{"day":"2001-01-01","cost_usd":40.0},{"day":"\#(today)","cost_usd":2.0}],"sessions":[]}"#
      ))
    let connection = try await signedInStore(server)
    let screen = OffscreenWindow(
      UsageAdapter(connection: connection) { _ in }, width: 900, height: 700)
    defer { screen.close() }
    try await settle(screen, untilShowing: "$2.00")
    try chooseSegment(3, on: screen)
    try await settle(screen, untilShowing: "$42.00")
  }

  @Test("The Paused filter narrows the page to what's paused")
  func automationsFilter() async throws {
    SystemSideEffects.install()
    let server = newSessionServer()
    server.route(
      "/v1/scheduled-tasks", method: "GET",
      .json(
        #"{"scheduled_tasks":[{"id":"t1","name":"Standup","prompt":"p","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"ag_claude","timezone":"UTC","state":"active","next_run_at":"2099-11-05T09:00:00Z"}]}"#
      ))
    let connection = try await signedInStore(server)
    let defaults = try scratchDefaults()
    let key = AutomationsIntroPresenter.seenKey(
      baseURL: connection.connectedServer?.baseUrl, userID: connection.connectedServer?.userId)
    defaults.set(true, forKey: try #require(key))
    let screen = OffscreenWindow(
      AutomationsAdapter(connection: connection, open: { _ in }, defaults: defaults),
      width: 900, height: 1100)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Standup")
    let paused = try #require(AutomationsFilter.allCases.firstIndex(of: .paused))
    try chooseSegment(paused, on: screen)
    // A row leaving a lazy list stays in what an offscreen window reads, so an empty page proves it.
    try await settle(screen, untilShowing: "No automations found")
  }

  @Test("Inbox's Load More reads the next page of sessions")
  func inboxLoadMore() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions", method: "GET",
      .json(
        #"{"object":"list","data":[\#(sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 3))],"has_more":true,"last_id":"conv_a"}"#
      ))
    let connection = try await signedInStore(server)
    try await eventually("the list") { connection.sessionList.isLoaded }
    let before = server.requests("GET", "/v1/sessions").count
    InboxTriageAdapter(connection: connection, open: { _ in })
      .actions.loadMoreSessions?()
    try await eventually("the next page") { server.requests("GET", "/v1/sessions").count > before }
  }
}
