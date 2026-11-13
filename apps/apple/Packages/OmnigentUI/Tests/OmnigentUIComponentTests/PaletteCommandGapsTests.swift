#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What the palette ran, and what the window was asked to do once it closed.
  @MainActor
  private final class PaletteRunLog {
    var performed: [PaletteTarget] = []
  }

  /// Commands typed into the palette and run with Return, and the palette's own close button.
  @Suite("Command palette: typed commands and closing", .serialized)
  @MainActor
  struct PaletteCommandGapsTests {
    private func state(offersEverything: Bool) -> PaletteViewState {
      var state = PaletteViewState(
        scope: "Studio",
        sessions: [
          PaletteEntry(
            id: "a", title: "Alpha", detail: "detail a", symbol: "bubble.left",
            target: .session("a"))
        ], servers: [], hasNextRequest: offersEverything)
      state.showsAutomations = offersEverything
      state.showsUsage = offersEverything
      return state
    }

    private func palette(
      _ log: PaletteRunLog, offersEverything: Bool
    ) -> OffscreenWindow<CommandPalette> {
      let state = state(offersEverything: offersEverything)
      let view = CommandPalette(
        state: state, commands: PaletteCatalog.entries(state: state, commands: .init())
      ) { log.performed.append($0) }
      let screen = OffscreenWindow(view, width: 640, height: 520)
      screen.settle()
      return screen
    }

    @Test("typed and run with Return: Settings, and the pages and next request a server offers")
    func typedCommands() throws {
      let typed: [(String, PaletteTarget)] = [
        ("settings", .settings), ("next session", .nextRequest), ("automations", .automations),
        ("usage", .usage),
      ]
      for (query, target) in typed {
        let log = PaletteRunLog()
        let screen = palette(log, offersEverything: true)
        defer { screen.close() }
        try screen.type(query)
        try screen.press(keyCode: 36, characters: "\r")
        #expect(log.performed == [target], "\(query)")
      }
    }

    @Test("with nothing waiting and no pages offered, those commands can't be run")
    func unofferedCommands() throws {
      let unoffered: [(String, PaletteTarget)] = [
        ("Go to next session that needs you", .nextRequest), ("Go to Automations", .automations),
        ("Go to Usage", .usage),
      ]
      for (query, target) in unoffered {
        let log = PaletteRunLog()
        let screen = palette(log, offersEverything: false)
        defer { screen.close() }
        try screen.type(query)
        try screen.press(keyCode: 36, characters: "\r")
        #expect(!log.performed.contains(target), "\(query)")
      }
    }

    @Test("a click on the presented palette's close button closes it without running anything")
    func closeButtonCloses() throws {
      let log = PaletteRunLog()
      let root = Color.clear.commandPalette(
        state: state(offersEverything: false),
        actions: PaletteActions { log.performed.append($0) }, initiallyPresented: true)
      let screen = OffscreenWindow(root, width: 640, height: 560)
      defer { screen.close() }
      screen.settle(0.2)
      let sheet = try #require(screen.window.attachedSheet?.contentView)
      let fields = screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
      let search = try #require(fields.first)
      let searchFrame = search.convert(search.bounds, to: sheet)
      // Close sits at the end of the search field's row.
      let close = try #require(
        screen.controlFrames.first {
          abs($0.midY - searchFrame.midY) < 12 && $0.minX >= searchFrame.maxX - 1
        })
      try screen.click(CGPoint(x: close.midX, y: close.midY))
      screen.settle(0.2)
      #expect(screen.window.attachedSheet == nil)
      #expect(log.performed.isEmpty)
    }
  }
#endif
