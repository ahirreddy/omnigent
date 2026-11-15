import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// What the sandbox control, the composer's liveness line and a session's row read from a
/// header and a list row fed by hand.
@MainActor
@Suite("Sandbox status adapter", .timeLimit(.minutes(1)))
struct SandboxStatusAdapterTests {
  /// A top-level session on host `sbx` with its runner connected.
  private func settings(
    _ adjust: (inout OmnigentCoreFFI.SessionSettings) -> Void = { _ in }
  ) -> OmnigentCoreFFI.SessionSettings {
    var settings = OmnigentCoreFFI.SessionSettings(
      agentId: "agent", harness: "codex-native", wrapper: nil, modelOverride: .notReported,
      baseModel: nil, reasoningEffort: .notReported, modelOptions: [], hostId: "sbx",
      hostOnline: true, runnerOnline: true, runnerBound: true, hostResumable: nil,
      parentId: nil, sideChatSourceId: nil, routingMode: nil)
    adjust(&settings)
    return settings
  }

  private func header(
    _ settings: OmnigentCoreFFI.SessionSettings?, launch: SandboxLaunch? = nil,
    status: OmnigentCoreFFI.TurnStatus = .idle, permissionLevel: Int64? = 4, readOnly: Bool = false
  ) -> OmnigentCoreFFI.SessionHeader {
    OmnigentCoreFFI.SessionHeader(
      id: "conv", title: "Plan", status: status, readOnly: readOnly, archived: false,
      permissionLevel: permissionLevel, failureMessage: nil, settings: settings,
      sandboxLaunch: launch)
  }

  private func launch(
    _ stage: SandboxLaunchStage, details: String? = nil, error: String? = nil
  ) -> SandboxLaunch {
    SandboxLaunch(stage: stage, provider: "example", details: details, error: error)
  }

  private let listed: @MainActor (String) -> SessionEnvironment? = { id in
    id == "sbx" ? .sandbox(label: "Modal Sandbox") : .remote
  }

  private func state(
    _ header: OmnigentCoreFFI.SessionHeader?,
    environment: @MainActor (String) -> SessionEnvironment? = { _ in nil }
  ) async throws -> SandboxStatusState? {
    SandboxAdapter.state(
      try await ConversationFixtures.store(header: header), environment: environment)
  }

  @Test("A session on a machine, a child session and an unloaded one have no sandbox")
  func absent() async throws {
    #expect(try await state(header(settings())) == nil)
    #expect(try await state(header(settings { $0.hostId = "mac" }), environment: listed) == nil)
    #expect(try await state(nil, environment: listed) == nil)
    #expect(try await state(header(nil), environment: listed) == nil)
    let child = header(settings { $0.parentId = "conv_parent" })
    #expect(try await state(child, environment: listed) == nil)
    let sideChat = header(settings { $0.sideChatSourceId = "conv_source" })
    #expect(try await state(sideChat, environment: listed) == nil)
  }

  @Test("A host the list calls a sandbox is one: running, with Stop for its owner")
  func running() async throws {
    let shown = try #require(try await state(header(settings()), environment: listed))
    #expect(shown.mark == .running)
    #expect(shown.title == "Modal Sandbox")
    #expect(shown.summary == "Running")
    #expect(shown.host == .online && shown.runner == .online)
    #expect(!shown.isTurnRunning)
    #expect(shown.operations.map(\.id) == ["wake", "stop"])
    #expect(shown.operations.map(\.title) == ["Wake", "Stop Agent"])
    #expect(shown.operations[0].unavailableReason == "The sandbox is already running.")
    #expect(shown.operations[1].unavailableReason == nil)
    #expect(shown.operations[1].isDestructive && !shown.operations[0].isDestructive)
    #expect(!shown.operations[1].help.isEmpty)
  }

