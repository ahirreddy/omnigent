import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Omni Advisor: its settings, both switches (a change reads the Inbox's items again), the
/// prompt and Run now, each failure kept with the control that caused it.
@MainActor
@Suite("Omni Advisor", .timeLimit(.minutes(1)))
struct AdvisorStoreTests {
  private static let settings = "/v1/proactive-agent/settings"

  private static func settingsBody(user: Bool = true, workspace: Bool = true) -> String {
    #"{"workspace_enabled":\#(workspace),"user_enabled":\#(user),"#
      + #""enabled":\#(user && workspace),"can_manage_workspace":true,"agent_id":"advisor"}"#
  }

  private func advisor(_ server: RouteServer) async throws -> AdvisorStore {
    let store = try await connectedStore(server)
    return try #require(store.pages?.feeds.advisor)
  }

  @Test("settings load, and a failed refresh keeps the ones read before")
  func loadsSettings() async throws {
    let server = RouteServer()
    server.route(Self.settings, .json(Self.settingsBody(workspace: false)))
    let advisor = try await advisor(server)
    #expect(advisor.settings == .idle)
    await advisor.loadSettings()
    #expect(advisor.settings.value?.agentId == "advisor")
    #expect(advisor.settings.value?.showsOn == false, "an admin turned it off for everyone")
    #expect(!advisor.isOn)

    server.fail(Self.settings, status: 500)
    await advisor.loadSettings()
    #expect(advisor.settings.value != nil)
  }

  @Test("a first read that fails is a failure the Inbox can retry")
  func failedFirstRead() async throws {
    let server = RouteServer()
    server.fail(Self.settings, status: 404)
    let advisor = try await advisor(server)
    await advisor.loadSettings()
    guard case .failed = advisor.settings else {
      Issue.record("expected a failure, got \(advisor.settings)")
      return
    }
  }

  @Test("a switch saves, takes the server's answer and reads the items again")
  func switches() async throws {
    let server = RouteServer()
    server.route(Self.settings, .json(Self.settingsBody()))
    server.route(
      "\(Self.settings)/me", method: "PUT", .json(Self.settingsBody(user: false)))
    server.route(
      "/v1/inbox/items",
      .json(#"{"data":[],"next_cursor":null,"unread_count":0,"unread_count_capped":false}"#))
    // The connection owns the Inbox's feeds, which the switch reads again.
    let connection = try await connectedStore(server)
    let advisor = try #require(connection.pages?.feeds.advisor)
    await advisor.loadSettings()
    #expect(advisor.isOn)

    let itemReads = server.requests(to: "/v1/inbox/items").count
    #expect(await advisor.setEnabled(.me, false))
    #expect(!advisor.isOn && advisor.switchError == nil && !advisor.isSavingSwitch)
    #expect(server.requests(to: "/v1/inbox/items").count == itemReads + 1)

    server.fail("\(Self.settings)/workspace", method: "PUT", status: 403)
    #expect(await advisor.setEnabled(.workspace, false) == false)
    #expect(advisor.switchError != nil)
    #expect(advisor.settings.value?.userEnabled == false, "a refusal changes nothing")
    withExtendedLifetime(connection) {}
  }

  @Test("the prompt saves, restores the default, and keeps a refusal")
  func prompt() async throws {
    let server = RouteServer()
    let prompt = "/v1/proactive-agent/prompt"
    server.route(
      prompt, .json(#"{"prompt":"Built in.","default_prompt":"Built in.","overridden":false}"#))
    let advisor = try await advisor(server)
    await advisor.loadPrompt()
    #expect(advisor.prompt.value?.overridden == false)

    server.route(
      prompt, method: "PUT",
      .json(#"{"prompt":"Be brief.","default_prompt":"Built in.","overridden":true}"#))
    let saved = await advisor.savePrompt("Be brief.")
    #expect(saved?.prompt == "Be brief." && advisor.prompt.value?.overridden == true)

    server.fail(prompt, method: "PUT", status: 400, detail: "Prompt is too long")
    #expect(await advisor.savePrompt("x") == nil)
    #expect(advisor.promptError != nil)
    #expect(advisor.prompt.value?.prompt == "Be brief.", "a refusal keeps the saved prompt")
  }

  @Test("Run now sends each typed user once and says what it did")
  func runNow() async throws {
    let server = RouteServer()
    let runs = "/v1/proactive-agent/runs"
    server.route(
      runs, method: "POST",
      .json(
        #"{"started":[{"user_id":"ann@example.com","task_id":"t","run_id":null}],"#
          + #""skipped":[{"user_id":"bo@example.com","reason":"already_running"}],"#
          + #""truncated":false}"#))
    let advisor = try await advisor(server)
    await advisor.run(" , ")
    #expect(server.requests(to: runs).isEmpty, "nothing to run for sends nothing")

    await advisor.run("ann@example.com, bo@example.com ann@example.com")
    #expect(
      advisor.runs?.summary == "Started 1 run. Skipped: bo@example.com (already running).")
    let body = try #require(server.requests(to: runs).last?.body)
    let sent = try JSONSerialization.jsonObject(with: Data(body)) as? [String: [String]]
    #expect(sent?["users"] == ["ann@example.com", "bo@example.com"])

    server.fail(runs, method: "POST", status: 400)
    await advisor.run("*")
    #expect(advisor.runs == nil && advisor.runError != nil)
  }
}
