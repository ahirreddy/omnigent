import Foundation
import Testing

@testable import OmnigentWorkspaceUI

@Suite("File tree")
struct FileTreeModelTests {
  @Test("loads the root once and expands directories lazily")
  func lazyLoading() async {
    let source = SampleWorkspaceDataSource()
    let tree = FileTreeModel(source: source)
    #expect(tree.rows.map(\.id) == ["#loading"])
    await tree.loadRoot()
    await tree.loadRoot()
    #expect(source.requests == ["list "])
    #expect(tree.rows.compactMap(\.entry).count == 7)
    await tree.expand("src")
    #expect(source.requests == ["list ", "list src"])
    let srcRows = tree.rows.filter { $0.directory == "src" }
    #expect(srcRows.allSatisfy { $0.depth == 1 })
    #expect(srcRows.compactMap(\.entry).first?.path == "src/util")
    tree.collapse("src")
    await tree.expand("src")
    #expect(source.requests.count == 2, "a collapsed directory keeps its entries")
  }

  @Test("pages long directories with a load-more row")
  func pagination() async {
    let source = SampleWorkspaceDataSource(pageSize: 3)
    let tree = FileTreeModel(source: source)
    await tree.loadRoot()
    #expect(tree.rows.compactMap(\.entry).map(\.name) == [".git", "assets", "docs"])
    #expect(tree.rows.last?.content == .loadMore)
    await tree.loadMore("")
    await tree.loadMore("")
    #expect(tree.rows.compactMap(\.entry).count == 7)
    #expect(tree.rows.last?.content != .loadMore)
    #expect(source.requests == ["list ", "list  after docs", "list  after build.log"])
  }

  @Test("shows a failed directory in place and retries it")
  func failures() async {
    let failure = WorkspaceFailure(.forbidden, message: "No access to src")
    let source = SampleWorkspaceDataSource(failures: ["src": failure])
    let tree = FileTreeModel(source: source)
    await tree.loadRoot()
    await tree.expand("src")
    #expect(tree.rows.contains { $0.content == .failure(failure) })
    source.failures = [:]
    await tree.retry("src")
    #expect(!tree.rows.contains { $0.id == "src#failure" })
    #expect(tree.rows.contains { $0.id == "src/main.rs" })

    let rootSource = SampleWorkspaceDataSource(failures: ["": failure])
    let rootTree = FileTreeModel(source: rootSource)
    await rootTree.loadRoot()
    #expect(rootTree.rootFailure == failure)
  }

  @Test("an empty directory says so")
  func emptyDirectory() async {
    let tree = FileTreeModel(source: SampleWorkspaceDataSource())
    await tree.loadRoot()
    await tree.expand(".git")
    #expect(tree.rows.contains { $0.id == ".git#empty" })
  }

  @Test("keyboard: arrows move, right steps in, left steps out, return opens")
  func keyboard() async {
    let tree = FileTreeModel(source: SampleWorkspaceDataSource())
    var opened: [String] = []
    tree.onOpen = { opened.append($0.path) }
    await tree.loadRoot()
    tree.moveSelection(by: 1)
    #expect(tree.selection == ".git")
    tree.moveSelection(by: 3)
    #expect(tree.selection == "src")
    await tree.stepIn()
    #expect(tree.expanded.contains("src"))
    await tree.stepIn()
    #expect(tree.selection == "src/util")
    tree.moveSelection(by: 3)
    #expect(tree.selection == "src/main.rs")
    await tree.activateSelection()
    #expect(opened == ["src/main.rs"])
    tree.stepOut()
    #expect(tree.selection == "src")
    tree.stepOut()
    #expect(!tree.expanded.contains("src"))
    tree.moveSelection(by: 100)
    #expect(tree.selection == "README.md")
    tree.moveSelection(by: -100)
    #expect(tree.selection == ".git")
  }

