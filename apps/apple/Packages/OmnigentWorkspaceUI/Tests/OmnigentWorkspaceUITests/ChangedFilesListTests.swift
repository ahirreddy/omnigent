#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The changes tab: its states, the summary, and opening a file's diff.
  @MainActor
  @Suite("Changed files list", .serialized)
  struct ChangedFilesListTests {
    private func hosted(
      _ model: ChangesModel, source: any WorkspaceDataSource,
      onOpen: @escaping (ChangedFile) -> Void = { _ in }
    ) -> OffscreenWindow<ChangedFilesList> {
      OffscreenWindow(
        ChangedFilesList(model: model, source: source, actions: .none, onOpen: onOpen),
        width: 360, height: 400)
    }

    @Test("the list loads itself, and shows each file's name and folder")
    func loads() async throws {
      let source = SampleWorkspaceDataSource()
      let model = ChangesModel(source: source)
      let screen = hosted(model, source: source)
      defer { screen.close() }
      #expect(await settle(screen) { model.state.value != nil })
      await flush(screen)
      let list = try #require(model.state.value)
      let read = try shownString(screen)
      #expect(read.contains("\(list.totals.files) changed"), "read: \(read)")
      for file in list.files {
        #expect(read.contains(WorkspacePaths.name(of: file.path)), "\(file.path) in: \(read)")
      }
    }

    @Test("selecting a row opens its diff")
    func selectionOpens() async throws {
      let source = SampleWorkspaceDataSource()
      let model = ChangesModel(source: source)
      var opened: [String] = []
      let screen = hosted(model, source: source) { opened.append($0.path) }
      defer { screen.close() }
      #expect(await settle(screen) { model.state.value != nil })
      await flush(screen)
      let file = try #require(model.state.value?.files.first)
      model.selection = file.path
      #expect(await settle(screen) { opened == [file.path] })
    }

    @Test("a file already open under a diff opens again after another document showed")
    func reopensAfterAnotherDocument() async throws {
      let source = SampleWorkspaceDataSource()
      let browser = WorkspaceBrowserModel(source: source)
      await browser.changes.reload()
      let path = try #require(browser.changes.state.value?.files.first?.path)
      var opened: [String] = []
      let screen = hosted(browser.changes, source: source) { opened.append($0.path) }
      defer { screen.close() }
      browser.changes.selection = path
      #expect(await settle(screen) { opened == [path] })
      await browser.open(.diff(path: path))
      #expect(browser.changes.selection == path, "its own diff keeps the row selected")
      await browser.open(.file(path: "readme.md", line: nil))
      #expect(browser.changes.selection == nil, "another document releases the row")
      await flush(screen)
      browser.changes.selection = path
      #expect(await settle(screen) { opened == [path, path] })
      browser.hideDocument()
      #expect(browser.changes.selection == nil, "going back to the panel releases it too")
    }

    @Test("a failed read offers Try Again, which reads again")
    func failure() async throws {
      let source = ListedSource([:])
      let failing = FailingChanges(source: source)
      let model = ChangesModel(source: failing)
      let screen = hosted(model, source: failing)
      defer { screen.close() }
      #expect(await settle(screen) { model.state.failure != nil })
      await flush(screen)
      #expect(try screen.shows("The server broke"))
      let requests = failing.reads
      failing.fails = false
      let retry = try #require(screen.controlFrames.last)
      #expect(retry.height < 40)
      try screen.click(CGPoint(x: retry.midX, y: retry.midY))
      #expect(await settle(screen) { failing.reads > requests && model.state.failure == nil })
    }

    @Test("no changes says so; a long list says it's cut")
    func emptyAndCut() async throws {
      let source = ListedSource([:])
      let empty = FailingChanges(source: source)
      empty.fails = false
      empty.list = ChangesList(files: [], totals: ChangeTotals())
      let model = ChangesModel(source: empty)
      let screen = hosted(model, source: empty)
      defer { screen.close() }
      #expect(await settle(screen) { model.state.value != nil })
      await flush(screen)
      #expect(try screen.shows("No Changes"))
      let cut = FailingChanges(source: source)
      cut.fails = false
      var list = WorkspaceSamples.changes
      list.hasMore = true
      cut.list = list
      let cutModel = ChangesModel(source: cut)
      let cutScreen = hosted(cutModel, source: cut)
      defer { cutScreen.close() }
      #expect(await settle(cutScreen) { cutModel.state.value != nil })
      await flush(cutScreen)
      #expect(try cutScreen.shows("The server listed the first \(list.files.count)."))
    }
  }

  // swiftlint:disable async_without_await
  /// A source whose changes fail until told otherwise.
  @MainActor
  final class FailingChanges: WorkspaceDataSource {
    private let source: ListedSource
    var fails = true
    var reads = 0
    var list = WorkspaceSamples.changes

    init(source: ListedSource) { self.source = source }

    func changes() async throws(WorkspaceFailure) -> ChangesList {
      reads += 1
      if fails { throw WorkspaceFailure(.server, message: "The server broke") }
      return list
    }

    func listDirectory(_ path: String, after cursor: String?) async throws(WorkspaceFailure)
      -> DirectoryPage
    { try await source.listDirectory(path, after: cursor) }
    func readFile(_ path: String) async throws(WorkspaceFailure) -> WorkspaceFile {
      try await source.readFile(path)
    }
    func searchPaths(_ query: String, include: String, exclude: String)
      async throws(WorkspaceFailure) -> PathSearchResult
    { try await source.searchPaths(query, include: include, exclude: exclude) }
    func searchContent(_ query: ContentSearchQuery) async throws(WorkspaceFailure)
      -> ContentSearchResult
    { try await source.searchContent(query) }
    func diff(_ path: String) async throws(WorkspaceFailure) -> FileDiff {
      try await source.diff(path)
    }
    func absoluteLocation(of path: String) -> String? { nil }
    func save(_ path: String, text: String, base: String?) async throws(WorkspaceFailure)
      -> FileSaveResult
    { try await source.save(path, text: text, base: base) }
    func comments(on path: String, text: String) async throws(WorkspaceFailure)
      -> [FileCommentLine]
    { try await source.comments(on: path, text: text) }
    func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {}
    // swiftlint:disable:next discouraged_optional_boolean
    func updateComment(_ id: String, body: String?, open: Bool?) async throws(WorkspaceFailure) {}
    func deleteComment(_ id: String) async throws(WorkspaceFailure) {}
    func sendCommentsToAgent(_ ids: [String]) async throws(WorkspaceFailure) {}
  }
// swiftlint:enable async_without_await
#endif
