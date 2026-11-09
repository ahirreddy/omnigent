#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The tree's controls: search, sort, folders, retry and row menus.
  @MainActor
  @Suite("File tree interactions", .serialized)
  struct FileTreeInteractionTests {
    private static let tree = FileTreeViewTests.tree
    private static let files = FileTreeViewTests.files

    private func tree(_ source: ListedSource) async -> FileTreeModel {
      let model = FileTreeModel(source: source)
      await model.loadRoot()
      return model
    }

    private func hosted(
      _ model: FileTreeModel, _ source: ListedSource, actions: WorkspaceActions = .none,
      height: CGFloat = 320
    ) -> OffscreenWindow<FileTreeView> {
      OffscreenWindow(
        FileTreeView(model: model, source: source, actions: actions), width: 320, height: height)
    }

    @Test("the filter button shows the include and exclude fields and hides them again")
    func searchFilters() async throws {
      let source = ListedSource(Self.tree)
      let model = await tree(source)
      let screen = hosted(model, source)
      defer { screen.close() }
      let before = screen.controls.count
      try screen.click(try #require(screen.appKitButtons.first))
      #expect(model.showsSearchFilters)
      #expect(screen.controls.count == before + 2)
      try screen.click(try #require(screen.appKitButtons.first))
      #expect(!model.showsSearchFilters)
      #expect(screen.controls.count == before)
    }

    @Test("the eye button shows hidden files, and refresh reads the tree again")
    func hiddenAndRefresh() async throws {
      let source = ListedSource(Self.tree)
      let model = await tree(source)
      let screen = hosted(model, source)
      defer { screen.close() }
      #expect(!model.rows.contains { $0.id == ".env" })
      let buttons = screen.appKitButtons
      try #require(buttons.count >= 3)
      try screen.click(buttons[1])
      #expect(model.showsHidden)
      #expect(model.rows.contains { $0.id == ".env" })
      try screen.click(screen.appKitButtons[1])
      #expect(!model.showsHidden)
      source.requests = []
      try screen.click(screen.appKitButtons[2])
      #expect(await settle(screen) { source.requests == ["list "] })
    }

    @Test("the sort menu lists every order and choosing one sorts the tree")
    func sortMenu() async throws {
      let source = ListedSource(["": Self.files])
      let model = await tree(source)
      let screen = hosted(model, source)
      defer { screen.close() }
      let menu = try screen.menu(ofPopUp: 0)
      for sort in FileTreeSort.allCases {
        try screen.choose(sort.title, in: menu)
        #expect(model.sort == sort)
      }
      try screen.choose("Size", in: menu)
      #expect(model.rows.compactMap(\.entry).first?.name == "z.md", "largest first")
    }

    @Test("the folder menu copies, reveals and opens the working folder")
    func folderMenu() async throws {
      SystemSideEffects.reset()
      var revealed: [String] = []
      var opened: [String] = []
      let source = ListedSource(Self.tree, absoluteRoot: "/work")
      let model = await tree(source)
      let screen = hosted(
        model, source,
        actions: WorkspaceActions(
          reveal: { revealed.append($0) }, openExternally: { opened.append($0) }))
      defer { screen.close() }
      let menu = try screen.menu(ofPopUp: 1)
      #expect(
        menu.items.map(\.title).filter { !$0.isEmpty } == [
          "Copy Folder Path", "Reveal in Finder", "Open in Editor",
        ])
      try screen.choose("Copy Folder Path", in: menu)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "/work")
      try screen.choose("Reveal in Finder", in: menu)
      try screen.choose("Open in Editor", in: menu)
      #expect(revealed == ["/work"])
      #expect(opened == ["/work"])
    }

    @Test("without a known root there is no folder menu")
    func noFolderMenu() async {
      let source = ListedSource(Self.tree)
      let model = await tree(source)
      let screen = hosted(model, source)
      defer { screen.close() }
      #expect(screen.popUps.count == 1, "only the sort menu")
    }

    @Test("typing in the filter searches on return and lists matches with their folders")
    func filterSearch() async throws {
      let source = ListedSource(Self.tree)
      source.matches = PathSearchResult(
        entries: [
          WorkspaceEntry(path: "src/main.rs", kind: .file),
          WorkspaceEntry(path: "src/util", kind: .directory),
        ], truncated: true)
      let model = await tree(source)
      model.searchDelay = .seconds(60)
      let screen = hosted(model, source)
      defer { screen.close() }
      try screen.clickAny(0)
      try screen.type("mai")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(model.filter == "mai")
      #expect(await settle(screen) { source.requests.contains("search mai") })
      #expect(await settle(screen) { model.rows.count == 3 })
      #expect(model.rows.last?.content == .note("More files match. Refine the search to see them."))
      let text = try shownString(screen)
      #expect(text.contains("main.rs"), "read: \(text)")
      #expect(text.contains("More files match"), "read: \(text)")
    }

    /// The first row's chevron: the first control at a row's leading edge, under the search field.
    private func firstChevron<Content: View>(
      _ screen: OffscreenWindow<Content>
    ) throws -> CGRect {
      try #require(screen.controlFrames.first { $0.minX < 30 && $0.minY > 30 && $0.height < 24 })
    }

    @Test("a chevron expands and collapses its folder")
    func chevron() async throws {
      let source = ListedSource(Self.tree)
      let model = await tree(source)
      let screen = hosted(model, source)
      defer { screen.close() }
      let chevron = try firstChevron(screen)
      try screen.click(CGPoint(x: chevron.midX, y: chevron.midY))
      #expect(await settle(screen) { model.expanded.contains("src") })
      #expect(await settle(screen) { model.rows.contains { $0.id == "src/main.rs" } })
      let again = try firstChevron(screen)
      try screen.click(CGPoint(x: again.midX, y: again.midY))
      #expect(await settle(screen) { !model.expanded.contains("src") })
    }

    @Test("Load more reads the next page")
    func loadMore() async throws {
      let source = ListedSource(["": Self.files])
      source.nextCursors[""] = "next"
      let model = await tree(source)
      #expect(model.rows.last?.content == .loadMore)
      source.entries[""] = [WorkspaceEntry(path: "zz.txt", kind: .file)]
      let screen = hosted(model, source)
      defer { screen.close() }
      try screen.click(try #require(screen.appKitButtons.last))
      #expect(await settle(screen) { model.rows.contains { $0.id == "zz.txt" } })
      #expect(model.rows.last?.content != .loadMore)
    }

    @Test("a root that can't be read offers Try Again, and it recovers")
    func rootFailure() async throws {
      let source = ListedSource(Self.tree)
      source.failure = WorkspaceFailure(.runnerOffline, message: "The agent is asleep")
      let model = await tree(source)
      let screen = hosted(model, source)
      defer { screen.close() }
      #expect(try shownString(screen).contains("Agent Is Asleep"))
      source.failure = nil
      let retry = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: retry.midX, y: retry.midY))
      #expect(await settle(screen) { model.rootFailure == nil })
      #expect(await settle(screen) { model.rows.contains { $0.id == "readme.md" } })
    }

    @Test("a folder that can't be read shows in place with Retry; an empty one says so")
    func folderStates() async throws {
      let source = ListedSource(Self.tree)
      let model = await tree(source)
      source.failure = WorkspaceFailure(.forbidden, message: "No access")
      await model.expand("src")
      source.failure = nil
      let screen = hosted(model, source)
      defer { screen.close() }
      #expect(try shownString(screen).contains("No access"))
      try screen.click(try #require(screen.appKitButtons.last))
      #expect(await settle(screen) { model.rows.contains { $0.id == "src/main.rs" } })
      await model.expand("empty")
      model.collapse("src")
      let emptyRow = FileTreeModel.Row(id: "x", directory: "x", depth: 0, content: .empty)
      #expect(emptyRow.entry == nil)
    }

    @Test("a row's context menu copies paths; a folder has no Quick Look or Share")
    func contextMenus() async throws {
      SystemSideEffects.reset()
      var shared: [String] = []
      var looked: [String] = []
      let source = ListedSource(Self.tree, absoluteRoot: "/work")
      let model = await tree(source)
      let screen = hosted(
        model, source,
        actions: WorkspaceActions(share: { shared.append($0) }, quickLook: { looked.append($0) }))
      defer { screen.close() }
      let chevron = try firstChevron(screen)
      let folderRow = CGPoint(x: 160, y: chevron.midY)
      let folderMenu = try #require(try screen.contextMenuUnder(folderRow))
      #expect(!folderMenu.items.map(\.title).contains("Quick Look"))
      #expect(!folderMenu.items.map(\.title).contains("Share\u{2026}"))
      let fileRow = CGPoint(x: 160, y: chevron.midY + 22)
      let fileMenu = try #require(try screen.contextMenuUnder(fileRow))
      try screen.choose("Quick Look", in: fileMenu)
      try screen.choose("Share\u{2026}", in: fileMenu)
      try screen.choose("Copy Path", in: fileMenu)
      // Sorted by name, the row after the folder is "future".
      #expect(looked == ["future"])
      #expect(shared == ["future"])
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "future")
    }

    @Test("the arrow keys and return move through the tree once it has focus")
    func keyboard() async throws {
      let source = ListedSource(Self.tree)
      let model = await tree(source)
      var opened: [String] = []
      model.onOpen = { opened.append($0.path) }
      let screen = hosted(model, source)
      defer { screen.close() }
      let scrollArea = try #require(screen.controlFrames.first { $0.height > 40 })
      try screen.click(CGPoint(x: scrollArea.midX, y: scrollArea.maxY - 8))
      let (down, upKey, right, left) = (125 as UInt16, 126 as UInt16, 124 as UInt16, 123 as UInt16)
      try screen.press(keyCode: down, characters: "\u{F701}")
      #expect(model.selection == "src")
      try screen.press(keyCode: right, characters: "\u{F703}")
      #expect(await settle(screen) { model.expanded.contains("src") })
      try screen.press(keyCode: down, characters: "\u{F701}")
      #expect(model.selection == "src/main.rs")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(await settle(screen) { opened == ["src/main.rs"] })
      try screen.press(keyCode: left, characters: "\u{F702}")
      #expect(model.selection == "src")
      try screen.press(keyCode: upKey, characters: "\u{F700}")
      #expect(model.selection == "src")
    }
  }
#endif
