#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The tree's "files to include" and "files to exclude" fields, typed into.
  @MainActor
  @Suite("File tree search filters", .serialized)
  struct FileTreeViewFilterTests {
    /// The tree's fields, top to bottom: the name filter, then include and exclude once shown.
    private func fields(_ screen: OffscreenWindow<FileTreeView>) -> [NSTextField] {
      screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        .sorted {
          $0.convert($0.bounds, to: screen.host).minY < $1.convert($1.bounds, to: screen.host).minY
        }
    }

    @Test("what is typed into the include and exclude fields narrows the search the source runs")
    func globsReachTheSearch() async throws {
      let source = ListedSource(FileTreeViewTests.tree)
      source.matches = PathSearchResult(
        entries: [WorkspaceEntry(path: "src/main.rs", kind: .file)])
      let model = FileTreeModel(source: source)
      await model.loadRoot()
      model.searchDelay = .milliseconds(10)
      let screen = OffscreenWindow(
        FileTreeView(model: model, source: source, actions: .none), width: 320, height: 360)
      defer { screen.close() }
      try screen.click(try #require(fields(screen).first))
      try screen.type("mai")
      #expect(await settle(screen) { source.pathSearches.last == ["mai", "", ""] })

      // The filter button, first after the name field, brings the two glob fields.
      try screen.click(try #require(screen.appKitButtons.first))
      #expect(await settle(screen) { fields(screen).count == 3 })
      try screen.click(fields(screen)[1])
      try screen.type("src/**")
      #expect(model.include == "src/**")
      #expect(await settle(screen) { source.pathSearches.last == ["mai", "src/**", ""] })
      try screen.click(fields(screen)[2])
      try screen.type("*.md")
      #expect(model.exclude == "*.md")
      #expect(await settle(screen) { source.pathSearches.last == ["mai", "src/**", "*.md"] })
      #expect(await settle(screen) { model.rows.contains { $0.id == "src/main.rs" } })
    }

    @Test("globs typed before any name search nothing")
    func globsAloneSearchNothing() async throws {
      let source = ListedSource(FileTreeViewTests.tree)
      let model = FileTreeModel(source: source)
      await model.loadRoot()
      model.searchDelay = .milliseconds(10)
      model.showsSearchFilters = true
      let screen = OffscreenWindow(
        FileTreeView(model: model, source: source, actions: .none), width: 320, height: 360)
      defer { screen.close() }
      try #require(fields(screen).count == 3)
      try screen.click(fields(screen)[1])
      try screen.type("src/**")
      #expect(await settle(screen) { model.include == "src/**" })
      await flush(screen)
      #expect(source.pathSearches.isEmpty)
      #expect(!model.isSearching)
    }
  }
#endif
