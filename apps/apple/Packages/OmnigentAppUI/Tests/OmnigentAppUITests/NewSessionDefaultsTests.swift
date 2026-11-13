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

  /// A server that starts sandboxes of two providers.
  private func sandboxCatalog(hosts: [CreationHost]) -> OmnigentCoreFFI.CreationCatalog {
    var catalog = catalog(hosts: hosts)
    catalog.managedSandboxes = true
    catalog.sandboxProviders = ["arclet", "modal"]
    return catalog
  }

  @Test func withNoMachineOnlineThePageStartsOnANewSandbox() throws {
    let form = try form()
    form.applyDefaults(sandboxCatalog(hosts: [host("stopped-sandbox", online: false)]))
    #expect(form.isSandbox)
    #expect(form.sandbox.provider == "arclet")

    // A machine that is online is where a session starts, unless the last one was a sandbox.
    let other = try self.form()
    other.applyDefaults(sandboxCatalog(hosts: [host("mac")]))
    #expect(!other.isSandbox)
    #expect(other.selection.hostId == "mac")

    // A server that starts no sandboxes leaves the machine, offline as it is.
    let plain = try self.form()
    plain.applyDefaults(catalog(hosts: [host("old", online: false)]))
    #expect(!plain.isSandbox)
    #expect(plain.selection.hostId == "old")
  }

  @Test func thePageOpensOnTheKindOfTargetStartedOnLast() throws {
    let form = try form()
    form.isSandbox = true
    form.sandbox.provider = "modal"
    form.selection.agentId = "codex"
    form.rememberChoices()
    let next = NewSessionForm()
    next.preferences = form.preferences
    next.applyDefaults(sandboxCatalog(hosts: [host("mac")]))
    #expect(next.isSandbox)
    #expect(next.sandbox.provider == "modal")

    // A machine started on after that is what the next page opens on.
    next.isSandbox = false
    next.selection.hostId = "mac"
    next.rememberChoices()
    let later = NewSessionForm()
    later.preferences = form.preferences
    later.applyDefaults(sandboxCatalog(hosts: [host("mac")]))
    #expect(!later.isSandbox)
    #expect(later.selection.hostId == "mac")
  }

  @Test func theChoiceBetweenMachineAndSandboxIsMadeOnceAndNeverOverTheUsers() throws {
    let form = try form()
    form.hostWasChosen = true
    form.selection.hostId = "old"
    form.applyDefaults(sandboxCatalog(hosts: [host("old", online: false)]))
    #expect(!form.isSandbox)

    // Leaving the sandbox (a project's machine, an agent to install) is not undone later.
    let other = try self.form()
    other.applyDefaults(sandboxCatalog(hosts: []))
    #expect(other.isSandbox)
    other.isSandbox = false
    other.applyDefaults(sandboxCatalog(hosts: []))
    #expect(!other.isSandbox)

    // A remembered provider the server no longer offers falls to its first.
    let stale = try self.form()
    stale.preferences.set("gone", forKey: NewSessionForm.DefaultsKey.sandboxProvider)
    stale.applyDefaults(sandboxCatalog(hosts: [host("mac")]))
    #expect(stale.sandbox.provider == "arclet")
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
