import Testing

@testable import OmnigentUIComponents

@Suite("Session liveness")
struct SessionLivenessTests {
  /// Reported or unknown, as the server's optional liveness fields.
  private enum Seen {
    case online, offline, unreported

    var reported: Bool? {  // swiftlint:disable:this discouraged_optional_boolean
      switch self {
      case .online: true
      case .offline: false
      case .unreported: nil
      }
    }
  }

  private func derive(
    runner: Seen, host: Seen, hostID: String? = "host_1",
    _ adjust: (inout SessionLiveness.Signals) -> Void = { _ in }
  ) -> SessionLiveness {
    var signals = SessionLiveness.Signals(
      runnerOnline: runner.reported, hostOnline: host.reported, hostID: hostID)
    adjust(&signals)
    return SessionLiveness.derive(signals)
  }

  @Test("follows the web's truth table, first matching rule first")
  func truthTable() {
    #expect(derive(runner: .online, host: .offline) == .online)
    #expect(derive(runner: .offline, host: .offline) { $0.hostResumable = true } == .asleep)
    let waking = derive(runner: .offline, host: .offline) {
      $0.hostResumable = true
      $0.isTurnActive = true
    }
    #expect(waking == .starting)
    #expect(derive(runner: .unreported, host: .offline) == .hostOffline(isOwner: true))
    let viewer = derive(runner: .offline, host: .offline) { $0.isOwner = false }
    #expect(viewer == .hostOffline(isOwner: false))
    #expect(derive(runner: .unreported, host: .online) == .unknown)
    #expect(derive(runner: .offline, host: .online) == .asleep)
    #expect(derive(runner: .offline, host: .online) { $0.isTurnActive = true } == .starting)
    #expect(derive(runner: .offline, host: .unreported) == .unknown)
    #expect(derive(runner: .offline, host: .unreported, hostID: nil) == .stranded)
    let child = derive(runner: .offline, host: .unreported, hostID: nil) { $0.isSubagent = true }
    #expect(child == .asleep)
  }

  @Test("the reconnect command matches the web's for each unreachable state")
  func commands() {
    let host = SessionLivenessNotice(
      liveness: .hostOffline(isOwner: true), sessionID: "s1", serverURL: "http://127.0.0.1:6767",
      wrapper: nil, harness: nil)
    #expect(host.command == "omnigent host \\\n  --server http://127.0.0.1:6767")
    #expect(host.title == "Host is offline")
    #expect(host.line == nil)
    let viewer = SessionLivenessNotice(
      liveness: .hostOffline(isOwner: false), sessionID: "s1", serverURL: "https://a.b",
      wrapper: nil, harness: nil)
    #expect(viewer.command == nil)
    let codex = SessionLivenessNotice(
      liveness: .stranded, sessionID: "s1", serverURL: "https://a.b/x y",
      wrapper: "codex-native-ui", harness: "codex-native")
    #expect(codex.command == "omnigent codex \\\n  --resume s1 \\\n  --server 'https://a.b/x y'")
    #expect(codex.title == "Agent disconnected")
    let generic = SessionLivenessNotice(
      liveness: .stranded, sessionID: "s1", serverURL: "https://a.b", wrapper: nil,
      harness: "openai-agents")
    #expect(generic.command?.hasPrefix("omnigent run path/to/agent.yaml \\\n") == true)
  }

  @Test("native agents resolve from the wrapper label, else the harness and its aliases")
  func nativeAgents() {
    let agent = SessionLivenessNotice.nativeAgent(wrapper:harness:)
    #expect(agent("claude-code-native-ui", nil) == "claude")
    #expect(agent(nil, "native-pi") == "pi")
    #expect(agent(nil, "agy-native") == "antigravity")
    #expect(agent("other", "openai-agents") == nil)
  }

  @Test("asleep and starting are quiet lines")
  func lines() {
    let asleep = SessionLivenessNotice(
      liveness: .asleep, sessionID: "s1", serverURL: "", wrapper: nil, harness: nil)
    #expect(asleep.line == "Agent is asleep \u{2014} send a message to reconnect")
    #expect(asleep.command == nil)
    #expect(!SessionLiveness.asleep.isUnreachable)
    #expect(SessionLiveness.stranded.isUnreachable)
  }
}
