import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Composer adapter")
struct ComposerAdapterTests {
  private func configuration(wrapper: String, mode: String?, harness: String)
    -> OmnigentCoreFFI.SessionConfiguration
  {
    OmnigentCoreFFI.SessionConfiguration(
      agentId: "agent", harness: harness, wrapper: wrapper, modelOverride: nil, baseModel: nil,
      effort: nil, modelReported: true, effortReported: true, models: [], hostId: "host",
      hostOnline: true, runnerOnline: true, runnerBound: true, hostResumable: nil, parentId: nil,
      routingMode: nil, approvalMode: mode)
  }

  @Test("Each harness's own modes map to clear names, shields and risk")
  func approvalModes() throws {
    let codex = try #require(
      approvalModeMenu(
        configuration: configuration(
          wrapper: "codex-native-ui", mode: "approve-for-me", harness: "codex-native")))
    let modes = ComposerAdapter.approvalModes(codex)
    #expect(modes.title == "Codex approvals")
    #expect(modes.options.map(\.id) == ["ask-for-approval", "approve-for-me", "full-access"])
    #expect(modes.options.map(\.label) == ["Auto-edit", "Auto-approve", "Full access"])
    #expect(modes.selected?.harnessLabel == "Approve for me")
    #expect(modes.options.last?.risk == .fullAccess)
    #expect(modes.next?.id == "full-access")

    let claude = try #require(
      approvalModeMenu(
        configuration: configuration(
          wrapper: "claude-code-native-ui", mode: "bypassPermissions", harness: "claude-native")))
    let claudeModes = ComposerAdapter.approvalModes(claude)
    #expect(claudeModes.selected?.label == "Full access")
    #expect(claudeModes.selected?.isSwitchable == false)
    #expect(claudeModes.next == nil)

    #expect(
      approvalModeMenu(
        configuration: configuration(wrapper: "pi-native-ui", mode: nil, harness: "pi-native"))
        == nil)
  }

  @Test("Steering follows the harness")
  func steering() {
    #expect(
      configurationSupportsSteering(
        configuration: configuration(wrapper: "codex-native-ui", mode: nil, harness: "codex-native")
      ))
    #expect(
      !configurationSupportsSteering(
        configuration: configuration(wrapper: "", mode: nil, harness: "claude-sdk")))
  }

  @Test("Queued items keep their id, text and failure")
  func queued() throws {
    var queue = MessageQueue()
    let item = try queue.enqueue("later")
    _ = try queue.begin(item.id)
    queue.finish(item.id, failure: "Refused")
    let message = ComposerAdapter.queued(try #require(queue.items.first))
    #expect(message.id == String(item.id))
    #expect(message.text == "later")
    #expect(message.state == .failed(message: "Refused"))
  }
}
