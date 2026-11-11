import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Answers the reads behind the harness list, with one built-in agent to switch to.
func offerHarnesses(_ server: RouteServer) {
  server.route(
    "/v1/hosts",
    .json(
      #"{"hosts":[{"host_id":"demo-host","name":"Host","status":"online","configured_harnesses":{"claude-native":true}}]}"#
    ))
  server.route(
    "/v1/agents",
    .json(
      #"{"data":[{"id":"target","name":"Claude","harness":"claude-native","builtin":true}],"has_more":false}"#
    ))
}

/// The model, effort, harness and approval pickers.
@MainActor
@Suite("Composer settings", .timeLimit(.minutes(1)))
struct ComposerConfigurationTests {
  private let path = "/v1/sessions/conv_a"

  private func loaded(_ fields: String = codexFields) async throws -> LiveComposer {
    let live = try await LiveComposer(fields: fields)
    offerHarnesses(live.server)
    await live.composer.loadConfiguration()
    return live
  }

  private func patches(_ live: LiveComposer) throws -> [[String: Any]] {
    try live.server.requests(to: path, method: "PATCH").map { try live.server.body(of: $0) }
  }

  @Test("A failed read says so, and picking before it loads explains why nothing happened")
  func beforeLoading() async throws {
    let live = try await LiveComposer()
    let composer = live.composer
    await composer.selectModel("sample-fast")
    #expect(composer.configurationError?.message == "Settings have not loaded yet.")
    await composer.selectEffort("low")
    #expect(composer.configurationError?.message == "Settings have not loaded yet.")
    await composer.switchHarness(to: "target")
    #expect(composer.configurationError?.message == "Settings have not loaded yet.")
    composer.dismissConfigurationError()
    #expect(composer.configurationError == nil)
    #expect(composer.efforts(for: "any").isEmpty)
    #expect(composer.modelChoices.isEmpty)

    live.server.fail(path, method: "GET")
    await composer.loadConfiguration()
    #expect(composer.configurationError != nil)
    #expect(composer.configuration == nil)
  }

  @Test("Loading reads what the pickers offer")
  func loads() async throws {
    let live = try await loaded()
    let composer = live.composer
    #expect(composer.configuration?.harness == "codex-native")
    #expect(composer.configurationLabels != nil)
    #expect(composer.modelChoices.map(\.value) == ["sample-balanced", "sample-fast"])
    #expect(composer.efforts(for: "sample-fast") == ["high", "low"])
    #expect(composer.efforts(for: "unknown").isEmpty)
    #expect(composer.supportsModelChoice)
    #expect(composer.supportsEffortChoice)
    #expect(composer.executionUnavailableReason == nil)
    #expect(!composer.isSmartRoutingOn)
    #expect(composer.configurationError == nil)
  }

