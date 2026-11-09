#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// Rows with no button of their own: a real click reaches their tap handlers.
  @MainActor
  @Suite("Clicking workspace rows", .serialized)
  struct WorkspaceRowClickTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
      UserDefaults.standard.removeObject(forKey: "workspace.showsComments")
    }

    private static let entries: [String: [WorkspaceEntry]] = [
      "": [
        WorkspaceEntry(path: "src", kind: .directory),
        WorkspaceEntry(path: "README.md", kind: .file, size: 3),
      ],
      "src": [WorkspaceEntry(path: "src/main.rs", kind: .file, size: 3)],
    ]

    /// The middle of the tree's `index`th row: below the toolbar, in rows of 24 points.
    private func row<Content: View>(_ index: Int, in screen: OffscreenWindow<Content>) throws
      -> CGPoint
    {
      let list = try #require(screen.controlFrames.first { $0.height > 40 })
      return CGPoint(x: list.midX, y: list.minY + 12 + CGFloat(index) * 24)
    }

    @Test("one click on a file opens it, and one click on a folder toggles it")
    func treeRows() async throws {
      let source = ListedSource(Self.entries)
      let model = FileTreeModel(source: source)
      await model.loadRoot()
      var opened: [String] = []
      model.onOpen = { opened.append($0.path) }
      let screen = OffscreenWindow(
        FileTreeView(model: model, source: source, actions: .none), width: 320, height: 300)
      defer { screen.close() }
      try screen.click(try row(1, in: screen))
      #expect(await settle(screen) { opened == ["README.md"] })
      #expect(model.selection == "README.md")
      try screen.click(try row(0, in: screen))
      #expect(await settle(screen) { model.expanded == ["src"] })
      #expect(opened == ["README.md"], "a folder doesn't open a document")
      try screen.click(try row(0, in: screen))
      #expect(await settle(screen) { model.expanded.isEmpty })
    }

    @Test("clicking a file in the browser's tree shows it beside the tree")
    func browserOpensClickedFile() async throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      await model.tree.loadRoot()
      let screen = OffscreenWindow(WorkspaceBrowserView(model: model), width: 1_100, height: 500)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.shows("No File Selected"))
      let rows = try #require(model.tree.rows.firstIndex { $0.entry?.path == "README.md" })
      try screen.click(try row(rows, in: screen))
      #expect(await settle(screen) { model.document == .file(path: "README.md", line: nil) })
      #expect(await settle(screen) { model.file.value?.path == "README.md" })
      await flush(screen)
      #expect(try !screen.shows("No File Selected"))
    }

    /// Clicks down the results until `done`, since a file's header sits above its matches.
    private func clickDownResults<Content: View>(
      _ screen: OffscreenWindow<Content>, until done: () -> Bool
    ) async throws {
      let results = try #require(screen.controlFrames.last { $0.height > 100 })
      for offset in stride(from: 6.0, to: results.height, by: 8.0) where !done() {
        try screen.click(CGPoint(x: results.midX, y: results.minY + offset))
        await flush(screen)
      }
    }

    @Test("clicking a match selects it and opens it")
    func searchMatch() async throws {
      let model = WorkspaceSamples.searchedModel()
      var opened: [ContentMatch] = []
      let screen = OffscreenWindow(
        ContentSearchPanel(
          model: model, source: SampleWorkspaceDataSource(), actions: .none,
          onOpen: { opened.append($0) }),
        width: 360, height: 480)
      defer { screen.close() }
      model.selection = nil
      try await clickDownResults(screen) { !opened.isEmpty }
      let match = try #require(opened.first)
      #expect(model.selection == match.id)
    }

    @Test("clicking a match in the panel opens its file at its line")
    func searchMatchOpensDocument() async throws {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      model.tab = .search
      model.search.restore(WorkspaceSamples.searchResult)
      let screen = OffscreenWindow(WorkspacePanel(model: model), width: 340, height: 480)
      defer { screen.close() }
      await flush(screen)
      try await clickDownResults(screen) { model.document != nil }
      #expect(await settle(screen) { model.document != nil })
      guard case .file(let path, let line) = model.document else {
        Issue.record("expected a file, got \(String(describing: model.document))")
        return
      }
      let match = WorkspaceSamples.searchResult.files.flatMap(\.matches).first {
        $0.path == path && $0.line == line
      }
      #expect(match != nil, "\(path):\(String(describing: line))")
    }

    @Test("clicking a comment's card selects it and reveals its line")
    func commentCard() async throws {
      let spy = ReviewSpy()
      let review = ReviewFixtures.context(
        comments: [ReviewFixtures.comment("one", line: 7)], spy: spy)
      var selected: String?
      let binding = Binding(get: { selected }, set: { selected = $0 })
      let screen = OffscreenWindow(
        FileCommentsPanel(review: review, selectedID: binding, close: {}), width: 340, height: 520)
      defer { screen.close() }
      // The card's text sits above its row of actions: Hide, Edit, Resolve, Delete.
      let edit = screen.appKitButtons[1]
      let frame = edit.convert(edit.bounds, to: screen.host)
      try screen.click(CGPoint(x: frame.minX + 4, y: frame.minY - 16))
      await flush(screen)
      #expect(spy.revealed == [7])
      #expect(selected == "one")
    }
  }
#endif
