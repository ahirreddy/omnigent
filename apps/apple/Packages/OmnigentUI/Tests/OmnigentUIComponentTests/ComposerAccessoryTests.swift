#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What travels with the draft and what the composer reports around it.
  @Suite("Composer: attachments, paths, quotes and notices", .serialized)
  @MainActor
  struct ComposerAccessoryTests {
    private let log = ComposerActionLog()

    private func open(
      draft: String = "", _ change: (inout ComposerViewState) -> Void
    ) -> OffscreenWindow<ComposerScreen> {
      var state = ComposerViewState()
      change(&state)
      return openComposer(ComposerScreenModel(draft: draft, state: state), log.actions)
    }

    @Test("an attachment says how it's going and can be removed")
    func attachmentStates() throws {
      let attachments = [
        DraftAttachment(id: "ready", title: "ready.png", kind: .image, state: .ready),
        DraftAttachment(
          id: "sized", title: "sized.txt", kind: .file, byteCount: 2048, state: .ready),
        DraftAttachment(id: "up", title: "up.png", kind: .image, state: .uploading(progress: 0.5)),
        DraftAttachment(
          id: "spin", title: "spin.png", kind: .image, state: .uploading(progress: nil)),
        DraftAttachment(id: "done", title: "done.png", kind: .image, state: .uploaded),
        DraftAttachment(
          id: "bad", title: "bad.png", kind: .image, state: .failed(message: "Too big")),
      ]
      let screen = open { $0.attachments = attachments }
      defer { screen.close() }
      #expect(try screen.shows("Ready"))
      #expect(try screen.shows("2 KB"))
      #expect(try screen.shows("Uploading"))
      #expect(try screen.shows("Uploaded"))
      #expect(try screen.shows("Too big"))
      try screen.tapButton(0)
      #expect(log.events == ["removeAttachment:ready"])
    }

    @Test("an attachment alone is enough to send")
    func attachmentSends() throws {
      let screen = open {
        $0.attachments = [DraftAttachment(id: "a", title: "a.png", kind: .image, state: .ready)]
      }
      defer { screen.close() }
      try screen.pressReturn()
      #expect(log.events == ["send"])
    }

    @Test("an @ path chip can be removed and is enough to send")
    func mentions() throws {
      let screen = open { $0.mentions = ["src/main.swift", "docs/"] }
      defer { screen.close() }
      #expect(try screen.shows("src/main.swift"))
      try screen.tapButton(1)
      #expect(log.events == ["removeMention:docs/"])
      try screen.pressReturn()
      #expect(log.events.last == "send")
    }

    @Test("a quote can be removed, and text before a later one edited")
    func quotes() throws {
      let screen = open {
        $0.quotes = [ComposerQuote(text: "quoted"), ComposerQuote(before: "lead", text: "again")]
      }
      defer { screen.close() }
      #expect(try screen.shows("quoted"))
      try screen.tapButton(0)
      #expect(log.events == ["removeQuote:0"])
      log.events = []
      try screen.type("x", intoField: 0)
      #expect(log.events.first?.hasPrefix("lead:1:") == true)
    }

    @Test("a quote in an unavailable composer can't be removed")
    func quotesDisabled() throws {
      let screen = open {
        $0.quotes = [ComposerQuote(text: "quoted")]
        $0.availability = .unavailable(reason: "Archived")
      }
      defer { screen.close() }
      #expect(try screen.shows("quoted"))
      let buttons = screen.allViews.compactMap { $0 as? NSButton }.filter { !($0 is NSPopUpButton) }
      #expect(!buttons.isEmpty)
      #expect(buttons.allSatisfy { !$0.isEnabled })
    }

    @Test("a local command's output can be dismissed")
    func commandNotice() throws {
      let screen = open { $0.commandNotice = "Usage: /help" }
      defer { screen.close() }
      #expect(try screen.shows("Usage: /help"))
      try screen.tapButton(0)
      #expect(log.events == ["dismissNotice"])
    }

    @Test("a broken stream offers Reconnect; a connecting one just says so")
    func connection() throws {
      let failed = open {
        $0.connection = ComposerConnectionNotice(message: "Disconnected", isFailure: true)
      }
      defer { failed.close() }
      #expect(try failed.shows("Disconnected"))
      try failed.tapButton(1)
      #expect(log.events == ["reconnect"])

      var actions = log.actions
      actions.extras.reconnect = nil
      var state = ComposerViewState()
      state.connection = ComposerConnectionNotice(message: "Connecting\u{2026}")
      let waiting = openComposer(ComposerScreenModel(state: state), actions)
      defer { waiting.close() }
      #expect(try waiting.shows("Connecting\u{2026}"))
      #expect(waiting.allViews.contains { $0 is NSProgressIndicator })
      #expect(try !waiting.shows("Reconnect"))
    }

    @Test("an uncertain send without an acknowledgement still warns")
    func uncertainWithoutAcknowledge() throws {
      var actions = log.actions
      actions.acknowledgeUncertainDelivery = nil
      var state = ComposerViewState()
      state.delivery = .uncertain(message: "It may have arrived.")
      let screen = openComposer(ComposerScreenModel(state: state), actions)
      defer { screen.close() }
      #expect(try screen.shows("It may have arrived."))
      #expect(try !screen.shows("Allow another send"))
    }

    @Test("the reason shows in place of a field that can't take input")
    func unavailable() throws {
      let screen = open { $0.availability = .unavailable(reason: "Host offline") }
      defer { screen.close() }
      #expect(try screen.shows("Host offline"))
    }

    @Test("a suggestion list that may be incomplete says why; a failed search shows only that")
    func completionNotes() throws {
      let incomplete = open(draft: "/") {
        $0.slashCommands = [SlashCommand(name: "help")]
        $0.slashCommandsNote = "Skills unavailable."
      }
      defer { incomplete.close() }
      #expect(try incomplete.shows("Skills unavailable."))
      let failed = open(draft: "@x") { $0.mentionsNote = "Search failed." }
      defer { failed.close() }
      #expect(try failed.shows("Search failed."))
    }

    @Test("Plan mode shows beside the controls, and its menu leaves it")
    func planMode() throws {
      var actions = log.actions
      actions.extras.isPlanOn = true
      let screen = openComposer(ComposerScreenModel(state: ComposerViewState()), actions)
      defer { screen.close() }
      #expect(try screen.shows("Plan mode"))
      // On the bottom row, right-aligned.
      let window = screen.window.contentLayoutRect
      var menu: NSMenu?
      for offset in stride(from: 60, through: 200, by: 20) where menu == nil {
        menu = try screen.contextMenu(at: CGPoint(x: window.width - CGFloat(offset), y: 584))
      }
      let found = try #require(menu)
      try screen.choose("Exit Plan mode", in: found)
      #expect(log.events == ["plan"])
    }

    @Test("Touch's read-only bar gives the reason, or a plain sentence without one")
    func readOnlyBar() throws {
      for (reason, expected) in [("Archived", "Archived"), (nil, "This session is read-only.")] {
        var state = ComposerViewState()
        state.isReadOnly = true
        state.availability = .unavailable(reason: reason ?? "")
        let bar = ReadOnlyComposerBar(reason: reason)
        let screen = OffscreenWindow(bar)
        defer { screen.close() }
        #expect(try screen.shows(expected))
        let cli = OffscreenWindow(ReadOnlyComposerBar(reason: reason, isCLI: true))
        defer { cli.close() }
        #expect(try cli.shows(expected))
      }
    }
  }
#endif
