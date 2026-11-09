#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Records what the palette runs and what it asks the server.
  @MainActor
  private final class PaletteSpy {
    var performed: [PaletteTarget] = []
    var searches: [String] = []
    var answer = PaletteSearchResults()
  }

  private let arrowDown = (key: UInt16(125), text: "\u{F701}")
  private let arrowUp = (key: UInt16(126), text: "\u{F700}")

  @Suite("Command palette: search, keys and running a result", .serialized)
  @MainActor
  struct PaletteViewTests {
    private func entry(_ id: String, _ title: String, enabled: Bool = true) -> PaletteEntry {
      PaletteEntry(
        id: id, title: title, detail: "detail \(id)", symbol: "bubble.left", isEnabled: enabled,
        target: .session(id))
    }

    private var state: PaletteViewState {
      PaletteViewState(
        scope: "Studio", sessions: [entry("a", "Alpha"), entry("b", "Bravo")],
        servers: [
          PaletteEntry(
            id: "home", title: "Home", detail: "Server", symbol: "server.rack",
            target: .server("home"))
        ], hasNextRequest: false)
    }

    private var commands: [PaletteEntry] {
      PaletteCatalog.entries(state: state, commands: SessionCommandActions())
    }

    private func palette(
      _ spy: PaletteSpy, findsSessions: Bool = false, searches: Bool = false
    ) -> OffscreenWindow<CommandPalette> {
      let search: (@MainActor @Sendable (String, Int) async -> PaletteSearchResults)? =
        searches
        ? { @MainActor query, limit in
          spy.searches.append("\(query) \(limit)")
          return spy.answer
        } : nil
      let view = CommandPalette(
        state: state, commands: commands, findsSessions: findsSessions, search: search
      ) { spy.performed.append($0) }
      return OffscreenWindow(view, width: 640, height: 520)
    }

    private func field<V: View>(_ screen: OffscreenWindow<V>) throws -> NSTextField {
      let fields = screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
      return try #require(fields.first)
    }

    @Test("Return runs the first enabled result")
    func returnRunsFirst() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed == [.session("a")])
    }

    @Test("typing narrows the results, and Return runs the best match")
    func typingNarrows() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      try screen.type("inbox")
      #expect(try screen.shows("Go to Inbox"))
      #expect(try !screen.shows("Alpha"))
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed == [.inbox])
    }

    @Test("a search with no match says so, and Return does nothing")
    func noMatch() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      try screen.type("zzzzqqq")
      #expect(try !screen.shows("Alpha"))
      #expect(try screen.shows("No Results for \u{201C}zzzzqqq\u{201D}"))
      try screen.press(keyCode: 36, characters: "\r")
      try screen.press(keyCode: arrowDown.key, characters: arrowDown.text)
      #expect(spy.performed.isEmpty)
    }

    @Test("the arrows move over enabled results and stop at the ends")
    func arrows() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      try screen.press(keyCode: arrowUp.key, characters: arrowUp.text)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed.last == .session("a"))
      try screen.press(keyCode: arrowDown.key, characters: arrowDown.text)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed.last == .session("b"))
      try screen.press(keyCode: arrowDown.key, characters: arrowDown.text)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed.last == .newSession)
      // Toggle workspace is off without a session, so Down goes past it.
      let enabled = commands.filter(\.isEnabled)
      for _ in enabled { try screen.press(keyCode: arrowDown.key, characters: arrowDown.text) }
      // The last enabled action is Switch server, which changes scope rather than running.
      #expect(enabled.last?.target == .switchServer)
      try screen.press(keyCode: 36, characters: "\r")
      #expect(try field(screen).placeholderString == "Find a server")
    }

    @Test("Find a session scopes to sessions, Switch server to servers, each clearing the query")
    func scopeChanges() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      let search = try field(screen)
      try screen.type("Find a")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed.isEmpty)
      #expect(search.stringValue.isEmpty)
      #expect(search.placeholderString == "Search sessions by name")
      #expect(try !screen.shows("Go to Inbox"))
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed == [.session("a")])
    }

    @Test("Switch server lists the servers, and picking one runs it")
    func serverScope() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      try screen.type("Switch server")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(try field(screen).placeholderString == "Find a server")
      #expect(try screen.shows("Home"))
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.performed == [.server("home")])
    }

    @Test("opened for finding sessions it starts scoped")
    func opensScoped() throws {
      let spy = PaletteSpy()
      let screen = palette(spy, findsSessions: true)
      defer { screen.close() }
      #expect(try field(screen).placeholderString == "Search sessions by name")
      #expect(try screen.shows("Alpha"))
      #expect(try !screen.shows("Go to Inbox"))
    }

    @Test("the scope control switches what is searched")
    func scopePicker() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      let scope = try #require(screen.allViews.lazy.compactMap { $0 as? NSSegmentedControl }.first)
      scope.selectedSegment = 2
      scope.sendAction(scope.action, to: scope.target)
      screen.settle()
      #expect(try field(screen).placeholderString == "Find a server")
      scope.selectedSegment = 1
      scope.sendAction(scope.action, to: scope.target)
      screen.settle()
      #expect(try field(screen).placeholderString == "Search sessions by name")
    }

    @Test("clicking a result runs it, and a disabled action does nothing")
    func clickingRows() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      let table = try #require(screen.list)
      // 0 Sessions header, 1 Alpha, 2 Bravo.
      try screen.clickRow(1)
      #expect(spy.performed == [.session("a")])
      #expect(table.numberOfRows > 5)
      spy.performed = []
      let disabledIndex = try #require(commands.firstIndex { !$0.isEnabled })
      let disabledRow = 3 + 1 + disabledIndex
      table.scrollRowToVisible(disabledRow)
      screen.settle()
      try screen.clickRow(disabledRow)
      #expect(spy.performed.isEmpty)
    }

    @Test("the close button and Escape dismiss nothing that isn't presented, quietly")
    func closeControls() throws {
      let spy = PaletteSpy()
      let screen = palette(spy)
      defer { screen.close() }
      screen.settle()
      try screen.clickControl(at: 0)
      try screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(spy.performed.isEmpty)
    }

    /// Lets the palette's debounce finish: its wake-up runs on the main actor, so the test yields.
    private func waitForSearch<V: View>(_ screen: OffscreenWindow<V>) async throws {
      try await Task.sleep(for: .milliseconds(320))
      screen.settle(0.02)
    }

    @Test("a search asks the server once typing pauses, trimmed, and shows what it found")
    func serverSearch() async throws {
      let spy = PaletteSpy()
      spy.answer = PaletteSearchResults(
        titles: [entry("far", "Remote Alpha")],
        messages: [entry("msg", "A message"), entry("far", "Remote Alpha")])
      let screen = palette(spy, searches: true)
      defer { screen.close() }
      screen.settle()
      #expect(spy.searches.isEmpty)
      try screen.type(" a")
      #expect(spy.searches.isEmpty)
      try screen.type("l")
      #expect(try screen.shows("Searching\u{2026}"))
      try await waitForSearch(screen)
      #expect(spy.searches == ["al 10"])
      #expect(try screen.shows("Remote Alpha"))
      #expect(try !screen.shows("Searching\u{2026}"))
    }

    @Test("a failed search says so, and Retry asks again")
    func searchFailure() async throws {
      let spy = PaletteSpy()
      spy.answer = PaletteSearchResults(failure: "Offline")
      let screen = palette(spy, searches: true)
      defer { screen.close() }
      screen.settle()
      try screen.type("zzq")
      try await waitForSearch(screen)
      #expect(try screen.shows("Couldn\u{2019}t load sessions."))
      #expect(try screen.shows("Offline"))
      spy.answer = PaletteSearchResults(titles: [entry("far", "zzq found")])
      let retry = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: retry.midX, y: retry.midY))
      try await waitForSearch(screen)
      #expect(spy.searches == ["zzq 10", "zzq 10"])
      #expect(try screen.shows("zzq found"))
    }

    @Test("Show more asks for another page")
    func showMore() async throws {
      let spy = PaletteSpy()
      spy.answer = PaletteSearchResults(titles: [entry("far", "zzq found")])
      spy.answer.hasMore = true
      let screen = palette(spy, searches: true)
      defer { screen.close() }
      screen.settle()
      try screen.type("zzq")
      try await waitForSearch(screen)
      let more = try #require(screen.plainButtons.last)
      try screen.click(more)
      try await waitForSearch(screen)
      #expect(spy.searches == ["zzq 10", "zzq 20"])
    }

    @Test("clearing the query clears what the server found")
    func clearingQuery() async throws {
      let spy = PaletteSpy()
      spy.answer = PaletteSearchResults(titles: [entry("far", "zzq found")])
      let screen = palette(spy, searches: true)
      defer { screen.close() }
      screen.settle()
      try screen.type("zzq")
      try await waitForSearch(screen)
      #expect(try screen.shows("zzq found"))
      for _ in 0..<3 { try screen.press(keyCode: 51, characters: "\u{7F}") }
      try await waitForSearch(screen)
      #expect(try !screen.shows("zzq found"))
    }
  }
#endif
