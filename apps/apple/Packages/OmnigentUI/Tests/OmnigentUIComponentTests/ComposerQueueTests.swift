#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The queue over the composer. Each row's buttons, left to right: Edit, Send now or Retry,
  /// Remove, while a message can take them.
  @Suite("Composer: queue", .serialized)
  @MainActor
  struct ComposerQueueTests {
    private let log = ComposerActionLog()
    private static let two = [
      QueuedMessage(id: "one", text: "first"), QueuedMessage(id: "two", text: "second"),
    ]

    private func open(
      _ queue: [QueuedMessage], running: Bool = true, canSteer: Bool = true
    ) -> OffscreenWindow<ComposerScreen> {
      var state = ComposerViewState()
      state.queue = queue
      state.isRunning = running
      state.canSteer = canSteer
      return openComposer(ComposerScreenModel(state: state), log.actions)
    }

    @Test("Send now and Remove act on their own row")
    func rowButtons() throws {
      let screen = open(Self.two)
      defer { screen.close() }
      #expect(try screen.shows("2 messages"))
      try screen.tapButton(4)
      try screen.tapButton(5)
      try screen.tapButton(1)
      #expect(log.events == ["sendNow:two", "remove:two", "sendNow:one"])
    }

    @Test("one message is counted in the singular")
    func oneMessage() throws {
      let screen = open([QueuedMessage(id: "one", text: "first")])
      defer { screen.close() }
      #expect(try screen.shows("1 message"))
    }

    @Test("a failed message offers Retry; one waiting for its host offers no send")
    func retryAndWaiting() throws {
      let screen = open([
        QueuedMessage(id: "bad", text: "b", state: .failed(message: "Offline")),
        QueuedMessage(id: "wait", text: "w", state: .waitingForHost),
      ])
      defer { screen.close() }
      #expect(try screen.shows("Retry"))
      #expect(try screen.shows("Send failed"))
      #expect(try screen.shows("Waiting for host"))
      #expect(try !screen.shows("Send now"))
      try screen.tapButton(1)
      #expect(log.events == ["sendNow:bad"])
    }

    @Test("a message being sent offers nothing and can't be reordered")
    func sending() throws {
      let screen = open([QueuedMessage(id: "going", text: "g", state: .sending)])
      defer { screen.close() }
      #expect(try screen.shows("Sending"))
      // Exact, as the editor's hidden Expand Editor shortcut contains "Edit".
      #expect(try !screen.shownText().contains("Edit"))
      #expect(try !screen.shownText().contains("Remove"))
    }

    @Test("a turn that can't take input keeps Send now back; idle offers it")
    func sendNowDependsOnSteering() throws {
      let blocked = open(Self.two, canSteer: false)
      defer { blocked.close() }
      #expect(try blocked.shows("Remove"))
      #expect(try !blocked.shows("Send now"))
      let idle = open(Self.two, running: false, canSteer: false)
      defer { idle.close() }
      #expect(try idle.shows("Send now"))
    }

    @Test("Edit opens the text in place, and Save stores what was typed, trimmed")
    func editAndSave() throws {
      let screen = open([QueuedMessage(id: "one", text: "first")])
      defer { screen.close() }
      try screen.tapButton(0)
      try screen.type("  more ", intoField: 0)
      // The editor's Cancel, then Save.
      try screen.tapButton(1)
      #expect(log.events.count == 1)
      #expect(log.events.first?.hasPrefix("edit:one:") == true)
      #expect(log.events.first?.hasSuffix(" ") == false)
      #expect(try screen.shows("Edit"), "back to the row")
    }

    @Test("Return in the field saves; Esc and Cancel drop the edit, not the draft below")
    func editKeys() throws {
      let queue = [QueuedMessage(id: "one", text: "first")]
      let saved = open(queue)
      defer { saved.close() }
      try saved.tapButton(0)
      try saved.pressReturn()
      #expect(log.events == ["edit:one:first"])

      log.events = []
      var state = ComposerViewState()
      state.queue = queue
      let model = ComposerScreenModel(draft: "draft", state: state)
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.tapButton(0)
      try screen.pressEscape()
      #expect(log.events.isEmpty)
      #expect(try screen.shows("Remove"), "back to the row")
      try screen.tapButton(0)
      try screen.tapButton(0)
      #expect(log.events.isEmpty)
      #expect(model.draft == "draft")
    }

    @Test("emptied text can't be saved unless files or paths are the message")
    func blankSave() throws {
      let blank = open([QueuedMessage(id: "one", text: "")])
      defer { blank.close() }
      try blank.tapButton(0)
      try blank.pressReturn()
      #expect(log.events.isEmpty)

      let files = open([
        QueuedMessage(
          id: "two", text: "",
          files: [
            QueuedMessage.File(name: "a.png", isImage: true), QueuedMessage.File(name: "b.txt"),
          ], mentions: ["src/", "main.swift"])
      ])
      defer { files.close() }
      #expect(try files.shows("a.png"))
      #expect(try files.shows("+1"))
      #expect(try files.shows("main.swift"))
      try files.tapButton(0)
      try files.pressReturn()
      #expect(log.events == ["edit:two:"])
    }

    @Test("the context menu repeats the actions and moves within the order")
    func contextMenu() throws {
      let screen = open(Self.two)
      defer { screen.close() }
      let frames = screen.buttons
      let first = try #require(try screen.contextMenu(at: center(frames[0])))
      let titles = menuTitles(first)
      #expect(titles.contains("Move Up"))
      #expect(titles.contains("Move Down"))
      #expect(first.items.first { $0.title == "Move Up" }?.isEnabled == false)
      try screen.choose("Move Down", in: first)
      let second = try #require(try screen.contextMenu(at: center(frames[3])))
      #expect(second.items.first { $0.title == "Move Down" }?.isEnabled == false)
      try screen.choose("Move Up", in: second)
      #expect(log.events == ["move:[0]:2", "move:[1]:0"])
    }

    @Test("without a host's move action or a second message there's no moving")
    func noMove() throws {
      var actions = log.actions
      actions.extras.moveQueued = nil
      var state = ComposerViewState()
      state.queue = Self.two
      let screen = openComposer(ComposerScreenModel(state: state), actions)
      defer { screen.close() }
      let menu = try #require(try screen.contextMenu(at: center(screen.buttons[0])))
      #expect(!menuTitles(menu).contains("Move Up"))
      #expect(menuTitles(menu).contains("Remove"))
    }

    private func center(_ frame: CGRect) -> CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
  }
#endif
