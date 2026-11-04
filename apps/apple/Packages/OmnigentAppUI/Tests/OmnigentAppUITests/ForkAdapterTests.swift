import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

private func source(readOnly: Bool = false, hostID: String? = "host_a")
  -> OmnigentCoreFFI.SessionSummary
{
  OmnigentCoreFFI.SessionSummary(
    id: "conv_src", title: "Plan", preview: "", status: .idle, isReadOnly: readOnly,
    updatedAt: 1, workspace: "/work/project", agentName: "codex-native-ui (fork ag_1)",
    isPinned: false, isArchived: false, permissionLevel: readOnly ? 1 : 4, failureMessage: nil,
    canRename: true, canPin: true, canArchive: true,
    configuration: SessionConfiguration(
      agentId: "ag_clone", harness: "codex-native", wrapper: nil, modelOverride: nil,
      baseModel: nil, effort: nil, modelReported: nil, effortReported: nil, models: [],
      hostId: hostID, hostOnline: true, runnerOnline: true, runnerBound: true,
      hostResumable: nil, parentId: nil, routingMode: nil))
}

private func catalog(hostStatus: String) -> OmnigentCoreFFI.CreationCatalog {
  OmnigentCoreFFI.CreationCatalog(
    hosts: [
      CreationHost(
        hostId: "host_a", name: "Mac", status: hostStatus, sandboxProvider: nil,
        configuredHarnesses: nil)
    ],
    agents: [
      OmnigentCoreFFI.CreationAgent(
        id: "ag_claude", name: "claude-native-ui", harness: "claude-native", description: nil,
        pickerSection: .harness)
    ])
}

private func row(
  role: OmnigentUIComponents.RowRole = .assistant, streaming: Bool = false, ephemeral: Bool = false,
  responseID: String? = "resp_2"
) -> OmnigentUIComponents.Row {
  OmnigentUIComponents.Row(
    id: "item_a", role: role, text: "Done.", isStreaming: streaming, responseId: responseID,
    isEphemeral: ephemeral)
}

@Suite("Fork sheet adapter")
struct ForkAdapterTests {
  @Test("Only settled assistant messages with a response are fork points")
  func forkPoints() {
    #expect(ForkAdapter.forkPoint(row()) == "resp_2")
    #expect(ForkAdapter.forkPoint(row(role: .user)) == nil)
    #expect(ForkAdapter.forkPoint(row(streaming: true)) == nil)
    #expect(ForkAdapter.forkPoint(row(ephemeral: true)) == nil)
    #expect(ForkAdapter.forkPoint(row(responseID: nil)) == nil)
  }

  @Test("Read-only viewers and unbound sessions get no Fork")
  func gate() {
    #expect(forkUnavailableReason(source: source()) == nil)
    #expect(forkUnavailableReason(source: source(readOnly: true)) != nil)
  }

  @Test("The sheet shows the core's plan, the source first")
  func state() {
    let context = ForkContext(
      source: source(), upToResponseID: "resp_2", kind: .fromMessage(rowID: "item_a"))
    let plan = forkPlan(source: source(), catalog: catalog(hostStatus: "online"))
    let state = ForkAdapter.state(
      context: context, plan: plan, isForking: false, errorMessage: nil)
    #expect(state.title == "Fork from this response")
    #expect(state.agents.map(\.id) == ["ag_clone", "ag_claude"])
    #expect(state.agents.first?.name == "codex-native-ui (same as original)")
    #expect(state.agentID == "ag_clone")
    #expect(state.directory == "/work/project")
    #expect(state.startUnavailableReason == nil)

    let offline = forkPlan(source: source(), catalog: catalog(hostStatus: "offline"))
    let blocked = ForkAdapter.state(
      context: context, plan: offline, isForking: true, errorMessage: "Refused")
    #expect(blocked.startUnavailableReason != nil)
    #expect(blocked.isForking)
    #expect(blocked.errorMessage == "Refused")
  }

  @Test("Choices become the request: same agent omitted, start on the plan's host")
  func request() {
    let context = ForkContext(
      source: source(), upToResponseID: "resp_2", kind: .fromMessage(rowID: "item_a"))
    let plan = forkPlan(source: source(), catalog: catalog(hostStatus: "online"))
    let clone = ForkAdapter.request(
      context: context, plan: plan, agentID: "ag_clone", directory: "/work", start: false)
    #expect(
      clone
        == ForkRequest(
          sourceId: "conv_src", upToResponseId: "resp_2", agentId: nil, title: nil, start: nil))
    let started = ForkAdapter.request(
      context: context, plan: plan, agentID: "ag_claude", directory: "/work", start: true)
    #expect(started.agentId == "ag_claude")
    #expect(started.start == ForkStart(hostId: "host_a", workspace: "/work"))
  }
}