  @Test("reveal expands ancestors; refresh re-reads expanded directories only")
  func revealAndRefresh() async {
    let source = SampleWorkspaceDataSource()
    let tree = FileTreeModel(source: source)
    await tree.loadRoot()
    await tree.reveal("src/util/mod.rs")
    #expect(tree.expanded == ["src", "src/util"])
    #expect(tree.selection == "src/util/mod.rs")
    #expect(tree.rows.first { $0.id == "src/util/mod.rs" }?.depth == 2)
    await tree.expand("docs")
    tree.collapse("docs")
    let before = source.requests.count
    await tree.refresh()
    #expect(Array(source.requests.dropFirst(before)) == ["list ", "list src", "list src/util"])
  }
}

@Suite("Search, changes and documents")
struct WorkspaceModelTests {
  @Test("content search keeps the searched query and selects the first match")
  func search() async {
    let model = ContentSearchModel(source: SampleWorkspaceDataSource())
    await model.search()
    #expect(model.state == .idle, "a blank query is not sent")
    model.query.query = "Fixture Needle"
    await model.search()
    #expect(model.state.value?.matchCount == 7)
    #expect(model.searchedQuery?.query == "Fixture Needle")
    #expect(model.selection == "README.md:3:1")
    model.moveSelection(by: 1)
    #expect(model.selection == "README.md:5:7")
    model.query.query = "edited, not searched"
    #expect(model.state.value?.matchCount == 7)
  }

  @Test("content search failures carry the server's reason")
  func searchFailure() async {
    let source = SampleWorkspaceDataSource()
    source.searchFailure = WorkspaceFailure(.searchFailed, message: "regex parse error")
    let model = ContentSearchModel(source: source)
    model.query = ContentSearchQuery(query: "(unclosed", regex: true)
    await model.search()
    #expect(model.state.failure?.message == "regex parse error")
  }

  @Test("changes reload keeps a valid selection")
  func changes() async {
    let model = ChangesModel(source: SampleWorkspaceDataSource())
    await model.reload()
    #expect(model.state.value?.totals.files == 4)
    model.moveSelection(by: 1)
    #expect(model.selection == "src/new_file.rs")
    await model.reload()
    #expect(model.selection == "src/new_file.rs")
    model.selection = "gone.txt"
    await model.reload()
    #expect(model.selection == nil)
  }

  @Test("opening documents reads files and diffs; failures stay visible")
  func documents() async {
    let source = SampleWorkspaceDataSource()
    let browser = WorkspaceBrowserModel(source: source)
    await browser.open(.file(path: "src/main.rs", line: 3))
    #expect(browser.file.value?.path == "src/main.rs")
    await browser.open(.diff(path: "src/lib.rs"))
    #expect(browser.diff.value?.hunks.count == 3)
    #expect(browser.file == .idle)
    await browser.open(.diff(path: "README.md"))
    #expect(browser.diff.failure?.kind == .notChanged)
    browser.close()
    #expect(browser.document == nil)
  }

  @Test("documents open as tabs; closing the shown one shows its neighbour")
  func documentTabs() async {
    let browser = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await browser.open(.file(path: "README.md", line: nil))
    await browser.open(.diff(path: "src/lib.rs"))
    await browser.open(.file(path: "src/main.rs", line: nil))
    await browser.open(.file(path: "README.md", line: 4))
    #expect(
      browser.openDocuments.map(\.tabID) == [
        "file:README.md", "diff:src/lib.rs", "file:src/main.rs",
      ])
    #expect(
      browser.openDocuments.first == .file(path: "README.md", line: 4), "the tab takes the line")
    #expect(browser.document == .file(path: "README.md", line: 4))

    await browser.close(.file(path: "README.md", line: nil))
    #expect(browser.document == .diff(path: "src/lib.rs"))
    #expect(browser.diff.value?.path == "src/lib.rs")
    await browser.close(.file(path: "src/main.rs", line: nil))
    #expect(
      browser.document == .diff(path: "src/lib.rs"), "closing a hidden tab keeps the shown one")

    browser.hideDocument()
    #expect(browser.document == nil)
    #expect(browser.openDocuments.count == 1, "showing the panel keeps the tabs")
    await browser.open(.diff(path: "src/lib.rs"))
    await browser.close(.diff(path: "src/lib.rs"))
    #expect(browser.document == nil)
    #expect(browser.openDocuments.isEmpty)
  }

  @Test("opening a file from the tree opens it in the browser")
  func treeOpens() async {
    let browser = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await browser.tree.loadRoot()
    browser.tree.selection = "README.md"
    await browser.tree.activateSelection()
    for _ in 0..<20 where browser.file.value == nil { await Task.yield() }
    #expect(browser.document == .file(path: "README.md", line: nil))
    #expect(browser.file.value?.path == "README.md")
  }
}

