#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import Testing

  @testable import OmnigentBrowser

  /// Positions of the find bar's borderless controls.
  private enum FindControl {
    static let previous = 0
    static let next = 1
    static let done = 3
  }

  @Suite("Find bar, off screen", .serialized)
  @MainActor
  struct FindBarViewTests {
    private func makeBar(_ fixture: TabFixture) -> OffscreenWindow<BrowserFindBar> {
      fixture.model.showFindBar()
      return OffscreenWindow(BrowserFindBar(model: fixture.model), width: 640, height: 44)
    }

    @Test("emptying the field takes the old highlights off the page")
    func emptyingTheFieldClearsHighlights() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      tab.findResult = BrowserFindResult(matchFound: true, matchCount: 2, activeMatch: 1)
      fixture.model.find.query = "cat"
      await fixture.model.findNext()
      #expect(fixture.model.find.result != nil)

      fixture.model.find.query = ""
      await fixture.model.findNext()

      #expect(fixture.model.find.result == nil)
      #expect(tab.commands.last == "stopFinding")
    }

    @Test("typing searches as you go, and the buttons and Return step through the matches")
    func typingAndStepping() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      tab.findResult = BrowserFindResult(matchFound: true, matchCount: 3, activeMatch: 2)
      let screen = makeBar(fixture)
      defer { screen.close() }
      await screen.catchUp()

      try screen.focusField()
      try screen.type("cat")
      await screen.catchUp()
      #expect(fixture.model.find.query == "cat")
      #expect(tab.commands.last == "find cat forward false")
      #expect(fixture.model.find.result?.matchCount == 3)

      try screen.clickButton(at: FindControl.previous)
      await screen.catchUp()
      #expect(tab.commands.last == "find cat backward false")

      try screen.clickButton(at: FindControl.next)
      await screen.catchUp()
      #expect(tab.commands.last == "find cat forward false")

      let before = tab.commands.count
      try screen.pressReturn()
      await screen.catchUp()
      #expect(tab.commands.count == before + 1)
      #expect(tab.commands.last == "find cat forward false")
    }

    @Test("Done and Escape close the bar and clear the highlights")
    func doneAndEscape() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = makeBar(fixture)
      defer { screen.close() }
      fixture.model.find.query = "cat"
      await fixture.model.findNext()

      try screen.clickButton(at: FindControl.done)
      #expect(!fixture.model.find.isVisible)
      #expect(fixture.model.find.result == nil)
      #expect(tab.commands.last == "stopFinding")

      fixture.model.showFindBar()
      await screen.catchUp()
      try screen.focusField()
      try screen.pressEscape()
      await screen.catchUp()
      #expect(!fixture.model.find.isVisible)
    }

    @Test("a failed search says why on the tab")
    func failedSearch() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      tab.failure = .tabNotReady
      fixture.model.find.query = "cat"
      await fixture.model.findNext()
      #expect(fixture.model.lastError == .tabNotReady)
      #expect(fixture.model.find.result == nil)
    }

    @Test("asking for the bar again gets the field focused again")
    func focusRequest() async throws {
      let fixture = try TabFixture()
      let screen = makeBar(fixture)
      defer { screen.close() }
      await screen.catchUp()
      screen.window.makeFirstResponder(nil)
      fixture.model.showFindBar()
      await screen.catchUp()
      #expect(screen.window.firstResponder is NSText)
    }

    @Test("the count says what the search found")
    func matchText() {
      let two = BrowserFindResult(matchFound: true, matchCount: 4, activeMatch: 2)
      let noActive = BrowserFindResult(matchFound: true, matchCount: 4, activeMatch: nil)
      let uncounted = BrowserFindResult(matchFound: true, matchCount: nil, activeMatch: nil)
      let none = BrowserFindResult(matchFound: false, matchCount: nil, activeMatch: nil)
      #expect(BrowserFindBar.matchText(query: "", result: two).isEmpty)
      #expect(BrowserFindBar.matchText(query: "cat", result: nil).isEmpty)
      #expect(BrowserFindBar.matchText(query: "cat", result: none) == "No matches")
      #expect(BrowserFindBar.matchText(query: "cat", result: two) == "2 of 4")
      #expect(BrowserFindBar.matchText(query: "cat", result: noActive) == "1 of 4")
      #expect(BrowserFindBar.matchText(query: "cat", result: uncounted) == "Found")
    }
  }
#endif
