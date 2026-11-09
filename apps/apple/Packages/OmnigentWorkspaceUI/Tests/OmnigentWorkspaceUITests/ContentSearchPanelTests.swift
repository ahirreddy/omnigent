#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Content search: the form's toggles and filters, and each result state.
  @MainActor
  @Suite("Content search panel", .serialized)
  struct ContentSearchPanelTests {
    private func hosted(
      _ model: ContentSearchModel, onOpen: @escaping (ContentMatch) -> Void = { _ in }
    ) -> OffscreenWindow<ContentSearchPanel> {
      OffscreenWindow(
        ContentSearchPanel(
          model: model, source: SampleWorkspaceDataSource(), actions: .none, onOpen: onOpen),
        width: 360, height: 480)
    }

    private func queryField(_ screen: OffscreenWindow<ContentSearchPanel>) throws -> NSTextField {
      try #require(screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    }

    /// Match case, regular expression and filters: the first row's controls after the field.
    private func toggles(_ screen: OffscreenWindow<ContentSearchPanel>) -> [CGPoint] {
      screen.controls.prefix(4).dropFirst().map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    @Test("typing a query and pressing Return searches, then matches show by file")
    func searches() async throws {
      let model = ContentSearchModel(source: SampleWorkspaceDataSource())
      let screen = hosted(model)
      defer { screen.close() }
      #expect(try screen.shows("Search File Contents"))
      try screen.click(try queryField(screen))
      try screen.type("needle")
      #expect(model.query.query == "needle")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(await settle(screen) { model.state.value != nil })
      await flush(screen)
      #expect(model.searchedQuery?.query == "needle")
    }

    @Test("match case and regular expression change the query")
    func toggleOptions() throws {
      let model = ContentSearchModel(source: SampleWorkspaceDataSource())
      let screen = hosted(model)
      defer { screen.close() }
      let buttons = toggles(screen)
      try #require(buttons.count == 3, "\(screen.controls)")
      try screen.click(buttons[0])
      #expect(model.query.caseSensitive)
      #expect(!model.query.regex)
      try screen.click(buttons[1])
      #expect(model.query.regex)
    }

    @Test("the filter button brings the include and exclude fields, each of which searches")
    func filters() async throws {
      let model = ContentSearchModel(source: SampleWorkspaceDataSource())
      let screen = hosted(model)
      defer { screen.close() }
      try screen.click(toggles(screen)[2])
      #expect(model.showsFilters)
      await flush(screen)
      let fields = screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        .sorted { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }
      try #require(fields.count == 3)
      model.query.query = "needle"
      try screen.click(fields[1])
      try screen.type("src/**")
      #expect(model.query.include == "src/**")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(await settle(screen) { model.searchedQuery?.include == "src/**" })
      try screen.click(fields[2])
      try screen.type("*.md")
      #expect(model.query.exclude == "*.md")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(await settle(screen) { model.searchedQuery?.exclude == "*.md" })
      #expect(model.query.hasFilters)
    }

    @Test("results count matches and files, and warn when partial")
    func results() throws {
      let model = WorkspaceSamples.searchedModel()
      let screen = hosted(model)
      defer { screen.close() }
      let result = try #require(model.state.value)
      #expect(
        try screen.shows("\(result.matchCount) results in \(result.files.count) files"))
      for file in result.files { #expect(try screen.shows(WorkspacePaths.name(of: file.path))) }
      #expect(try !screen.shows("Results are partial."))
      var cut = result
      cut.truncated = true
      let cutModel = ContentSearchModel(source: SampleWorkspaceDataSource())
      cutModel.restore(cut)
      let cutScreen = hosted(cutModel)
      defer { cutScreen.close() }
      #expect(try cutScreen.shows("Results are partial."))
      var warned = result
      warned.warning = "The index is rebuilding."
      let warnedModel = ContentSearchModel(source: SampleWorkspaceDataSource())
      warnedModel.restore(warned)
      let warnedScreen = hosted(warnedModel)
      defer { warnedScreen.close() }
      #expect(try warnedScreen.shows("The index is rebuilding."))
    }

    @Test("no matches names the query, or says the search stopped early")
    func noMatches() throws {
      let model = ContentSearchModel(source: SampleWorkspaceDataSource())
      model.query.query = "zebra"
      model.restore(ContentSearchResult(files: []))
      let screen = hosted(model)
      defer { screen.close() }
      #expect(try screen.shows("No Matches"))
      var stopped = ContentSearchResult(files: [])
      stopped.truncated = true
      let stoppedModel = ContentSearchModel(source: SampleWorkspaceDataSource())
      stoppedModel.restore(stopped)
      let stoppedScreen = hosted(stoppedModel)
      defer { stoppedScreen.close() }
      #expect(try stoppedScreen.shows("The search stopped early"))
    }

    @Test("a failed search shows the server's reason")
    func failure() async throws {
      let source = SampleWorkspaceDataSource()
      source.searchFailure = WorkspaceFailure(.searchFailed, message: "Invalid regex")
      let model = ContentSearchModel(source: source)
      model.query.query = "("
      await model.search()
      let screen = hosted(model)
      defer { screen.close() }
      #expect(try screen.shows("Invalid regex"))
      #expect(try screen.shows("Search Failed"))
    }

    @Test("arrow keys move through the matches and Return opens the selected one")
    func keyboard() async throws {
      let model = WorkspaceSamples.searchedModel()
      var opened: [ContentMatch] = []
      let screen = hosted(model) { opened.append($0) }
      defer { screen.close() }
      let results = try #require(screen.controlFrames.last { $0.height > 100 })
      try screen.click(CGPoint(x: results.midX, y: results.maxY - 10))
      try screen.press(keyCode: 125, characters: "\u{F701}")
      await flush(screen)
      let first = try #require(model.selection, "the arrow reached the results")
      try screen.press(keyCode: 125, characters: "\u{F701}")
      await flush(screen)
      #expect(model.selection != first)
      try screen.press(keyCode: 126, characters: "\u{F700}")
      await flush(screen)
      #expect(model.selection == first)
      try screen.press(keyCode: 36, characters: "\r")
      await flush(screen)
      #expect(opened.map(\.id) == [first])
    }

    @Test("a match and its file's header have the path menu")
    func contextMenus() throws {
      let screen = hosted(WorkspaceSamples.searchedModel())
      defer { screen.close() }
      let results = try #require(screen.controlFrames.last { $0.height > 100 })
      let header = CGPoint(x: results.midX, y: results.minY + 30)
      let menu = try #require(try screen.contextMenuUnder(header))
      #expect(menu.items.map(\.title).contains("Copy Path"))
      let match = CGPoint(x: results.midX, y: results.minY + 55)
      #expect(try screen.contextMenuUnder(match) != nil)
    }
  }
#endif
