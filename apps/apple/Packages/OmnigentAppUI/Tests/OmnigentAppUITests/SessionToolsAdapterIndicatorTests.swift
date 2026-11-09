import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

@MainActor
@Suite("Session tools indicators")
struct SessionToolsAdapterIndicatorTests {
  private typealias Fixtures = ConversationFixtures

  /// A panel over a server answering `pullRequests` for the session's list.
  private func panel(pullRequests: String) async throws -> SessionPanelStore {
    let core = try await Fixtures.core(routes: [
      "/v1/info": .json(
        #"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#),
      "/v1/sessions/conv/pull-requests": .json(pullRequests),
    ])
    let panel = SessionPanelStore(sessionID: "conv", core: core)
    await panel.reloadPullRequests()
    return panel
  }

  private let screen = ConversationViewState(
    header: OmnigentUIComponents.SessionHeader(id: "conv", title: ""))

  private func listing(_ rows: [String]) -> String {
    #"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false,"synced":true}"#
  }

  private func pullRequest(_ number: String, state: String = "OPEN", url: String? = nil) -> String {
    let link = url ?? "https://github.com/o/r/pull/\(number)"
    return #"""
      {"url":"\#(link)","host":"github.com","repository":"o/r","number":\#(number),"relationship":"created","state":"\#(state)"}
      """#
  }

  @Test("Background tasks: named ones, the note, and nothing when the section is missing")
  func backgroundTasks() {
    #expect(SessionToolsAdapter.backgroundTasks([]).list.isEmpty)
    #expect(SessionToolsAdapter.backgroundTasks([]).note == nil)

    let tasks = SessionToolsAdapter.backgroundTasks([
      Fixtures.section(
        "background-tasks",
        details: [("t1", "npm test"), ("t2", ""), ("t1", "again"), ("undetailed", "2 more")])
    ])
    #expect(tasks.list.map(\.id) == ["t1", "t2", "t1"])
    #expect(tasks.list.map(\.command) == ["npm test", nil, "again"])
    #expect(tasks.note == "2 more")
  }

  @Test("The background count is zero unless the core wrote an Int")
  func backgroundCount() async throws {
    func count(_ text: String) async throws -> Int {
      let store = try await Fixtures.store(
        sections: [Fixtures.section("status", details: [("background", text)])])
      return SessionToolsAdapter.indicators(store, screen: screen).backgroundTasks
    }
    #expect(try await count("3") == 3)
    #expect(try await count("abc") == 0)
    #expect(try await count("") == 0)
    #expect(try await count(String(UInt64.max)) == 0)
    let store = try await Fixtures.store()
    let empty = SessionToolsAdapter.indicators(store, screen: screen)
    #expect(empty.backgroundTasks == 0)
    #expect(empty.goal == nil)
    #expect(empty.subagents.isEmpty)
  }

  @Test("A goal's usage reads at both ends of the 64-bit range")
  func goalUsage() {
    func usage(tokens: UInt64, budget: UInt64?, seconds: UInt64) -> String {
      SessionToolsAdapter.goal(
        SessionGoal(
          objective: "", status: "exploded", tokenBudget: budget, tokensUsed: tokens,
          timeUsedSeconds: seconds, canPause: true, canResume: true)
      ).usage
    }
    #expect(usage(tokens: 0, budget: nil, seconds: 59) == "0 tokens")
    #expect(usage(tokens: 0, budget: 0, seconds: 60) == "0 / 0 tokens \u{00B7} 1 min")
    let largest = usage(tokens: .max, budget: .max, seconds: .max)
    #expect(largest.contains("tokens"))
    #expect(largest.hasSuffix("min"))
  }

  @Test("Plan mode is only Codex-native's, whatever the collaboration mode says")
  func planMode() async throws {
    let native = Fixtures.header(settings: Fixtures.settings(wrapper: "codex-native-ui"))
    func mode(_ collaboration: String?, header: OmnigentCoreFFI.SessionHeader?) async throws
      -> SessionToolsAdapter.PlanMode?
    {
      SessionToolsAdapter.planMode(
        try await Fixtures.store(
          header: header,
          sections: collaboration.map { [Fixtures.section("collaboration", summary: $0)] } ?? []))
    }
    #expect(try await mode("PLAN", header: native)?.isOn == true)
    #expect(try await mode("exploded", header: native)?.isOn == false)
    #expect(try await mode(nil, header: native)?.isOn == false)
    #expect(try await mode("plan", header: nil) == nil)
  }

  @Test("No panel, no features or a failed read mean no pull request chip")
  func noPullRequests() async throws {
    #expect(SessionToolsAdapter.pullRequestLabel(nil) == nil)
    #expect(SessionToolsAdapter.pullRequestPreview(nil).isEmpty)
    let unread = SessionPanelStore(sessionID: "conv", core: try await Fixtures.core())
    #expect(SessionToolsAdapter.pullRequestLabel(unread) == nil)
    #expect(SessionToolsAdapter.pullRequestPreview(unread).isEmpty)
    let empty = try await panel(pullRequests: listing([]))
    #expect(SessionToolsAdapter.pullRequestLabel(empty) == nil)
    var tray = ComposerTray(contextFraction: 0)
    SessionToolsAdapter.setPullRequests(nil, label: nil, on: &tray)
    #expect(tray.pullRequest == nil)
    #expect(tray.pullRequestStatus == nil)
    #expect(tray.pullRequestPreview.isEmpty)
  }

  @Test("The chip names one PR, counts several, and lists what needs the user first")
  func pullRequestChip() async throws {
    let one = try await panel(pullRequests: listing([pullRequest("7")]))
    #expect(SessionToolsAdapter.pullRequestLabel(one) == "#7")

    let several = try await panel(
      pullRequests: listing([
        pullRequest("1", state: "MERGED"), pullRequest("2", state: "exploded"),
        pullRequest("3"), pullRequest("4"),
      ]))
    #expect(SessionToolsAdapter.pullRequestLabel(several) == "4 PRs")
    let preview = SessionToolsAdapter.pullRequestPreview(several)
    #expect(preview.map(\.number) == [3, 4, 2, 1])
    var tray = ComposerTray(contextFraction: 0)
    SessionToolsAdapter.setPullRequests(several, label: "4 PRs", on: &tray)
    #expect(tray.pullRequest == "4 PRs")
    #expect(tray.pullRequestStatus == .open)
  }

  @Test("A PR number past Int keeps the list readable; duplicate URLs both stay")
  func oddPullRequests() async throws {
    let url = "https://github.com/o/r/pull/1"
    let odd = try await panel(
      pullRequests: listing([
        pullRequest(String(UInt64.max), url: url), pullRequest("0", url: url),
      ]))
    let preview = SessionToolsAdapter.pullRequestPreview(odd)
    #expect(preview.map(\.number) == [Int.max, 0])
    #expect(SessionToolsAdapter.pullRequestLabel(odd) == "2 PRs")
  }
}
