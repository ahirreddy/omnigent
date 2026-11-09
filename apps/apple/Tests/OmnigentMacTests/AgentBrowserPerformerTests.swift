import Foundation
import OmnigentBrowser
import OmnigentCoreFFI
import OmnigentStores
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// Agent browser actions, from what the server claims to what is posted back.
@MainActor
struct AgentBrowserPerformerTests {
  private final class FakeController: AgentBrowserActing {
    var requests: [AgentBrowserActionRequest] = []
    func perform(_ request: AgentBrowserActionRequest) async -> AgentBrowserActionResult {
      await Task.yield()
      requests.append(request)
      return AgentBrowserActionResult(ok: true, data: ["title": .string("Example")])
    }
    func close(conversationID: String) {}
  }

  private func request(args: String = #"{"url":"https://example.com"}"#) -> BrowserActionRequest {
    BrowserActionRequest(
      sessionId: "conv", actionId: "baction_1", action: "navigate", argsJson: args)
  }

  @Test func anActionRunsAndItsResultIsJSON() async throws {
    let controller = FakeController()
    let performer = AgentBrowserPerformer(controller: controller)
    let data = try await performer.perform(request())
    #expect(controller.requests.map(\.actionID) == ["baction_1"])
    #expect(controller.requests.first?.conversationID == "conv")
    let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(result["ok"] as? Bool == true)
  }

  @Test func malformedArgumentsThrowInsteadOfRunning() async {
    let controller = FakeController()
    let performer = AgentBrowserPerformer(controller: controller)
    await #expect(throws: (any Error).self) {
      _ = try await performer.perform(request(args: "not json"))
    }
    #expect(controller.requests.isEmpty)
  }

  @Test func aFakeControllerIsNotTheAgentBrowser() {
    #expect(AgentBrowserPerformer(controller: FakeController()).agentController == nil)
  }

  @Test func onlyTheDeveloperIDEditionPerformsAgentActions() {
    let performer = AgentBrowserPerformer.forEdition(provider: AppEdition.makeBrowserProvider())
    #if OMNIGENT_CHROMIUM
      #expect(performer?.agentController != nil)
    #else
      #expect(performer == nil)
    #endif
  }
}
