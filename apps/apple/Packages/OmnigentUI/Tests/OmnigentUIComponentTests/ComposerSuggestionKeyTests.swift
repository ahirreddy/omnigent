#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// `/` and `@` suggestions and Up and Down through history, by real keys.
  @Suite("Composer: suggestions and recall", .serialized)
  @MainActor
  struct ComposerSuggestionKeyTests {
    private let log = ComposerActionLog()
    private static let commands = [
      SlashCommand(name: "compact", description: "Compact the context"),
      SlashCommand(name: "clear"),
      SlashCommand(name: "skill-one", isSkill: true),
    ]

    private func state(mentions: [String] = []) -> ComposerViewState {
      var state = ComposerViewState(slashCommands: Self.commands, mentionCandidates: mentions)
      state.isRunning = true
      return state
    }

    @Test("Return applies the highlighted command and Down moves the highlight")
    func returnAppliesHighlight() throws {
      let model = ComposerScreenModel(draft: "/c", state: state())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressDown()
      try screen.pressReturn()
      #expect(model.draft == "/clear ")
      #expect(log.events.isEmpty)
    }

    @Test("Up wraps past the first row; typing puts the highlight back on it")
    func upWraps() throws {
      let model = ComposerScreenModel(draft: "/", state: state())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressUp()
      try screen.pressReturn()
      #expect(model.draft == "/skill-one ")
      model.draft = "/c"
      screen.settle()
      try screen.pressReturn()
      #expect(model.draft == "/compact ")
    }

    @Test("Tab applies a command too; a Command-Return still sends over open suggestions")
    func tabAndCommandReturn() throws {
      let model = ComposerScreenModel(draft: "/cl", state: state())
      model.state.isRunning = false
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressReturn(.command)
      #expect(log.events == ["send"])
      try screen.pressTab()
      #expect(model.draft == "/clear ")
    }

    @Test("Esc closes the suggestions first, and a second Esc stops the turn")
    func escapeOrder() throws {
      let model = ComposerScreenModel(draft: "/", state: state())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressEscape()
      #expect(log.events.isEmpty)
      try screen.pressEscape()
      #expect(log.events == ["stop"])
    }

    @Test("a picked file becomes a chip and leaves the token out of the draft")
    func fileBecomesChip() throws {
      let model = ComposerScreenModel(draft: "see @Pa", state: state(mentions: ["Package.swift"]))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(log.events == ["attachMention:Package.swift"])
      #expect(model.draft == "see ")
    }

    @Test("without chips a picked path stays as text")
    func fileStaysAsText() throws {
      var actions = log.actions
      actions.extras.attachMention = nil
      let model = ComposerScreenModel(draft: "@Pa", state: state(mentions: ["Package.swift"]))
      let screen = openComposer(model, actions)
      defer { screen.close() }
      try screen.pressTab()
      #expect(model.draft == "@Package.swift ")
    }

    @Test("Return opens a folder; Tab attaches it whole")
    func folderKeys() throws {
      let model = ComposerScreenModel(
        draft: "@", state: state(mentions: ["Sources/", "Sources/App.swift"]))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressReturn()
      #expect(model.draft == "@Sources/")
      #expect(log.events.isEmpty)
      model.draft = "@"
      screen.settle()
      try screen.pressTab()
      #expect(log.events == ["attachMention:Sources/"])
      #expect(model.draft.isEmpty)
    }

    @Test("clicking a row applies it; a folder's Attach button attaches it whole")
    func clicksOnRows() throws {
      let model = ComposerScreenModel(
        draft: "@", state: state(mentions: ["Sources/", "Sources/App.swift"]))
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      // The rows are the topmost buttons: the folder, its Attach, then the file.
      try screen.tapButton(1)
      #expect(log.events == ["attachMention:Sources/"])
      log.events = []
      model.draft = "@"
      screen.settle()
      try screen.tapButton(0)
      #expect(model.draft == "@Sources/")
      #expect(log.events.isEmpty)
    }

    // MARK: Recall

    @Test("Up pulls back the newest queued message first, then walks earlier prompts; Down returns")
    func recallOrder() throws {
      log.lastQueued = "queued text"
      log.prompts = ["older", "newest"]
      var actions = log.actions
      actions.extras.history = log.history
      let model = ComposerScreenModel(state: ComposerViewState())
      let screen = openComposer(model, actions)
      defer { screen.close() }
      try screen.pressUp()
      #expect(model.draft == "queued text")
      model.draft = ""
      screen.settle()
      try screen.pressUp()
      #expect(model.draft == "newest")
      try screen.pressUp()
      #expect(model.draft == "older")
      try screen.pressUp()
      #expect(model.draft == "older", "nothing older stays where it is")
      try screen.pressDown()
      #expect(model.draft == "newest")
      try screen.pressDown()
      #expect(model.draft.isEmpty, "back to what the field had")
    }

    @Test("Up in a field with typed text leaves it alone")
    func recallRespectsTypedText() throws {
      log.prompts = ["older"]
      var actions = log.actions
      actions.extras.history = log.history
      let model = ComposerScreenModel(draft: "typed", state: ComposerViewState())
      let screen = openComposer(model, actions)
      defer { screen.close() }
      try screen.pressUp()
      try screen.pressDown()
      #expect(model.draft == "typed")
    }

    @Test("a host with only the single recall gives that prompt to an empty field")
    func singleRecall() throws {
      log.prompts = ["last prompt"]
      let model = ComposerScreenModel(state: ComposerViewState())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressUp()
      #expect(model.draft == "last prompt")
      #expect(log.events == ["recallPrevious"])
      // Down has nothing to walk without the history.
      try screen.pressDown()
      #expect(model.draft == "last prompt")
    }

    @Test("Command-Up is the text view's: it never recalls")
    func modifiedArrows() throws {
      log.prompts = ["last prompt"]
      let model = ComposerScreenModel(state: ComposerViewState())
      let screen = openComposer(model, log.actions)
      defer { screen.close() }
      try screen.pressUp(.command)
      #expect(model.draft.isEmpty)
      #expect(log.events.isEmpty)
    }
  }
#endif
