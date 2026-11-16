#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The sandbox panel hosted on its own, where its buttons take real clicks.
  @Suite("Sandbox status panel", .serialized)
  @MainActor
  struct SandboxStatusPanelTests {
    private let log = HostLog()

    private func panel(
      _ state: SandboxStatusState, model: SandboxPanelModel = SandboxPanelModel(),
      actions: SandboxStatusActions? = nil
    ) -> OffscreenWindow<AnyView> {
      transcriptScreen(
        SandboxStatusPanel(
          state: state, actions: actions ?? SandboxFixture.actions(log), model: model),
        width: 360, height: 520)
    }

    @Test("It names the provider and profile, the state, and the host's and the agent's links")
    func facts() throws {
      var state = SandboxFixture.state(.resting, "Asleep")
      state.profile = "GPU box"
      state.hint = "The next message wakes it."
      state.host = .offline
      let screen = panel(state)
      defer { screen.close() }
      for text in ["Modal Sandbox", "Profile: GPU box", "Asleep", "The next message wakes it."] {
        #expect(try screen.shows(text), "\(text)")
      }
      #expect(try screen.words(of: "sandbox-panel-state").contains("Asleep"))
      #expect(try screen.words(of: "sandbox-panel-host").contains("Offline"))
      #expect(
        try screen.words(of: "sandbox-panel-agent").contains("Not reported"))
      #expect(try screen.hasElement("sandbox-mark-resting"))
      #expect(try !screen.hasElement("sandbox-panel-details"))
      #expect(try !screen.hasElement("sandbox-panel-error"))

      let running = panel(SandboxFixture.running)
      defer { running.close() }
      #expect(try running.words(of: "sandbox-panel-host").contains("Online"))
      #expect(try running.words(of: "sandbox-panel-agent").contains("Online"))
      #expect(try !running.hasElement("sandbox-panel-profile"))
    }

    @Test("A launch on its way names its stage; one that waits or failed says what and why")
    func launch() throws {
      let cloning = panel(SandboxFixture.state(.progress, "Cloning repository"))
      defer { cloning.close() }
      #expect(try cloning.shows("Cloning repository\u{2026}"))

      var waiting = SandboxFixture.state(.attention, "Provisioning sandbox")
      waiting.details = "Sign in on your laptop."
      let needsYou = panel(waiting)
      defer { needsYou.close() }
      #expect(try needsYou.shows("Needs you"))
      #expect(
        try needsYou.words(of: "sandbox-panel-details").contains("Sign in on your laptop."))

      var failed = SandboxFixture.state(.failed, "Sandbox launch failed")
      failed.error = "The workspace is out of quota."
      let broken = panel(failed)
      defer { broken.close() }
      #expect(try broken.shows("Sandbox launch failed"))
      #expect(
        try broken.words(of: "sandbox-panel-error").contains("The workspace is out of quota."))
    }

    @Test("An operation's button asks for it once, and waits for the server's answer")
    func operation() async throws {
      let model = SandboxPanelModel()
      let gate = AsyncStream<Void>.makeStream()
      let log = self.log
      let actions = SandboxStatusActions { id in
        log.add(id)
        for await _ in gate.stream { break }
        return nil
      }
      let screen = panel(SandboxFixture.state(.resting, "Asleep"), model: model, actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Brings the sandbox and its agent back."))
      try screen.click(try screen.center(of: "sandbox-operation-wake"))
      #expect(try await screen.eventually { log.entries == ["wake"] })
      #expect(model.runningID == "wake")
      // While the request is out, neither button takes another.
      try screen.click(try screen.center(of: "sandbox-operation-wake"))
      try screen.click(try screen.center(of: "sandbox-operation-stop"))
      await screen.drainTasks()
      #expect(log.entries == ["wake"])
      gate.continuation.yield()
      #expect(try await screen.eventually { model.runningID == nil })
      #expect(model.failure == nil)
      #expect(try !screen.hasElement("sandbox-operation-error"))
    }

    @Test("An operation the server refuses says why in the panel")
    func refusal() async throws {
      let model = SandboxPanelModel()
      let screen = panel(
        SandboxFixture.state(.resting, "Asleep"), model: model,
        actions: SandboxFixture.actions(log, refusal: "No runner is available."))
      defer { screen.close() }
      try screen.click(try screen.center(of: "sandbox-operation-wake"))
      #expect(try await screen.eventually { model.failure != nil })
      #expect(log.entries == ["wake"])
      // The panel draws the failure a pass after the model has it.
      #expect(
        try await screen.eventually { try screen.shows("Wake failed: No runner is available.") })
      #expect(try screen.hasElement("sandbox-operation-error"))
    }

    @Test("An operation that does not apply is off and says why")
    func unavailable() async throws {
      var stop = SandboxFixture.stop
      stop.unavailableReason = "The agent is not running."
      let screen = panel(
        SandboxFixture.state(.resting, "Asleep", operations: [SandboxFixture.wake, stop]))
      defer { screen.close() }
      #expect(try screen.shows("The agent is not running."))
      try screen.click(try screen.center(of: "sandbox-operation-stop"))
      await screen.drainTasks()
      #expect(log.entries.isEmpty)
    }

    @Test("Stopping while a turn runs asks first; Cancel leaves the agent alone")
    func confirmation() async throws {
      var state = SandboxFixture.running
      state.isTurnRunning = true
      let model = SandboxPanelModel()
      let screen = panel(state, model: model)
      defer { screen.close() }
      try screen.click(try screen.center(of: "sandbox-operation-stop"))
      #expect(try await screen.eventually { model.confirmingID == "stop" })
      #expect(try screen.shows("A turn is running. Stop Agent ends it."))
      #expect(log.entries.isEmpty)
      try screen.click(try screen.center(of: "sandbox-operation-stop-cancel"))
      #expect(try await screen.eventually { model.confirmingID == nil })
      #expect(log.entries.isEmpty)

      try screen.click(try screen.center(of: "sandbox-operation-stop"))
      #expect(try await screen.eventually { model.confirmingID == "stop" })
      try screen.click(try screen.center(of: "sandbox-operation-stop-confirm"))
      #expect(try await screen.eventually { log.entries == ["stop"] })
      #expect(model.confirmingID == nil)
    }

    @Test("With no turn running, Stop goes straight to the server")
    func stopsAtOnce() async throws {
      let screen = panel(SandboxFixture.running)
      defer { screen.close() }
      try screen.click(try screen.center(of: "sandbox-operation-stop"))
      #expect(try await screen.eventually { log.entries == ["stop"] })
    }

    @Test("A panel that can ask nothing of the server shows no buttons")
    func readOnly() throws {
      let screen = panel(SandboxFixture.running, actions: SandboxStatusActions())
      defer { screen.close() }
      #expect(try screen.shows("Running"))
      #expect(try !screen.hasElement("sandbox-operation-wake"))
      let bare = panel(
        SandboxFixture.state(.running, "Running", operations: []),
        actions: SandboxFixture.actions(log))
      defer { bare.close() }
      #expect(try !bare.hasElement("sandbox-operation-stop"))
    }
  }
#endif
