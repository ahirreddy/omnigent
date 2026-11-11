#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The editor's keys, sent as real key events to the focused text view.
  @Suite("Composer: typing and sending from the keyboard", .serialized)
  @MainActor
  struct ComposerKeyTests {
    private let log = ComposerActionLog()

    @Test("typed text reaches the draft and Return sends it")
    func typeAndSend() throws {
      let model = ComposerScreenModel(state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.type("hi \u{1F600}")
      #expect(model.draft == "hi \u{1F600}")
      try screen.pressReturn()
      #expect(log.events == ["send"])
    }

    @Test("Return on an empty or blank draft sends nothing")
    func blankReturn() throws {
      for draft in ["", "   ", "\n\t"] {
        let model = ComposerScreenModel(draft: draft, state: ComposerSamples.idle)
        let screen = openComposer(model, log.actions)
        defer { screen.close() }
        try screen.pressReturn()
        #expect(log.events.isEmpty, "\(draft.debugDescription) was sent")
      }
    }

    @Test("Shift-Return and Option-Return add a line instead of sending")
    func newlineKeys() throws {
      for modifier in [NSEvent.ModifierFlags.shift, .option] {
        let model = ComposerScreenModel(draft: "line", state: ComposerSamples.idle)
        let screen = openComposer(model, log.actions)
        defer { screen.close() }
        try screen.pressReturn(modifier)
        #expect(log.events.isEmpty)
      }
    }

    @Test("with the Command-Return setting, Return adds a line and Command-Return sends")
    func commandReturnSetting() throws {
      var state = ComposerSamples.idle
      state.submitWithCommandReturn = true
      let model = ComposerScreenModel(draft: "line", state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(log.events.isEmpty)
      try screen.pressReturn(.command)
      #expect(log.events == ["send"])
    }

    @Test("a pending request's Approve keeps Command-Return; the draft does not send")
    func approveOwnsCommandReturn() throws {
      let model = ComposerScreenModel(draft: "line", state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions, owner: .approve)
      defer { screen.close() }
      try screen.pressReturn(.command)
      #expect(log.events.isEmpty)
      // Plain Return still sends: only the chord belongs to the request.
      try screen.pressReturn()
      #expect(log.events == ["send"])
    }

    @Test("a send that is blocked stays in the draft")
    func blockedSends() throws {
      let blocked: [ComposerViewState] = [
        with { $0.delivery = .uncertain(message: "Unknown") },
        with {
          $0.attachments = [
            DraftAttachment(
              id: "a", title: "a.png", kind: .image, state: .failed(message: "Too big"))
          ]
        },
        with {
          $0.attachments = [
            DraftAttachment(id: "a", title: "a.png", kind: .image, state: .uploading(progress: 0.5))
          ]
        },
      ]
      for state in blocked {
        let model = ComposerScreenModel(draft: "text", state: state)
        let screen = openComposer(model, log.actions)
        defer { screen.close() }
        try screen.pressReturn()
        #expect(log.events.isEmpty, "\(state.delivery) sent")
      }
    }

    @Test("Return during a send sends the new draft to wait behind it, where there is a queue")
    func returnDuringASend() throws {
      var unqueued = log.actions
      unqueued.extras.queueDraft = nil
      let alone = openComposer(
        ComposerScreenModel(draft: "text", state: with { $0.delivery = .sending }), unqueued)
      defer { alone.close() }
      try alone.pressReturn()
      #expect(log.events.isEmpty)

      let screen = openComposer(
        ComposerScreenModel(draft: "text", state: with { $0.delivery = .sending }), log.actions)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(log.events == ["send"])
    }

    private func with(_ change: (inout ComposerViewState) -> Void) -> ComposerViewState {
      var state = ComposerSamples.idle
      change(&state)
      return state
    }

    // MARK: While the agent works

    @Test("mid-turn Return steers; Option-Command-Return queues instead")
    func steerAndQueue() throws {
      let state = with {
        $0.isRunning = true
        $0.canSteer = true
      }
      let model = ComposerScreenModel(draft: "more", state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(log.events == ["send"])
      try screen.pressReturn([.command, .option])
      #expect(log.events == ["send", "queueDraft"])
    }

    @Test("with messages queued, Return joins the queue and the other key steers")
    func queuedKeepsOrder() throws {
      let state = with {
        $0.isRunning = true
        $0.canSteer = true
        $0.queue = [QueuedMessage(id: "q", text: "first")]
      }
      let model = ComposerScreenModel(draft: "more", state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(log.events == ["queueDraft"])
      try screen.pressReturn([.command, .option])
      #expect(log.events == ["queueDraft", "send"])
    }

    @Test("Option-Command-Return does nothing when there is no other choice")
    func noAlternative() throws {
      let model = ComposerScreenModel(draft: "more", state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressReturn([.command, .option])
      #expect(log.events.isEmpty)
    }

    @Test("Command-Return sends the whole queue, queueing a typed draft first")
    func sendAll() throws {
      var actions = log.actions
      actions.extras.history = log.history
      let state = with {
        $0.isRunning = true
        $0.queue = [QueuedMessage(id: "q", text: "first")]
      }
      let model = ComposerScreenModel(draft: "typed", state: state)
      let screen = openComposer(model, actions)
      defer { screen.close() }
      try screen.pressReturn(.command)
      #expect(log.events == ["queueDraft", "sendAll"])
      log.events = []
      model.draft = ""
      screen.settle()
      try screen.pressReturn(.command)
      #expect(log.events == ["sendAll"])
    }

    @Test("Shift-Command-Return is the send-all chord with the Command-Return setting")
    func sendAllWithCommandReturnSetting() throws {
      var actions = log.actions
      actions.extras.history = log.history
      let state = with {
        $0.isRunning = true
        $0.submitWithCommandReturn = true
        $0.queue = [QueuedMessage(id: "q", text: "first")]
      }
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(model, actions)
      defer { screen.close() }
      try screen.pressReturn([.command, .shift])
      #expect(log.events == ["sendAll"])
    }

    @Test("without a queue to join, a typed draft is not lost to send-all")
    func sendAllCannotQueueTheDraft() throws {
      var actions = log.actions
      actions.extras.history = log.history
      actions.extras.queueDraft = nil
      let state = with {
        $0.isRunning = true
        $0.queue = [QueuedMessage(id: "q", text: "first")]
      }
      let model = ComposerScreenModel(draft: "typed", state: state)
      let screen = openComposer(model, actions)
      defer { screen.close() }
      try screen.pressReturn(.command)
      #expect(log.events.isEmpty)
      #expect(model.draft.hasPrefix("typed"))
    }

    // MARK: Esc

    @Test("Esc stops a running turn, once")
    func escapeStops() throws {
      let model = ComposerScreenModel(state: with { $0.isRunning = true })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressEscape()
      #expect(log.events == ["stop"])
      model.state.isStopping = true
      screen.settle()
      try screen.pressEscape()
      #expect(log.events == ["stop"])
    }

    @Test("Esc does nothing while idle or when the host can't stop")
    func escapeIdle() throws {
      var actions = log.actions
      actions.interrupt = nil
      let idle = ComposerScreenModel(state: ComposerSamples.idle)
      let idleScreen = openComposer(idle, log.actions)
      defer { idleScreen.close() }
      try idleScreen.pressEscape()
      let running = ComposerScreenModel(state: with { $0.isRunning = true })
      let runningScreen = openComposer(running, actions)
      defer { runningScreen.close() }
      try runningScreen.pressEscape()
      #expect(log.events.isEmpty)
    }

    // MARK: Approval mode

    @Test("Shift-Tab moves to the next mode and shows which one")
    func shiftTabCycles() throws {
      let model = ComposerScreenModel(state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressTab(.shift)
      #expect(log.events == ["mode:full-access"])
    }

    @Test("Shift-Tab leaves a launch-only or unknown mode alone")
    func shiftTabStops() throws {
      let cases: [String?] = [nil, "unknown"]
      for selected in cases {
        let state = with { $0.approvalModes = ComposerSamples.codexModes(selected: selected) }
        let model = ComposerScreenModel(state: state)
        let screen = openComposer(model, log.actions)
        defer { screen.close() }
        try screen.pressTab(.shift)
        #expect(log.events.isEmpty)
      }
    }

    @Test("a plain Tab with no suggestions types into the draft rather than acting")
    func plainTab() throws {
      let model = ComposerScreenModel(draft: "a", state: ComposerSamples.idle)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressTab()
      #expect(log.events.isEmpty)
    }

    // MARK: Focus

    @Test("a focus request gives the editor the keyboard")
    func focusRequest() throws {
      let model = ComposerScreenModel(state: ComposerSamples.idle)
      let screen = OffscreenWindow(ComposerScreen(model: model, actions: log.actions))
      defer { screen.close() }
      #expect(screen.window.firstResponder !== screen.textView)
      model.focusRequest += 1
      screen.settle(0.2)
      #expect(screen.window.firstResponder === screen.textView)
    }
  }
#endif
