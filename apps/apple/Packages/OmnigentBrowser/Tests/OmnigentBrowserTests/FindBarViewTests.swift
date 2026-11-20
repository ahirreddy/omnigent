#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import Testing

  @testable import OmnigentBrowser

  /// Positions of the find bar's borderless controls.
  private enum FindControl {
    static let previous = 0
    static let next = 1
    static let matchCase = 2
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

    @Test("Match Case searches again, so the count isn't left over from the old search")
    func matchCaseSearchesAgain() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = makeBar(fixture)
      defer { screen.close() }
      fixture.model.find.query = "cat"
      await screen.catchUp()

      try screen.clickButton(at: FindControl.matchCase)
      await screen.catchUp()

      #expect(fixture.model.find.caseSensitive)
      #expect(tab.commands.last == "find cat forward true")
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

    @Test("Use Selection for Find takes the page's selection as the text Find Next looks for")
    func useSelection() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      tab.scriptResult = .string("needle")
      await fixture.model.useSelectionForFind()
      #expect(tab.scripts.last == "window.getSelection().toString()")
      #expect(fixture.model.find.query == "needle")
      await fixture.model.findNext()
      #expect(tab.commands.last == "find needle forward false")

      // Nothing selected, or a page that can't say, keeps the text; a failure shows on the tab.
      for kept in [BrowserScriptValue.string(""), .null] {
        tab.scriptResult = kept
        await fixture.model.useSelectionForFind()
        #expect(fixture.model.find.query == "needle")
      }
      tab.scriptFailure = .tabNotReady
      await fixture.model.useSelectionForFind()
      #expect(fixture.model.lastError == .tabNotReady)
      #expect(fixture.model.find.query == "needle")

      let unopened = fixture.environment.makeTab(url: nil)
      await unopened.useSelectionForFind()
      #expect(unopened.find.query.isEmpty)
    }

    @Test("Find takes the page's selected line as its query and searches it")
    func findSeedsFromSelection() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      tab.scriptResult = .string("  needle \n")
      await fixture.model.showFindBarSeedingSelection()
      #expect(tab.scripts.last == BrowserTabModel.findSeedScript)
      #expect(fixture.model.find.isVisible)
      #expect(fixture.model.find.query == "needle")
      #expect(fixture.model.find.selectAllRequest == 1)
      #expect(tab.commands.last == "find needle forward false")

      // Several lines, nothing, or a failed read keep the query; the failure shows on the tab.
      for kept in [BrowserScriptValue.string("one\ntwo"), .string(""), .null] {
        tab.scriptResult = kept
        await fixture.model.showFindBarSeedingSelection()
        #expect(fixture.model.find.query == "needle")
      }
      tab.scriptFailure = .tabNotReady
      await fixture.model.showFindBarSeedingSelection()
      #expect(fixture.model.lastError == .tabNotReady)
      #expect(fixture.model.find.isVisible)
    }

    @Test("Find pressed in the bar keeps what was typed")
    func findInBarKeepsTyping() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = makeBar(fixture)
      defer { screen.close() }
      await screen.catchUp()
      try screen.focusField()
      try screen.type("typed")
      await screen.catchUp()
      #expect(fixture.model.find.isFieldFocused)
      tab.scriptResult = .string("selected")
      let reads = tab.scripts.count
      await fixture.model.showFindBarSeedingSelection()
      #expect(tab.scripts.count == reads)
      #expect(fixture.model.find.query == "typed")
    }

    @Test("A seed is one line of at most 1,000 characters")
    func seedRule() {
      #expect(BrowserFindModel.seed(fromSelection: " cat ") == "cat")
      #expect(BrowserFindModel.seed(fromSelection: "a\nb") == nil)
      #expect(BrowserFindModel.seed(fromSelection: "  ") == nil)
      let long = String(repeating: "x", count: BrowserFindModel.maxSeedLength + 1)
      #expect(BrowserFindModel.seed(fromSelection: long) == nil)
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
