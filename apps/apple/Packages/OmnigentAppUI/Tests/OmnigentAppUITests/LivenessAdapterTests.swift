import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A session header; the session is bound to no host unless `hostID` is set.
private func header(
  harness: String = "codex-native", hostID: String? = nil, hostOnline: Bool = false,
  runnerOnline: Bool = true, permissionLevel: Int64 = 4
) -> OmnigentCoreFFI.SessionHeader {
  OmnigentCoreFFI.SessionHeader(
    id: "conv_a", title: "Plan", status: .idle, readOnly: false, archived: false,
    permissionLevel: permissionLevel, failureMessage: nil,
    settings: SessionSettings(
      agentId: "ag_a", harness: harness, wrapper: nil, modelOverride: .notReported,
      baseModel: nil, reasoningEffort: .notReported, modelOptions: [], hostId: hostID,
      hostOnline: hostOnline, runnerOnline: runnerOnline, runnerBound: hostID != nil,
      hostResumable: nil, parentId: nil, sideChatSourceId: nil, routingMode: nil))
}

@Suite("Liveness adapter")
struct LivenessAdapterTests {
  @Test("An owned session bound to no host resumes on a machine; a bound or shared one does not")
  func resumesOnMachine() {
    #expect(LivenessAdapter.resumesOnMachine(header()))
    #expect(!LivenessAdapter.resumesOnMachine(header(hostID: "host_a")))
    #expect(!LivenessAdapter.resumesOnMachine(header(permissionLevel: 2)))
  }

  @Test("An unbound native session reads stranded although the server calls its runner online")
  func unboundNativeIsStranded() {
    #expect(LivenessAdapter.liveness(header(), runnerUnavailable: false) == .stranded)
    // A server-side harness runs without a machine.
    #expect(
      LivenessAdapter.liveness(header(harness: "agent-sdk"), runnerUnavailable: false) == .online)
    #expect(LivenessAdapter.isNative("native-pi"))
    #expect(!LivenessAdapter.isNative(nil))
  }

  @Test("An owned session whose host is offline reads host offline")
  func hostOffline() {
    let offline = header(hostID: "host_a", runnerOnline: false)
    #expect(
      LivenessAdapter.liveness(offline, runnerUnavailable: false) == .hostOffline(isOwner: true))
  }
}
