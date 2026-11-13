#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The CLI composer's own keys, pressed on its focused editor: Esc, Tab, Shift-Tab and Down.
  @Suite("CLI composer: keys", .serialized)
  @MainActor
  struct TranscriptCLIComposerKeyTests {
    private let log = ComposerActionLog()
    private static let commands = [
      SlashCommand(name: "compact", description: "Compact the context"),
      SlashCommand(name: "clear", description: "Clear the conversation"),
    ]

    init() {
      SystemSideEffects.reset()
    }

    /// The composer with the keyboard in its editor, as it is once it has come on screen.
    private func composer(
      _ state: ComposerViewState, draft: String = ""
    ) async throws -> OffscreenWindow<AnyView> {
      let screen = try cliComposerScreen(state, actions: log.actions, draft: draft)
      try await letTasksRun(screen, milliseconds: 200)
      try #require(screen.window.firstResponder is NSTextView, "the editor has the keyboard")
      return screen
    }

    private func suggesting(isRunning: Bool = false) -> ComposerViewState {
      var state = ComposerViewState(slashCommands: Self.commands)
      state.isRunning = isRunning
      return state
    }

    @Test("Esc stops a running turn, and does nothing while idle")
    func escapeStops() async throws {
      let idle = try await composer(ComposerViewState())
      defer { idle.close() }
      try idle.pressEscape()
      #expect(log.events.isEmpty)

      var state = ComposerViewState()
      state.isRunning = true
      let running = try await composer(state)
      defer { running.close() }
      try running.pressEscape()
      #expect(log.events == ["stop"])
    }

    @Test("Esc closes the suggestions first, and only the next Esc stops the turn")
    func escapeClosesSuggestionsFirst() async throws {
      let screen = try await composer(suggesting(isRunning: true), draft: "/")
      defer { screen.close() }
      #expect(try screen.shows("Compact the context"))
      try screen.pressEscape()
      #expect(log.events.isEmpty)
      #expect(try !screen.shows("Compact the context"))
      try screen.pressEscape()
      #expect(log.events == ["stop"])
    }

    @Test("Tab fills in the highlighted command instead of sending")
    func tabAppliesSuggestion() async throws {
      let screen = try await composer(suggesting(), draft: "/cl")
      defer { screen.close() }
      try screen.pressTab()
      #expect(screen.textView?.string == "/clear ")
      #expect(log.events.isEmpty)
    }

    @Test("Down moves the highlight to the next command, which Return then fills in")
    func downMovesTheHighlight() async throws {
      let screen = try await composer(suggesting(), draft: "/c")
      defer { screen.close() }
      try screen.pressDown()
      try screen.pressReturn()
      #expect(screen.textView?.string == "/clear ")
      #expect(log.events.isEmpty, "the command is filled in, not sent")
    }

    @Test("Shift-Tab moves to the next approval mode; with no modes it does nothing")
    func shiftTabCyclesTheMode() async throws {
      let plain = try await composer(ComposerViewState())
      defer { plain.close() }
      try plain.pressShiftTab()
      #expect(log.events.isEmpty)

      let screen = try await composer(
        ComposerViewState(approvalModes: ComposerSamples.codexModes()))
      defer { screen.close() }
      try screen.pressShiftTab()
      #expect(log.events == ["mode:full-access"])
    }

    // The app's own event path, where the editor's watcher takes the key before focus moves.
    @Test("Shift-Tab on its way into the app cycles the mode whatever character it carries")
    func shiftTabThroughTheApplication() async throws {
      let screen = try await composer(
        ComposerViewState(approvalModes: ComposerSamples.codexModes()))
      defer { screen.close() }
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .shift,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: screen.window.windowNumber,
        context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false,
        keyCode: ComposerKey.tab)
      NSApp.sendEvent(try #require(event))
      screen.settle(0.05)
      #expect(log.events == ["mode:full-access"])
      #expect(screen.textView?.string.isEmpty == true, "the key is used up, not typed")
    }
  }
#endif