  @Test("A launch shows by stage: under way, waiting on the user, then failed")
  func launching() async throws {
    let unbound = settings {
      $0.hostId = nil
      $0.hostOnline = nil
      $0.runnerOnline = false
    }
    let cloning = try #require(try await state(header(unbound, launch: launch(.cloning))))
    #expect(cloning.mark == .progress)
    #expect(cloning.title == "Example Sandbox")
    #expect(cloning.statusLine == "Cloning repository\u{2026}")
    #expect(cloning.host == .unreported && cloning.runner == .offline)

    let waiting = try #require(
      try await state(
        header(unbound, launch: launch(.actionRequired, details: "Sign in on your laptop."))))
    #expect(waiting.mark == .attention)
    #expect(waiting.summary == "Provisioning sandbox")
    #expect(waiting.details == "Sign in on your laptop.")

    let failed = try #require(
      try await state(header(unbound, launch: launch(.failed, error: "No capacity"))))
    #expect(failed.mark == .failed)
    #expect(failed.summary == "Sandbox launch failed")
    #expect(failed.error == "No capacity")
    #expect(failed.operations[0].unavailableReason?.contains("no sandbox to start") == true)
  }

  @Test("At rest it is asleep, offline or not reported; a turn under way wakes it")
  func resting() async throws {
    let asleep = try #require(
      try await state(
        header(
          settings {
            $0.hostOnline = false
            $0.runnerOnline = false
            $0.hostResumable = true
          })))
    #expect(asleep.mark == .resting)
    #expect(asleep.title == "Sandbox", "nothing names the provider")
    #expect(asleep.summary == "Asleep")
    #expect(asleep.hint == "The next message wakes it.")
    #expect(asleep.host == .offline)
    #expect(asleep.operations[0].unavailableReason == nil)
    #expect(asleep.operations[1].unavailableReason == "The agent is not running.")

    let silent = settings {
      $0.hostOnline = nil
      $0.runnerOnline = nil
    }
    let unknown = try #require(try await state(header(silent), environment: listed))
    #expect(unknown.mark == .resting)
    #expect(unknown.host == .unreported && unknown.runner == .unreported)

    let stopped = settings { $0.runnerOnline = false }
    let waking = try #require(
      try await state(header(stopped, status: .running), environment: listed))
    #expect(waking.mark == .progress)
    #expect(waking.summary == "Waking")
    #expect(waking.isTurnRunning)
  }

  @Test("The profile names the sandbox, and a viewer is told why the buttons are off")
  func profileAndViewer() async throws {
    let profiled = settings {
      $0.sandboxProfile = SandboxProfileName(provider: "modal", name: "GPU box")
    }
    let viewer = try #require(
      try await state(header(profiled, permissionLevel: 1, readOnly: true)))
    #expect(viewer.title == "Modal Sandbox")
    #expect(viewer.profile == "GPU box")
    #expect(viewer.operations[0].unavailableReason?.contains("view this session") == true)
    #expect(viewer.operations[1].unavailableReason?.contains("owner") == true)
    // A session nobody shared reports no level, and its viewer owns it.
    let owner = try #require(try await state(header(profiled, permissionLevel: nil)))
    #expect(owner.operations[1].unavailableReason == nil)
  }

  @Test("Every phase has a mark, and a link reads online, offline or not reported")
  func marksAndLinks() {
    let marks: [(SandboxPhase, SandboxStatusState.Mark)] = [
      (.launching, .progress), (.waking, .progress), (.actionRequired, .attention),
      (.failed, .failed), (.running, .running), (.agentAsleep, .resting), (.asleep, .resting),
      (.offline, .resting), (.unknown, .resting),
    ]
    for (phase, mark) in marks { #expect(SandboxAdapter.mark(phase) == mark, "\(phase)") }
    #expect(SandboxAdapter.link(true) == .online)
    #expect(SandboxAdapter.link(false) == .offline)
    #expect(SandboxAdapter.link(nil) == .unreported)
    #expect(SandboxAdapter.hostSandbox(.sandbox(label: "Modal Sandbox")) == "Modal Sandbox")
    #expect(SandboxAdapter.hostSandbox(.remote) == nil)
    #expect(SandboxAdapter.hostSandbox(nil) == nil)
  }

  @Test("A launch that has not finished has a note; a ready one and none have not")
  func launchNotes() {
    #expect(SandboxAdapter.launchNote(nil) == nil)
    #expect(SandboxAdapter.launchNote(launch(.ready)) == nil)
    #expect(
      SandboxAdapter.launchNote(launch(.starting)) == SandboxLaunchNote(label: "Connecting host"))
    #expect(
      SandboxAdapter.launchNote(launch(.actionRequired, details: "Sign in."))
        == SandboxLaunchNote(label: "Provisioning sandbox", standing: .waiting, note: "Sign in."))
    #expect(
      SandboxAdapter.launchNote(launch(.failed, error: "No capacity"))
        == SandboxLaunchNote(
          label: "Sandbox launch failed", standing: .failed, note: "No capacity"))
  }

  @Test("While it launches the composer's line names the stage; a failure names itself")
  func livenessLine() async throws {
    let unbound = settings {
      $0.hostId = nil
      $0.hostOnline = nil
      $0.runnerOnline = false
      $0.runnerBound = false
    }
    let launching = header(unbound, launch: launch(.provisioning))
    #expect(
      LivenessAdapter.liveness(launching, runnerUnavailable: false)
        == .launching(SandboxLaunchNote(label: "Provisioning sandbox")))
    let line = LivenessAdapter.notice(
      try await ConversationFixtures.store(header: launching), serverURL: nil)
    #expect(line?.line == "Provisioning sandbox\u{2026}")
    #expect(line?.failedLaunch == nil)

    // A failed first launch leaves the session bound to nothing, as it was before.
    let failed = header(unbound, launch: launch(.failed, error: "No capacity"))
    #expect(LivenessAdapter.liveness(failed, runnerUnavailable: false) == .stranded)
    let failure = try #require(
      LivenessAdapter.notice(try await ConversationFixtures.store(header: failed), serverURL: nil))
    #expect(failure.title == "Sandbox launch failed")
    #expect(failure.failedLaunch?.line == "Sandbox launch failed: No capacity")

    // It is said even before the session reports where it runs, but not over a live agent.
    let silent = settings {
      $0.hostOnline = nil
      $0.runnerOnline = nil
    }
    let unreported = header(silent, launch: launch(.failed, error: "No capacity"))
    let early = LivenessAdapter.notice(
      try await ConversationFixtures.store(header: unreported), serverURL: nil)
    #expect(early?.line == "Sandbox launch failed: No capacity")
    let quiet = LivenessAdapter.notice(
      try await ConversationFixtures.store(header: header(silent)), serverURL: nil)
    #expect(quiet == nil)
    let live = header(settings(), launch: launch(.failed, error: "No capacity"))
    #expect(
      LivenessAdapter.notice(try await ConversationFixtures.store(header: live), serverURL: nil)
        == nil)
  }

  @Test("A launching session's row names the stage, not a local machine or a disconnect")
  func row() {
    var unbound = ConversationFixtures.configuration(harness: "codex-native")
    unbound.hostId = nil
    unbound.hostOnline = nil
    unbound.runnerOnline = false
    unbound.runnerBound = false
    let environments: [String: SessionEnvironment] = ["mac": .thisMachine]
    func info(_ configuration: SessionConfiguration) -> SessionRowInfo {
      SidebarAdapter.rowInfo(
        ConversationFixtures.summary("conv", configuration: configuration), isOwned: true,
        environments: environments)
    }
    let plain = info(unbound)
    #expect(plain.environment == "Local machine")
    #expect(plain.isDisconnected && plain.disconnectedLabel == "Disconnected")

    var launching = unbound
    launching.sandboxLaunching = true
    launching.sandboxLaunch = launch(.cloning)
    #expect(info(launching).environment == "Cloning repository")
    #expect(!info(launching).isDisconnected)
    // A stage the launch flag did not keep up with still is no disconnect.
    launching.sandboxLaunching = nil
    #expect(!info(launching).isDisconnected)

    var failed = unbound
    failed.sandboxLaunch = launch(.failed, error: "No capacity")
    #expect(info(failed).environment == "Sandbox launch failed")
    #expect(info(failed).isDisconnected)
    #expect(info(failed).disconnectedLabel == "Sandbox launch failed: No capacity")
  }
}
