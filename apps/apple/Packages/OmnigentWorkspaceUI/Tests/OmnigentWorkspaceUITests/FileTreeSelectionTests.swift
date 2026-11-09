import Foundation
import Testing

@testable import OmnigentWorkspaceUI

/// What a click, return or an arrow key does to the tree's selection.
@Suite("File tree selection")
struct FileTreeSelectionTests {
  private static let entries: [String: [WorkspaceEntry]] = [
    "": [
      WorkspaceEntry(path: "src", kind: .directory),
      WorkspaceEntry(path: "z.txt", kind: .file, size: 3),
    ],
    "src": [
      WorkspaceEntry(path: "src/.hidden", kind: .file, size: 1),
      WorkspaceEntry(path: "src/zeta.rs", kind: .file, size: 1),
      WorkspaceEntry(path: "src/alpha.rs", kind: .file, size: 9),
    ],
  ]

  private func model() async -> FileTreeModel {
    let model = FileTreeModel(source: ListedSource(Self.entries))
    await model.loadRoot()
    return model
  }

  @Test("clicking a file opens it in one click; clicking a folder toggles it")
  func singleClick() async {
    let tree = await model()
    var opened: [String] = []
    tree.onOpen = { opened.append($0.path) }
    tree.selection = "z.txt"
    await tree.activateSelection()
    #expect(opened == ["z.txt"])
    tree.selection = "src"
    await tree.activateSelection()
    #expect(tree.expanded == ["src"])
    #expect(opened == ["z.txt"], "a folder doesn't open a document")
    await tree.activateSelection()
    #expect(tree.expanded.isEmpty)
  }

  @Test("a browser opens the file its tree activates")
  func browserOpensFile() async throws {
    let browser = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await browser.tree.loadRoot()
    browser.tree.selection = "README.md"
    await browser.tree.activateSelection()
    for _ in 0..<100 where browser.document == nil { await Task.yield() }
    #expect(browser.document == .file(path: "README.md", line: nil))
  }

  @Test("activating nothing, or a selection that's gone, does nothing")
  func activateNothing() async {
    let tree = await model()
    var opened = 0
    tree.onOpen = { _ in opened += 1 }
    await tree.activateSelection()
    tree.selection = "gone.txt"
    await tree.activateSelection()
    #expect(opened == 0)
  }

  @Test("a folder found by a search opens in the tree and ends the search")
  func searchedFolder() async {
    let source = ListedSource(Self.entries)
    source.matches = PathSearchResult(entries: [WorkspaceEntry(path: "src", kind: .directory)])
    let tree = FileTreeModel(source: source)
    await tree.loadRoot()
    tree.searchDelay = .seconds(60)
    tree.filter = "sr"
    await tree.searchNow()
    tree.selection = "src"
    await tree.activateSelection()
    #expect(tree.filter.isEmpty)
    #expect(tree.expanded == ["src"])
    #expect(tree.selection == "src")
    #expect(tree.rows.contains { $0.id == "src/alpha.rs" })
  }

  @Test("the right arrow steps to the first row shown, never a hidden or unsorted one")
  func stepInShownRow() async {
    let tree = await model()
    tree.selection = "src"
    await tree.stepIn()
    #expect(tree.expanded == ["src"])
    #expect(tree.selection == "src", "the first press only expands")
    await tree.stepIn()
    #expect(tree.selection == "src/alpha.rs")
    #expect(tree.selectedEntry?.path == "src/alpha.rs", "the selection is on a visible row")
  }

  @Test("the right arrow in an empty or hidden-only folder stays put")
  func stepInNothingShown() async {
    let source = ListedSource([
      "": [WorkspaceEntry(path: "dots", kind: .directory)],
      "dots": [WorkspaceEntry(path: "dots/.a", kind: .file)],
    ])
    let tree = FileTreeModel(source: source)
    await tree.loadRoot()
    tree.selection = "dots"
    await tree.stepIn()
    await tree.stepIn()
    #expect(tree.selection == "dots")
  }