@Suite("View state helpers")
struct ViewStateTests {
  @Test("UTF-16 and UTF-8 ranges map to string indices on character boundaries")
  func ranges() {
    let text = "\u{1F600} fixture needle again."
    let utf16 = TextRange(start: 3, end: 17).utf16Range(in: text)
    #expect(utf16.map { String(text[$0]) } == "fixture needle")
    let utf8 = TextRange(start: 5, end: 19).utf8Range(in: text)
    #expect(utf8.map { String(text[$0]) } == "fixture needle")
    #expect(TextRange(start: 1, end: 2).utf16Range(in: text) == nil, "splits a surrogate pair")
    #expect(TextRange(start: 0, end: 99).utf16Range(in: text) == nil)
    #expect(TextRange(start: 2, end: 1).utf8Range(in: text) == nil)
  }

  @Test("hunk navigation stops at the ends")
  func hunks() {
    var navigator = HunkNavigator(total: 3)
    #expect(navigator.label == "3 changes")
    #expect(navigator.next() == 0)
    #expect(navigator.next() == 1)
    #expect(navigator.next() == 2)
    #expect(navigator.next() == 2)
    #expect(navigator.label == "Change 3 of 3")
    #expect(navigator.previous() == 1)
    var empty = HunkNavigator(total: 0)
    #expect(empty.next() == nil)
    #expect(empty.label == "No changes")
  }

  @Test("automatic layout goes side by side on wide windows")
  func layout() {
    #expect(DiffLayoutMode.automatic.resolved(width: 1_200) == .split)
    #expect(DiffLayoutMode.automatic.resolved(width: 700) == .unified)
    #expect(DiffLayoutMode.unified.resolved(width: 1_200) == .unified)
  }

  @Test("sample diffs pair removals with additions like the core")
  func sampleSplitRows() {
    let rows = WorkspaceSamples.libDiff.splitRows
    guard case .line(let left?, let right?) = rows[1] else {
      Issue.record("expected a paired row, got \(rows[1])")
      return
    }
    #expect(left.kind == .removed && right.kind == .added)
    #expect(left.changed == TextRange(start: 19, end: 19))
    #expect(right.changed == TextRange(start: 19, end: 51))
    #expect(WorkspaceSamples.libDiff.added == 6 && WorkspaceSamples.libDiff.removed == 4)
  }
}

@Suite("Syntax highlighting")
struct SyntaxHighlighterTests {
  private func tokens(_ line: String, _ language: SyntaxLanguage) -> [(SyntaxToken, String)] {
    let units = Array(line.utf16)
    return SyntaxHighlighter(language: language).spans(in: line).map {
      ($0.token, String(decoding: units[$0.range], as: UTF16.self))
    }
  }

  @Test("keywords, strings, numbers, types and line comments")
  func rust() {
    let found = tokens("pub fn greet(n: u32) -> String { \"hi \\\"x\\\"\" } // 42", .rust)
    #expect(found.map(\.0) == [.keyword, .keyword, .type, .string, .comment])
    #expect(found[3].1 == "\"hi \\\"x\\\"\"")
    #expect(found[4].1 == "// 42")
    #expect(tokens("let x = 1_000.5;", .swift).map(\.0) == [.keyword, .number])
    #expect(tokens("total2 = x", .python).isEmpty, "digits inside identifiers are not numbers")
  }

  @Test("hash comments, unterminated strings and markdown")
  func others() {
    #expect(tokens("echo 'a' # done", .bash).map(\.0) == [.string, .comment])
    #expect(tokens("x = \"open", .python).map(\.1) == ["\"open"])
    #expect(tokens("# Title", .markdown).map(\.0) == [.type])
    #expect(tokens("plain text", .markdown).isEmpty)
  }
}
