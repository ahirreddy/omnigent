import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// Random worktree asks the pinned host whether the folder is a Git repository, as the web's
/// `useHostWorktrees`, and saves `HEAD` as the automation's base branch.
@MainActor
@Suite("Automations: random worktree", .serialized, .timeLimit(.minutes(1)))
struct AutomationWorktreeTests {
  private func connected(offline: Set<String> = []) async throws -> (ConnectionStore, PagesStore) {
    let server = newSessionServer(offline: offline)
    server.route(
      "/v1/hosts/mac/worktrees",
      .json(#"{"data":[{"path":"/work","branch":"main","is_main":true}]}"#))
    server.route("/v1/hosts/box/worktrees", .json(#"{"data":[]}"#))
    let connection = try await signedInStore(server)
    let pages = try #require(connection.pages)
    await pages.loadAutomationCatalog()
    return (connection, pages)
  }

  private func draft(host: String, workspace: String) -> AutomationDraftState {
    var draft = AutomationDraftState(name: "Nightly", agentID: "ag_claude")
    draft.hostID = host
    draft.workspace = workspace
    return draft
  }

  @Test("A repository folder offers it; another folder, an offline host or none says why")
  func check() async throws {
    let (connection, pages) = try await connected(offline: ["box"])
    func check(_ draft: AutomationDraftState) async -> AutomationWorktreeCheck {
      await AutomationsMapping.worktreeCheck(
        AutomationsMapping.worktreeQuery(draft, pages: pages), creation: connection.creation())
    }
    #expect(await check(draft(host: "mac", workspace: "/work")) == .repository)
    #expect(await check(draft(host: "box", workspace: "/work")) == .hostOffline)
    #expect(
      AutomationsMapping.worktreeQuery(draft(host: "mac", workspace: ""), pages: pages) == nil)
    var sandbox = draft(host: "mac", workspace: "/work")
    sandbox.runsInSandbox = true
    #expect(await check(sandbox) == .notRepository)

    let (online, onlinePages) = try await connected()
    let plain = AutomationsMapping.worktreeQuery(
      draft(host: "box", workspace: "/notes"), pages: onlinePages)
    #expect(
      await AutomationsMapping.worktreeCheck(plain, creation: online.creation()) == .notRepository)
  }

  @Test("Random worktree saves HEAD as the base branch")
  func savedBaseBranch() {
    var draft = draft(host: "mac", workspace: "/work")
    draft.baseBranch = "HEAD"
    draft.schedule = ScheduleChoice(preset: .daily)
    let request = AutomationsMapping.request(
      draft, prompt: "Summarize", saved: nil, sessionModes: false, sendsOverrides: false)
    #expect(request.baseBranch == "HEAD")
  }
}
