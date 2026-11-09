import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentAppUI

/// What the new-session page picks by itself, and when it leaves the user's choice alone.
@MainActor
struct NewSessionDefaultsTests {
  private func form() throws -> NewSessionForm {
    let form = NewSessionForm()
    let suite = "new-session-defaults-\(UUID().uuidString)"
    form.preferences = try #require(UserDefaults(suiteName: suite))
    return form
  }

  private func agent(_ id: String, rank: UInt32) -> OmnigentCoreFFI.CreationAgent {
    OmnigentCoreFFI.CreationAgent(
      id: id, name: id, harness: id, description: nil, supportsCreation: true,
      pickerSection: .harness, isPrimaryHarness: true, pickerRank: rank)
  }

  /// Claude sorts first but only Codex runs on the host.
  private func catalog(hosts: [CreationHost]) -> OmnigentCoreFFI.CreationCatalog {
    OmnigentCoreFFI.CreationCatalog(
      hosts: hosts, agents: [agent("claude", rank: 0), agent("codex", rank: 1)],
      managedSandboxes: false)
  }

  private func host(_ id: String, online: Bool = true) -> CreationHost {
    CreationHost(
      hostId: id, name: id, status: online ? "online" : "offline", sandboxProvider: nil,
      configuredHarnesses: [
        HarnessStatus(harness: "claude", readiness: .notReady),
        HarnessStatus(harness: "codex", readiness: .ready),
      ], isAvailable: online)
  }

  @Test func aHostConnectingLaterIsPickedWithAnAgentReadyOnIt() throws {
    let form = try form()
    form.applyDefaults(catalog(hosts: []))
    #expect(form.selection.hostId.isEmpty)
    #expect(form.selection.agentId == "claude")

    form.applyDefaults(catalog(hosts: [host("mac")]))
    #expect(form.selection.hostId == "mac")
    #expect(form.selection.agentId == "codex")
  }

  @Test func theAgentTheUserChoseStaysWhenItIsNotReady() throws {
    let form = try form()
    form.agentWasChosen = true
    form.selection.agentId = "claude"
    form.applyDefaults(catalog(hosts: [host("mac")]))
    #expect(form.selection.agentId == "claude")
  }

  @Test func theHostTheUserChoseStaysWhenItGoesOffline() throws {
    let form = try form()
    form.hostWasChosen = true
    form.selection.hostId = "old"
    form.applyDefaults(catalog(hosts: [host("old", online: false), host("mac")]))
    #expect(form.selection.hostId == "old")
  }

  @Test func aRememberedAgentWinsOnlyWhereItIsReady() throws {
    let form = try form()
    form.preferences.set("claude", forKey: NewSessionForm.DefaultsKey.agent)
    form.applyDefaults(catalog(hosts: [host("mac")]))
    #expect(form.selection.agentId == "codex")

    var ready = host("mac")
    ready.configuredHarnesses = [HarnessStatus(harness: "claude", readiness: .ready)]
    let other = try self.form()
    other.preferences.set("claude", forKey: NewSessionForm.DefaultsKey.agent)
    other.applyDefaults(catalog(hosts: [ready]))
    #expect(other.selection.agentId == "claude")
  }

  @Test func changingToAnotherAgentForgetsTheModel() throws {
    let form = try form()
    form.selection.agentId = "claude"
    form.selection.model = "opus"
    form.applyDefaults(catalog(hosts: [host("mac")]))
    #expect(form.selection.agentId == "codex")
    #expect(form.selection.model == nil)
  }
}
