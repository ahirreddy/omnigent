#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The titlebar's sandbox control on its own: what it says for each state and what opens its
  /// panel.
  @Suite("Sandbox status control", .serialized)
  @MainActor
  struct SandboxStatusControlTests {
    private let log = HostLog()

    private func control(_ state: SandboxStatusState) -> OffscreenWindow<AnyView> {
      transcriptScreen(
        SandboxStatusControl(state: state, actions: SandboxFixture.actions(log))
          .padding(40),
        width: 420, height: 320)
    }

    @Test(
      "Each state says its words and shows its own mark",
      arguments: [
        (SandboxStatusState.Mark.progress, "Cloning repository", "Cloning repository\u{2026}"),
        (.running, "Running", "Running"),
        (.resting, "Asleep", "Asleep"),
        (.attention, "Provisioning sandbox", "Provisioning sandbox"),
        (.failed, "Sandbox launch failed", "Sandbox launch failed"),
      ])
    func marks(mark: SandboxStatusState.Mark, summary: String, line: String) throws {
      let screen = control(SandboxFixture.state(mark, summary))
      defer { screen.close() }
      #expect(try screen.words(of: "header-sandbox").contains("Modal Sandbox"))
      #expect(try screen.words(of: "header-sandbox").contains(line))
      for other in SandboxStatusState.Mark.allCases {
        #expect(try screen.hasElement("sandbox-mark-\(other.rawValue)") == (other == mark))
      }
      #expect(
        try screen.words(of: "sandbox-mark-\(mark.rawValue)").contains(mark.label))
      // Only a sandbox on its way spins.
      #expect(screen.allViews.contains { $0 is NSProgressIndicator } == (mark == .progress))
    }

    @Test("A click opens the panel to stay, and a second click closes it")
    func click() async throws {
      let screen = control(SandboxFixture.running)
      defer { screen.close() }
      let point = try screen.center(of: "header-sandbox")
      #expect(screen.popoverWindow == nil)
      try screen.click(point)
      #expect(try await screen.eventually { screen.popoverWindow != nil })
      let shown = try screen.shownText(under: try #require(screen.popoverWindow?.contentView))
      #expect(shown.contains("Modal Sandbox") && shown.contains("Running"), "\(shown)")
      // The pointer leaving does not close a panel a click opened.
      try screen.hover(point)
      try screen.endHover()
      // Outlasts, in real time, the hover's delay, which would close a panel the hover opened.
      try await Task.sleep(for: .milliseconds(600))
      await screen.settleTasks()
      #expect(screen.popoverWindow != nil)
      try screen.click(point)
      #expect(try await screen.eventually { screen.popoverWindow == nil })
    }

    @Test("Resting the pointer on it opens the panel; passing over does not; leaving closes it")
    func hover() async throws {
      let screen = control(SandboxFixture.running)
      defer { screen.close() }
      let point = try screen.center(of: "header-sandbox")
      try screen.hover(point)
      try screen.endHover()
      // Past the delay a resting pointer would have opened the panel after, in real time.
      try await Task.sleep(for: .milliseconds(500))
      await screen.settleTasks()
      #expect(screen.popoverWindow == nil)

      try screen.hover(point)
      #expect(screen.popoverWindow == nil)
      #expect(try await screen.eventually { screen.popoverWindow != nil })
      try screen.endHover()
      #expect(try await screen.eventually { screen.popoverWindow == nil })
    }

    @Test("The press a keyboard or assistive user sends opens the panel")
    func press() async throws {
      let screen = control(SandboxFixture.running)
      defer { screen.close() }
      try screen.withAccessibilityTree {
        let button = try screen.accessibilityElement("header-sandbox")
        _ = unsafe button.perform(NSSelectorFromString("accessibilityPerformPress"))
      }
      #expect(try await screen.eventually { screen.popoverWindow != nil })
    }

    @Test("With keyboard navigation on, Tab reaches the control and Space opens the panel")
    func keyboard() async throws {
      let screen = control(SandboxFixture.running)
      defer { screen.close() }
      screen.window.makeFirstResponder(nil)
      try screen.press(keyCode: 48, characters: "\t")
      try screen.press(keyCode: 49, characters: " ")
      await screen.settleTasks(limit: .milliseconds(500))
      // Without the system's keyboard navigation a button is not in the key loop at all.
      withKnownIssue("Tab reaches a button only with keyboard navigation on") {
        #expect(screen.popoverWindow != nil)
      } when: {
        !NSApp.isFullKeyboardAccessEnabled
      }
    }
  }

  /// The model behind the control: what opens and closes the panel, and what a button starts.
  @Suite("Sandbox panel model", .serialized)
  @MainActor
  struct SandboxPanelModelTests {
    @Test("A click pins the panel open; the pointer alone opens one that closes when it leaves")
    func presentation() async {
      let model = SandboxPanelModel(openDelay: .milliseconds(1), closeDelay: .milliseconds(1))
      model.toggle()
      #expect(model.isPresented && model.isPinned)
      model.pointerChanged(overControl: true)
      model.pointerChanged(overControl: false)
      #expect(model.pending == nil, "the pointer leaving asks nothing of a pinned panel")
      model.toggle()
      #expect(!model.isPresented && !model.isPinned)

      model.pointerChanged(overControl: true)
      #expect(!model.isPresented, "not before the pointer has rested")
      await model.pending?.value
      #expect(model.isPresented && !model.isPinned)
      // Crossing from the control to the panel keeps it open.
      model.pointerChanged(overControl: false)
      model.pointerChanged(overPanel: true)
      #expect(model.pending == nil && model.isPresented)
      model.pointerChanged(overPanel: false)
      await model.pending?.value
      #expect(!model.isPresented)
      // A click on a panel the pointer opened keeps it.
      model.pointerChanged(overControl: true)
      await model.pending?.value
      model.toggle()
      #expect(model.isPresented && model.isPinned)
    }

    @Test("A pointer that moves on before the delay ends opens nothing")
    func passingOver() async {
      let model = SandboxPanelModel(openDelay: .seconds(60), closeDelay: .seconds(60))
      model.pointerChanged(overControl: true)
      let resting = model.pending
      #expect(resting != nil)
      model.pointerChanged(overControl: false)
      #expect(model.pending == nil)
      await resting?.value
      #expect(!model.isPresented)
    }

    @Test("A request runs once, reports a refusal, and a destructive one waits for a yes")
    func requests() async {
      let model = SandboxPanelModel()
      let log = HostLog()
      let refuse: @MainActor (String) async -> String? = { id in
        log.add(id)
        return id == "wake" ? "No runner is available." : nil
      }
      model.request(SandboxFixture.wake, isTurnRunning: true, perform: refuse)
      #expect(model.runningID == "wake" && model.isPinned)
      await model.inFlight?.value
      #expect(model.runningID == nil)
      #expect(model.failure == "Wake failed: No runner is available.")
      // The sandbox moving on retires the failure.
      model.sandboxChanged()
      #expect(model.failure == nil)

      model.request(SandboxFixture.stop, isTurnRunning: true, perform: refuse)
      #expect(model.confirmingID == "stop" && model.runningID == nil)
      model.cancelConfirmation()
      #expect(model.confirmingID == nil)
      model.request(SandboxFixture.stop, isTurnRunning: true, perform: refuse)
      model.request(SandboxFixture.stop, isTurnRunning: true, perform: refuse)
      #expect(model.confirmingID == nil && model.runningID == "stop")
      await model.inFlight?.value
      #expect(model.failure == nil)
      #expect(log.entries == ["wake", "stop"])
      // Closing the panel drops a confirmation left open.
      model.isPresented = true
      model.request(SandboxFixture.stop, isTurnRunning: true, perform: refuse)
      model.isPresented = false
      #expect(model.confirmingID == nil)
    }
  }
#endif
