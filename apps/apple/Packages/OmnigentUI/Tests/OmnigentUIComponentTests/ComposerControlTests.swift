#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The pill's buttons, by real clicks. In reading order: Stop while running, Send once there
  /// is a draft, Mic. A disabled Stop or Send isn't in `buttons`, which proves it can't be pressed.
  @Suite("Composer: Send, Stop, Mic and Add", .serialized)
  @MainActor
  struct ComposerControlTests {
    private let log = ComposerActionLog()

    /// A state with nothing under the pill, so the pill's controls are the only ones.
    private func bare(_ change: (inout ComposerViewState) -> Void = { _ in }) -> ComposerViewState {
      var state = ComposerViewState()
      change(&state)
      return state
    }

    @Test("Send appears with a draft and sends on click")
    func sendAppearsWithDraft() throws {
      let model = ComposerScreenModel(state: bare())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(screen.buttons.count == 1)
      model.draft = "hello"
      screen.settle()
      #expect(screen.buttons.count == 2)
      try screen.tapButton(0)
      #expect(log.events == ["send"])
    }

    @Test("a click on a blocked Send does nothing")
    func sendBlocked() throws {
      // Without a queue, a second message cannot wait behind the one being sent.
      var unqueued = log.actions
      unqueued.extras.queueDraft = nil
      let blocks: [(ComposerActions, (inout ComposerViewState) -> Void)] = [
        (log.actions, { $0.availability = .unavailable(reason: "Host offline") }),
        (log.actions, { $0.delivery = .uncertain(message: "Unknown") }),
        (unqueued, { $0.delivery = .sending }),
      ]
      for (actions, block) in blocks {
        let model = ComposerScreenModel(draft: "hello", state: bare())
        let screen = openComposer(model, actions)
        defer { screen.close() }
        let send = try #require(screen.buttons.first)
        block(&model.state)
        screen.settle()
        try screen.click(CGPoint(x: send.midX, y: send.midY))
        #expect(!log.events.contains("send"))
      }
    }

    @Test("text typed while a message is on its way can be sent, with no progress in its way")
    func sendDuringASend() throws {
      let model = ComposerScreenModel(draft: "and this", state: bare { $0.delivery = .sending })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(!screen.allViews.contains { $0 is NSProgressIndicator })
      try screen.tapButton(0)
      #expect(log.events == ["send"])
    }

    @Test("Send shows progress while sending, even with no draft left")
    func sendingShowsProgress() throws {
      let model = ComposerScreenModel(state: bare { $0.delivery = .sending })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
    }

    @Test("Stop stays in reach while running and calls interrupt")
    func stopClick() throws {
      let model = ComposerScreenModel(state: bare { $0.isRunning = true })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.tapButton(0)
      #expect(log.events == ["stop"])
    }

    @Test("Stop stops once: a second click during the interrupt does nothing")
    func stopDisabled() throws {
      let model = ComposerScreenModel(state: bare { $0.isRunning = true })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let stop = try #require(screen.buttons.first)
      model.state.isStopping = true
      screen.settle()
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      try screen.click(CGPoint(x: stop.midX, y: stop.midY))
      #expect(log.events.isEmpty)
    }

    @Test("Stop can't be pressed where the host can't interrupt")
    func stopUnavailable() throws {
      var actions = log.actions
      actions.interrupt = nil
      let model = ComposerScreenModel(state: bare { $0.isRunning = true })
      let screen = openComposer(model, actions)
      defer { screen.close() }
      #expect(screen.buttons.count == 1, "only Mic")
    }

    @Test("Command-Period is Stop's shortcut")
    func stopShortcut() throws {
      let model = ComposerScreenModel(state: bare { $0.isRunning = true })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let handled = try screen.pressShortcut(keyCode: 47, characters: ".", modifiers: .command)
      #expect(handled)
      #expect(log.events == ["stop"])
    }

    @Test("Mic runs the host's dictation; Option-Command-V is its shortcut")
    func dictation() throws {
      let model = ComposerScreenModel(state: bare())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.tapButton(0)
      #expect(log.events == ["dictate"])
      let handled = try screen.pressShortcut(
        keyCode: 9, characters: "v", modifiers: [.command, .option])
      #expect(handled)
      #expect(log.events == ["dictate", "dictate"])
    }

    @Test("Mic is disabled where the composer takes no input")
    func dictationDisabled() throws {
      let state = bare { $0.availability = .unavailable(reason: "Archived") }
      let model = ComposerScreenModel(state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.tapButton(0)
      #expect(!log.events.contains("dictate"))
    }

    @Test("Shift-Command-E expands the editor and again collapses it")
    func expandShortcut() throws {
      let model = ComposerScreenModel(state: bare())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let editorHeight = { screen.textView?.enclosingScrollView?.frame.height ?? 0 }
      let collapsed = editorHeight()
      let expanded = try screen.pressShortcut(
        keyCode: 14, characters: "e", modifiers: [.command, .shift])
      #expect(expanded)
      screen.settle(0.4)
      #expect(editorHeight() > collapsed * 3)
      _ = try screen.pressShortcut(keyCode: 14, characters: "e", modifiers: [.command, .shift])
      screen.settle(0.4)
      #expect(editorHeight() < collapsed + 1)
    }

    @Test("the editor grows with its text and then stops growing")
    func editorGrows() throws {
      let model = ComposerScreenModel(state: bare())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let editorHeight = { screen.textView?.enclosingScrollView?.frame.height ?? 0 }
      let one = editorHeight()
      model.draft = "1\n2\n3"
      screen.settle(0.4)
      let three = editorHeight()
      #expect(three > one * 2)
      model.draft = String(repeating: "line\n", count: 100)
      screen.settle(0.4)
      let capped = editorHeight()
      model.draft = String(repeating: "line\n", count: 500)
      screen.settle(0.4)
      #expect(capped < 300)
      #expect(editorHeight() == capped)
    }

    @Test("the Add menu offers attachments and the session's actions")
    func addMenu() throws {
      let model = ComposerScreenModel(state: bare())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      let menu = try screen.menu(at: 0)
      let titles = menuTitles(menu)
      #expect(titles.contains("Files and images\u{2026}"))
      #expect(titles.contains("Photos\u{2026}"))
      #expect(titles.contains("Start a new side chat"))
      #expect(titles.contains("Goal"))
      #expect(titles.contains("Plan"))
      try screen.choose("Start a new side chat", in: menu)
      try screen.choose("Goal", in: menu)
      try screen.choose("Plan", in: menu)
      #expect(log.events == ["sideChat", "goal", "plan"])
    }

    @Test("Add leaves out what the host can't do, and hides itself when that's everything")
    func addMenuReducesToNothing() throws {
      var actions = ComposerActions(send: {})
      actions.extras.dictate = {}
      let model = ComposerScreenModel(state: bare { $0.acceptsAttachments = false })
      let screen = openComposer(model, actions)
      defer { screen.close() }
      #expect(screen.menus.isEmpty)

      var noExtras = ComposerActions(send: {}, addAttachments: { _ in })
      noExtras.extras.dictate = {}
      let other = ComposerScreenModel(state: bare())
      let otherScreen = openComposer(other, noExtras)
      defer { otherScreen.close() }
      let titles = menuTitles(try otherScreen.menu(at: 0))
      #expect(titles.contains("Start a new side chat") == false)
      #expect(titles.contains("Files and images\u{2026}"))
    }

    @Test("after an uncertain send, Allow another send acknowledges it")
    func uncertainDeliveryIsAcknowledged() throws {
      let model = ComposerScreenModel(
        state: bare { $0.delivery = .uncertain(message: "It may have arrived.") })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.tapButton(0)
      #expect(log.events == ["acknowledge"])
    }

    @Test("a failed send can be dismissed")
    func failedDeliveryIsDismissed() throws {
      let model = ComposerScreenModel(
        state: bare { $0.delivery = .failed(message: "Network down.") })
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      // The banner's Copy, then its Dismiss.
      try screen.tapButton(1)
      #expect(log.events == ["dismissDelivery"])
      #expect(try screen.shows("Dismiss"))
      #expect(try !screen.shows("Restore message"))
    }

    @Test("a failed message the field has no room for is restored or discarded from its banner")
    func failedDeliveryOffersTheMessage() throws {
      let state = bare {
        $0.delivery = .failed(message: "Network down.")
        $0.offersUnsentMessage = true
      }
      let screen = openComposer(ComposerScreenModel(draft: "newer", state: state), log.actions)
      defer { screen.close() }
      #expect(try screen.shows("Discard message"))
      #expect(try screen.shows("Restore message"))
      // The banner's Copy, its Discard, then its Restore.
      try screen.tapButton(2)
      try screen.tapButton(1)
      #expect(log.events == ["restoreUnsent", "dismissDelivery"])
    }
  }
#endif
