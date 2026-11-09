import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

private let harnessFixHosts = #"""
  {"hosts":[{"host_id":"h1","name":"Mac","status":"online","harness_login_supported":true,
    "configured_harnesses":{"codex-native":true,"claude-native":true},
    "harness_accounts":{"codex":{"kind":"chatgpt","email":"old@x.io"},
      "claude":{"kind":"subscription","email":"me@x.io"}}}]}
  """#

/// A connected harness catalog and a fix flow that polls quickly.
@MainActor
func harnessFixStores(_ server: RouteServer) async throws -> (HarnessSetupStore, HarnessFixStore) {
  server.route(
    "/v1/info",
    .json(
      #"{"single_user":true,"accounts_enabled":false,"features":{"harness_install":true},"installable_harnesses":["codex-native"]}"#
    ))
  server.route("/v1/harnesses", .json(#"{"data":[]}"#))
  server.route("/v1/hosts", .json(harnessFixHosts))
  let connection = try await connectedStore(server)
  let setup = try #require(connection.harnessSetup())
  await setup.load()
  let core = try #require(connection.core)
  return (setup, HarnessFixStore(core: core, setup: setup, pollInterval: .milliseconds(5)))
}

/// Ports of the flows in web/src/pages/settings/HarnessFixDialog.test.tsx.
@MainActor
struct HarnessFixStoreTests {
  @Test(.timeLimit(.minutes(1))) func switchingCodexSignsOutThenSignsInWithADeviceCode()
    async throws
  {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(
      "/v1/hosts/h1/harnesses/codex/logout",
      .json(#"{"configured_harnesses":{"codex-native":"needs-auth"},"harness_accounts":{}}"#))
    server.route(
      "/v1/hosts/h1/harnesses/codex/login",
      .json(
        #"{"login_id":"l1","verification_url":"https://auth.openai.com/codex/device","user_code":"AB-12","expires_at":4102444800}"#
      ))
    server.route(
      "/v1/hosts/h1/harnesses/codex/login/l1",
      .json(
        #"{"status":"succeeded","error":null,"expired":false,"configured_harnesses":{"codex-native":true},"harness_accounts":{"codex":{"kind":"chatgpt","email":"new@x.io","plan":"pro"}}}"#
      ))
    let detail = try #require(setup.detail(harness: "codex-native", name: "Codex", hostID: "h1"))
    #expect(detail.credentialAction == .switchAccount)

    await fix.begin(.switch, detail: detail, hostID: "h1")
    #expect(fix.phase == .confirmSwitch(account: "old@x.io"))
    await fix.confirmSwitch(detail: detail, hostID: "h1", email: nil)
    if case .deviceCode(let login) = fix.phase {
      #expect(login.userCode == "AB-12")
    } else {
      Issue.record("expected a device code, got \(fix.phase)")
    }
    try await eventually("the sign-in") {
      if case .done = fix.phase { return true }
      return false
    }
    #expect(fix.phase == .done("Codex is ready on Mac. Signed in as new@x.io \u{b7} pro."))
    #expect(setup.detail(harness: "codex-native", name: "Codex", hostID: "h1")?.ready == true)
  }

  @Test(.timeLimit(.minutes(1))) func switchingClaudeRunsTheLoginCommandThenChecksAgain()
    async throws
  {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    server.route(
      "/v1/hosts/h1/harnesses/claude/logout",
      .json(#"{"configured_harnesses":{"claude-native":"needs-auth"},"harness_accounts":null}"#))
    server.route(
      "/v1/hosts/h1/harnesses/refresh",
      .json(#"{"configured_harnesses":{"claude-native":"needs-auth"}}"#))
    let detail = try #require(
      setup.detail(harness: "claude-native", name: "Claude Code", hostID: "h1"))

    await fix.confirmSwitch(detail: detail, hostID: "h1", email: "work@x.io")
    #expect(
      fix.phase
        == .runCommand("claude auth login --claudeai --email work@x.io", stillNotReady: false))
    await fix.checkAgain(detail: detail, hostID: "h1")
    #expect(
      fix.phase
        == .runCommand("claude auth login --claudeai --email work@x.io", stillNotReady: true))
    server.route(
      "/v1/hosts/h1/harnesses/refresh", .json(#"{"configured_harnesses":{"claude-native":true}}"#))
    await fix.checkAgain(detail: detail, hostID: "h1")
    #expect(fix.phase == .done("Claude Code is ready on Mac."))
  }

  @Test(.timeLimit(.minutes(1))) func updatingReportsTheVersionOrTheSetupStillNeeded() async throws
  {
    let server = RouteServer()
    let (setup, fix) = try await harnessFixStores(server)
    let detail = try #require(setup.detail(harness: "codex-native", name: "Codex", hostID: "h1"))
    server.route(
      "/v1/hosts/h1/harnesses/codex-native/install",
      .json(#"{"configured_harnesses":{"codex-native":true},"version":"0.50.0"}"#))
    await fix.begin(.update, detail: detail, hostID: "h1")
    #expect(fix.phase == .done("Codex 0.50.0 is ready on Mac."))

    server.route(
      "/v1/hosts/h1/harnesses/codex-native/install",
      .json(#"{"configured_harnesses":{"codex-native":"needs-auth"}}"#))
    await fix.begin(.update, detail: detail, hostID: "h1")
    #expect(fix.phase == .needsSetup("Codex was updated but still needs to be set up on Mac."))

    server.route(
      "/v1/hosts/h1/harnesses/codex-native/install",
      .json(#"{"detail":"npm is not installed"}"#, status: 400))
    await fix.begin(.update, detail: detail, hostID: "h1")
    #expect(fix.phase == .failed("npm is not installed"))
  }

  @Test(.timeLimit(.minutes(1))) func startupReadsOnceAndOlderHostsSaySo() async throws {
    let server = RouteServer()
    let (_, fix) = try await harnessFixStores(server)
    server.route(
      "/v1/hosts/h1/harnesses/codex-native/startup", .json(#"{"detail":"x"}"#, status: 501))
    await fix.loadStartup(harness: "codex-native", hostID: "h1", hostName: "Mac")
    #expect(fix.startup["h1/codex-native"] == .loaded(.hostOutdated))
  }
}