  @Test("the arrows clamp at the ends and start from either end with no selection")
  func arrows() async {
    let tree = await model()
    tree.moveSelection(by: 1)
    #expect(tree.selection == "src")
    tree.moveSelection(by: -5)
    #expect(tree.selection == "src")
    tree.moveSelection(by: 50)
    #expect(tree.selection == "z.txt")
    tree.selection = nil
    tree.moveSelection(by: -1)
    #expect(tree.selection == "z.txt")
    tree.selection = "gone"
    tree.moveSelection(by: 1)
    #expect(tree.selection == "src")
    let empty = FileTreeModel(source: ListedSource(["": []]))
    empty.moveSelection(by: 1)
    #expect(empty.selection == nil)
  }

  @Test("the left arrow collapses, then steps out; at the top it stays")
  func stepOut() async {
    let tree = await model()
    tree.stepOut()
    #expect(tree.selection == nil)
    await tree.expand("src")
    tree.selection = "src/alpha.rs"
    tree.stepOut()
    #expect(tree.selection == "src")
    tree.stepOut()
    #expect(tree.expanded.isEmpty)
    tree.stepOut()
    #expect(tree.selection == "src")
  }

  @Test("collapsing a folder moves a selection inside it to the folder")
  func collapseMovesSelection() async {
    let tree = await model()
    await tree.expand("src")
    tree.selection = "src/alpha.rs"
    await tree.toggle("src")
    #expect(tree.selection == "src")
  }

  @Test("sort orders put folders first and missing values last", arguments: FileTreeSort.allCases)
  func sorts(sort: FileTreeSort) {
    let older = Date(timeIntervalSince1970: 1)
    let newer = Date(timeIntervalSince1970: 2)
    let entries = [
      WorkspaceEntry(path: "b.txt", kind: .file, size: 5, modifiedAt: older),
      WorkspaceEntry(path: "a.rs", kind: .file, size: 50, modifiedAt: newer),
      WorkspaceEntry(path: "c", kind: .file),
      WorkspaceEntry(path: ".d.txt", kind: .file, size: 5, modifiedAt: older),
      WorkspaceEntry(path: "dir", kind: .directory),
    ]
    let names = sort.sorted(entries).map(\.name)
    #expect(names.first == "dir")
    switch sort {
    case .name: #expect(names == ["dir", ".d.txt", "a.rs", "b.txt", "c"])
    case .lastEdited: #expect(names == ["dir", "a.rs", ".d.txt", "b.txt", "c"])
    case .size: #expect(names == ["dir", "a.rs", ".d.txt", "b.txt", "c"])
    case .type: #expect(names == ["dir", "c", "a.rs", ".d.txt", "b.txt"])
    }
    #expect(!sort.title.isEmpty)
    #expect(!sort.symbol.isEmpty)
    #expect(sort.id == sort.rawValue)
  }

  @Test("a failed search shows in place, and clearing the filter returns to the tree")
  func searchStates() async {
    let source = ListedSource(Self.entries)
    let tree = FileTreeModel(source: source)
    await tree.loadRoot()
    tree.searchDelay = .seconds(60)
    tree.filter = "x"
    source.failure = WorkspaceFailure(.searchFailed, message: "Boom")
    await tree.searchNow()
    #expect(tree.rows.map(\.id) == ["#search-failure"])
    source.failure = nil
    await tree.searchNow()
    #expect(tree.rows.map(\.content) == [.note("No matching files")])
    tree.filter = "  "
    await tree.searchNow()
    #expect(tree.search == .idle)
    #expect(tree.rows.contains { $0.id == "z.txt" })
  }

  @Test("a typed filter searches on its own after the pause")
  func debouncedSearch() async throws {
    let source = ListedSource(Self.entries)
    let tree = FileTreeModel(source: source)
    await tree.loadRoot()
    tree.searchDelay = .milliseconds(1)
    tree.filter = "z"
    tree.filter = "zz"
    tree.include = "*.txt"
    tree.exclude = "b"
    for _ in 0..<500 where !source.requests.contains("search zz") {
      try await Task.sleep(for: .milliseconds(2))
    }
    #expect(source.requests.contains("search zz"))
    #expect(!source.requests.contains("search z"), "a newer keystroke replaces the search")
  }
}
