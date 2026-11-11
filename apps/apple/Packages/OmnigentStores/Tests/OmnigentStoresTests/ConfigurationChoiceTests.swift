import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A model, effort or approval mode between the choice and the server's answer.
@MainActor
@Suite("Settings show at once", .timeLimit(.minutes(1)))
struct ConfigurationChoiceTests {
  private let path = "/v1/sessions/conv_a"

  private func loaded(_ fields: String) async throws -> LiveComposer {
    let live = try await LiveComposer(fields: fields)
    offerHarnesses(live.server)
    await live.composer.loadConfiguration()
    return live
  }

  /// The Codex session after choosing `model` and `effort`.
  private func codex(model: String, effort: String) -> String {
    codexFields
      .replacingOccurrences(
        of: #""model_override":"sample-balanced""#, with: #""model_override":"\#(model)""#
      )
      .replacingOccurrences(
        of: #""reasoning_effort":"high""#, with: #""reasoning_effort":"\#(effort)""#)
  }

  @Test("A model and an effort show while the server is asked, and stay when it agrees")
  func shownWhileAsked() async throws {
    let live = try await loaded(codexFields)
    let composer = live.composer
    let fast = codex(model: "sample-fast", effort: "high")
    live.server.route(path, method: "PATCH", snapshot(fast))
    let modelPatch = live.server.hold(path, method: "PATCH")
    let model = Task { await composer.selectModel("sample-fast") }
    try await eventually("the model to reach the server") { modelPatch.arrivals == 1 }
    #expect(composer.configuration?.modelOverride == "sample-fast")
    #expect(composer.configuration?.effort == "high")
    #expect(composer.isApplyingConfiguration)
    modelPatch.release()
    await model.value
    #expect(composer.configuration?.modelOverride == "sample-fast")
    #expect(composer.configurationError == nil)
    live.server.route(path, method: "GET", snapshot(fast))
    try await live.settle()

    live.server.route(path, method: "PATCH", snapshot(codex(model: "sample-fast", effort: "low")))
    let effortPatch = live.server.hold(path, method: "PATCH")
    let effort = Task { await composer.selectEffort("low") }
    try await eventually("the effort to reach the server") { effortPatch.arrivals == 1 }
    #expect(composer.configuration?.effort == "low")
    effortPatch.release()
    await effort.value
    #expect(composer.configuration?.effort == "low")
    #expect(composer.configuration?.modelOverride == "sample-fast")
    #expect(composer.configurationError == nil)
    #expect(!composer.isApplyingConfiguration)
  }

  @Test("A refused model goes back to the server's value with the reason, and is sent once")
  func refusedModel() async throws {
    let live = try await loaded(codexFields)
    let composer = live.composer
    live.server.fail(path, method: "PATCH")
    let patch = live.server.hold(path, method: "PATCH")
    let change = Task { await composer.selectModel("sample-fast") }
    try await eventually("the model to reach the server") { patch.arrivals == 1 }
    #expect(composer.configuration?.modelOverride == "sample-fast")
    // What the harness reports meanwhile is not part of the change, so it stays.
    composer.harnessReported(mode: "plan")
    patch.release()
    await change.value
    #expect(composer.configuration?.modelOverride == "sample-balanced")
    #expect(composer.configuration?.effort == "high")
    #expect(composer.configuration?.approvalMode == "plan")
    #expect(composer.configurationError != nil)
    #expect(!composer.isApplyingConfiguration)
    try await live.settle()
    #expect(live.server.requests(to: path, method: "PATCH").count == 1)

    await composer.selectEffort("low")
    #expect(composer.configuration?.effort == "high")
    #expect(composer.configurationError != nil)
  }

  @Test("An approval mode shows while the server is asked; a refusal shows the session's mode")
  func approvalMode() async throws {
    let live = try await loaded(claudeFields("default"))
    let composer = live.composer
    let accepting = snapshot(claudeFields("acceptEdits"))
    live.server.route(path, method: "PATCH", accepting)
    let accepted = live.server.hold(path, method: "PATCH")
    let change = Task { await composer.selectApprovalMode("acceptEdits") }
    try await eventually("the mode to reach the server") { accepted.arrivals == 1 }
    #expect(composer.configuration?.approvalMode == "acceptEdits")
    #expect(composer.approvalModeMenu?.selected == "acceptEdits")
    accepted.release()
    await change.value
    #expect(composer.configuration?.approvalMode == "acceptEdits")
    #expect(composer.configurationError == nil)
    live.server.route(path, method: "GET", accepting)
    try await live.settle()

    live.server.fail(path, method: "PATCH")
    let refused = live.server.hold(path, method: "PATCH")
    let retry = Task { await composer.selectApprovalMode("plan") }
    try await eventually("the mode to reach the server") { refused.arrivals == 1 }
    #expect(composer.approvalModeMenu?.selected == "plan")
    // The mode goes back before the session's own mode has been read again.
    let reread = live.server.hold(path, method: "GET")
    refused.release()
    try await eventually("the mode to go back") {
      composer.configuration?.approvalMode == "acceptEdits"
    }
    #expect(composer.isApplyingConfiguration)
    reread.release()
    await retry.value
    #expect(composer.approvalModeMenu?.selected == "acceptEdits")
    #expect(composer.configurationError != nil)
    #expect(live.server.requests(to: path, method: "PATCH").count == 2)
  }
}
