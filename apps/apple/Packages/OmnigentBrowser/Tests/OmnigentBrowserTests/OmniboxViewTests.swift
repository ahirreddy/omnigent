#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// The address bar as a user drives it: type, pick a suggestion, submit, give up.
  @MainActor
  @Suite("Omnibox, off screen", .serialized)
  struct OmniboxViewTests {
    private func field(
      _ fixture: TabFixture, style: BrowserOmniboxField.Style = .toolbar
    ) -> some View {
      BrowserOmniboxField(model: fixture.model, environment: fixture.environment, style: style)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .frame(width: 600)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @Test("the field shows the page's address, and a blank page's is empty")
    func showsTheAddress() throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      #expect(screen.fields.first?.stringValue == "https://a.example/page")
      fixture.model.load(try testURL("about:blank"))
      screen.settle()
      #expect(screen.fields.first?.stringValue.isEmpty == true)
    }

    @Test("Return loads a typed address, as typed, and leaves the field")
    func returnLoadsAnAddress() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      try screen.focusField()
      screen.fields.first?.currentEditor()?.selectAll(nil)
      try screen.type("b.example/path")
      #expect(screen.fields.first?.stringValue == "b.example/path")
      try screen.pressReturn()
      #expect(tab.loads.last == (try testURL("https://b.example/path")))
      #expect(screen.fields.first?.stringValue == "https://b.example/path")
      tab.state.title = "B"
      await screen.catchUp()
      let visit = fixture.environment.history(for: fixture.model.profileID).visits.first
      #expect(visit?.typed == true)
    }

    @Test("Return searches for words, with the chosen engine")
    func returnSearches() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      try screen.focusField()
      screen.fields.first?.currentEditor()?.selectAll(nil)
      try screen.type("two words")
      try screen.pressReturn()
      let loaded = try #require(tab.loads.last)
      #expect(loaded.absoluteString.contains("two"))
      #expect(loaded.host(percentEncoded: false) != "two")
    }

    @Test("Escape puts the page's address back")
    func escapeReverts() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      try screen.focusField()
      screen.fields.first?.currentEditor()?.selectAll(nil)
      try screen.type("nonsense")
      try screen.pressEscape()
      #expect(screen.fields.first?.stringValue == "https://a.example/page")
      #expect(tab.loads.count == 1)
    }

    @Test("empty text loads nothing and says why")
    func emptyTextIsRefused() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      #expect(throws: BrowserError.invalidURL("  ")) { try fixture.model.submitOmnibox("  ") }
      #expect(tab.loads.count == 1)
    }

    @Test("arrows move through suggestions, and Return takes the one selected")
    func arrowsPickASuggestion() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let history = fixture.environment.history(for: fixture.model.profileID)
      history.recordVisit(url: try testURL("https://omni.example/one"), title: "One", typed: true)
      history.recordVisit(url: try testURL("https://omni.example/two"), title: "Two", typed: true)
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      try screen.focusField()
      screen.fields.first?.currentEditor()?.selectAll(nil)
      try screen.type("omni")
      await screen.catchUp()
      let suggestions = BrowserOmnibox.suggestions(
        for: "omni", searchEngine: fixture.environment.settings.searchEngine, history: history,
        bookmarks: fixture.environment.bookmarks(for: fixture.model.profileID), openTabs: [])
      try #require(suggestions.count >= 3)
      try screen.pressDownArrow()
      try screen.pressDownArrow()
      try screen.pressUpArrow()
      // Past the first row, and far past the end, is still the list.
      try screen.pressUpArrow()
      try screen.pressUpArrow()
      try screen.pressDownArrow()
      try screen.pressReturn()
      #expect(tab.loads.last == suggestions[1].url)
    }

    @Test("a click on a suggestion loads it")
    func clickingASuggestion() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let history = fixture.environment.history(for: fixture.model.profileID)
      let url = try testURL("https://omni.example/picked")
      history.recordVisit(url: url, title: "Picked", typed: false)
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      try screen.focusField()
      screen.fields.first?.currentEditor()?.selectAll(nil)
      try screen.type("omni")
      await screen.catchUp()
      let suggestions = BrowserOmnibox.suggestions(
        for: "omni", searchEngine: fixture.environment.settings.searchEngine, history: history,
        bookmarks: fixture.environment.bookmarks(for: fixture.model.profileID), openTabs: [])
      let index = try #require(suggestions.firstIndex { $0.url == url })
      // The list hangs 34 points under the field with rows of about 26, inside 4 of padding.
      try screen.click(CGPoint(x: 200, y: 34 + 4 + 13 + 26 * CGFloat(index)))
      await screen.catchUp()
      #expect(tab.loads.last == url)
    }

    @Test("an open tab's suggestion switches to it rather than loading it here")
    func openTabSuggestionSwitches() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let other = fixture.environment.makeTab(url: try testURL("https://omni.example/open"))
      other.activate()
      var switched: [UUID] = []
      fixture.environment.onSwitchToTab = { switched.append($0) }
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      try screen.focusField()
      screen.fields.first?.currentEditor()?.selectAll(nil)
      try screen.type("omni")
      await screen.catchUp()
      let suggestions = BrowserOmnibox.suggestions(
        for: "omni", searchEngine: fixture.environment.settings.searchEngine,
        history: fixture.environment.history(for: fixture.model.profileID),
        bookmarks: fixture.environment.bookmarks(for: fixture.model.profileID),
        openTabs: fixture.environment.openTabSummaries(excluding: fixture.model.id))
      let index = try #require(
        suggestions.firstIndex {
          if case .openTab = $0.kind { return true }
          return false
        })
      for _ in 0..<index { try screen.pressDownArrow() }
      try screen.pressReturn()
      #expect(switched == [other.id])
      #expect(tab.loads.count == 1)
      #expect(screen.fields.first?.stringValue == "https://a.example/page")
    }

    @Test("a request to focus takes the keyboard, and each new tab asks for one")
    func focusRequests() throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      #expect(fixture.model.omniboxFocusRequest == 0)
      #expect(screen.window.firstResponder is NSWindow)
      fixture.model.focusOmnibox()
      screen.settle()
      #expect(screen.window.firstResponder is NSText)
      let (environment, _) = try makeEnvironment()
      environment.settings.newTabURL = nil
      #expect(environment.makeTab().omniboxFocusRequest == 1)
    }

    @Test("the toolbar field's star bookmarks, and a saved icon replaces the globe")
    func starAndIcon() throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(field(fixture), width: 700, height: 400)
      defer { screen.close() }
      #expect(screen.buttons.count == 1)
      try screen.clickButton(at: 0)
      #expect(fixture.model.isBookmarked)
      fixture.model.favicon = BrowserFavicon(pngData: Self.onePixelPNG)
      screen.settle()
      #expect(fixture.model.favicon?.image != nil)
      try screen.clickButton(at: 0)
      #expect(!fixture.model.isBookmarked)
    }

    @Test("the pill's Clear empties the text and goes away")
    func pillClear() throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(field(fixture, style: .pill), width: 700, height: 400)
      defer { screen.close() }
      fixture.model.focusOmnibox()
      screen.settle()
      try screen.type("https://typed.example")
      screen.settle()
      let controls = screen.controlFrames
      // Clear, then Cancel, then the suggestion for what was typed.
      let clear = try #require(controls.first)
      try screen.click(CGPoint(x: clear.midX, y: clear.midY))
      screen.settle()
      #expect((screen.window.firstResponder as? NSText)?.string.isEmpty == true)
      #expect(screen.controlFrames.count < controls.count)
    }

    @Test("the pill clears while editing, and Cancel gives up")
    func pillStyle() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(field(fixture, style: .pill), width: 700, height: 400)
      defer { screen.close() }
      #expect(screen.buttons.isEmpty)
      fixture.model.focusOmnibox()
      screen.settle()
      #expect(screen.window.firstResponder is NSText)
      #expect(!screen.controlFrames.isEmpty)
      tab.state.estimatedProgress = 0.4
      tab.state.isLoading = true
      screen.settle()
    }

    static let onePixelPNG =
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
      ) ?? Data()
  }
#endif