  @Test("Choosing a model writes it and shows the server's answer; a refusal changes nothing")
  func selectsModel() async throws {
    let live = try await loaded()
    let composer = live.composer
    live.server.fail(path, method: "PATCH")
    await composer.selectModel("sample-fast")
    #expect(composer.configurationError != nil)
    #expect(composer.configuration?.modelOverride == "sample-balanced")
    #expect(!composer.isApplyingConfiguration)
    try await live.settle()

    let chosen = codexFields.replacingOccurrences(
      of: #""model_override":"sample-balanced""#, with: #""model_override":"sample-fast""#)
    live.server.route(path, method: "PATCH", snapshot(chosen))
    await composer.selectModel("sample-fast")
    #expect(composer.configurationError == nil)
    #expect(composer.configuration?.modelOverride == "sample-fast")
    #expect(try patches(live).last?["model_override"] as? String == "sample-fast")
  }

  @Test("/model and /effort clear the draft and change the setting")
  func commandsChangeSettings() async throws {
    let live = try await loaded()
    let composer = live.composer
    let lowEffort = codexFields.replacingOccurrences(
      of: #""reasoning_effort":"high""#, with: #""reasoning_effort":"low""#)
    live.server.route(path, method: "PATCH", snapshot(lowEffort))
    composer.text = "/effort low"
    #expect(await composer.send() == .handled)
    #expect(composer.text.isEmpty)
    #expect(composer.configuration?.effort == "low")
    try await live.settle()

    live.server.route(path, method: "GET", snapshot(lowEffort))
    live.server.route(
      path, method: "PATCH",
      snapshot(
        lowEffort.replacingOccurrences(
          of: #""model_override":"sample-balanced""#, with: #""model_override":"sample-fast""#)))
    composer.text = "/model sample-fast"
    await composer.send()
    #expect(composer.text.isEmpty)
    #expect(composer.configuration?.modelOverride == "sample-fast")
    #expect(live.postedTexts.isEmpty, "a command is not a message")
  }

  @Test("A pick while Smart Routing is on turns routing off first; a refusal stops the pick")
  func smartRouting() async throws {
    let live = try await loaded()
    let composer = live.composer
    #expect(composer.offersSmartRouting == composer.rules.offersSmartRouting)

    live.server.fail(path, method: "PATCH")
    await composer.setSmartRouting(true)
    #expect(composer.configurationError != nil)
    #expect(!composer.isSmartRoutingOn)
    try await live.settle()

    let routed = codexFields + #","cost_control_mode_override":"on""#
    live.server.route(path, method: "PATCH", snapshot(routed))
    await composer.setSmartRouting(true)
    #expect(composer.isSmartRoutingOn)
    #expect(composer.configurationError == nil)
    live.server.route(path, method: "GET", snapshot(routed))
    try await live.settle()

    live.server.fail(path, method: "PATCH")
    let writes = try patches(live).count
    await composer.selectModel("sample-fast")
    #expect(composer.configurationError != nil)
    #expect(try patches(live).count == writes + 1, "only the routing write was tried")
    try await live.settle()
    await composer.selectEffort("low")
    #expect(try patches(live).count == writes + 2)
    #expect(composer.isSmartRoutingOn)
  }

  @Test("Switching harness keeps the session; a refusal stays on the old one")
  func switchesHarness() async throws {
    let live = try await loaded()
    let composer = live.composer
    #expect(composer.harnessOptions.map(\.id) == ["target"])
    #expect(composer.harnessOptions.first?.isCurrent == false)

    await composer.switchHarness(to: "target")
    #expect(composer.configurationError != nil)
    #expect(composer.configuration?.harness == "codex-native")
    try await live.settle()

    // Reads after the switch see the new harness, as a real server's would.
    let switched = snapshot(
      claudeFields("default").replacingOccurrences(
        of: #""agent_id":"claude""#, with: #""agent_id":"target-clone""#))
    live.server.route("/v1/sessions/conv_a/switch-agent", method: "POST", switched)
    let gate = live.server.hold("/v1/sessions/conv_a/switch-agent", method: "POST")
    let switching = Task { await composer.switchHarness(to: "target") }
    try await eventually("the switch") { gate.arrivals == 1 }
    #expect(composer.isApplyingConfiguration)
    live.server.route(path, method: "GET", switched)
    gate.release()
    await switching.value
    #expect(
      composer.configurationError == nil, "\(String(describing: composer.configurationError))")
    #expect(composer.configuration?.harness == "claude-native")
    #expect(!composer.isApplyingConfiguration)
  }

  @Test("A failed model preview still offers the harness list")
  func previewFails() async throws {
    let live = try await LiveComposer(
      fields:
        #""harness":"codex-native","agent_id":"clone","labels":{"omnigent.wrapper":"codex-native-ui"},"host_id":"demo-host","host_online":true,"runner_online":true,"model_options":[]"#
    )
    offerHarnesses(live.server)
    live.server.fail("/v1/hosts/demo-host/harnesses/codex-native/model-options")
    await live.composer.loadConfiguration()
    #expect(live.composer.configurationError == nil)
    #expect(live.composer.harnessOptions.count == 1)
    #expect(live.composer.configurationCatalog?.modelOptionsError != nil)
  }

  @Test("A mode change that lands elsewhere shows where it really is and says so")
  func approvalModes() async throws {
    let live = try await loaded(claudeFields("default"))
    let composer = live.composer
    let menu = try #require(composer.approvalModeMenu)
    #expect(menu.options.contains { $0.switchable })

    live.server.route(path, method: "PATCH", snapshot(claudeFields("acceptEdits")))
    await composer.selectApprovalMode("acceptEdits")
    #expect(composer.configurationError == nil)
    #expect(composer.configuration?.approvalMode == "acceptEdits")
    try await live.settle()

    live.server.route(path, method: "GET", snapshot(claudeFields("default")))
    live.server.route(path, method: "PATCH", snapshot(claudeFields("plan")))
    await composer.selectApprovalMode("auto")
    #expect(composer.configurationError != nil)
    #expect(composer.configuration?.approvalMode == "default", "read back from the server")
    try await live.settle()

    live.server.fail(path, method: "GET")
    await composer.selectApprovalMode("auto")
    #expect(composer.configurationError?.message.contains("could not be read") == true)
    #expect(!composer.isApplyingConfiguration)
  }
}
