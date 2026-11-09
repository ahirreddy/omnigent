#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  /// The browser's less traveled paths: reloads, tabs already gone, comments through the document.
  @MainActor
  @Suite("Workspace edges", .serialized)
  struct WorkspaceEdgeTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
      UserDefaults.standard.removeObject(forKey: "workspace.showsComments")
    }

    private var path: String { WorkspaceSamples.mainFile.path }

    private func editing() -> WorkspaceActions {
      var actions = WorkspaceActions()
      actions.canEdit = true
      return actions
    }

    @Test("when the session's files change, the changes, tree and open file are read again")
    func filesInvalidated() async throws {
      let source = SampleWorkspaceDataSource()
      let model = WorkspaceBrowserModel(source: source)
      await model.tree.loadRoot()
      await model.open(.file(path: path, line: nil))
      let before = source.requests.count
      await model.changedFilesInvalidated()
      let requests = source.requests.dropFirst(before)
      #expect(requests.contains { $0.hasPrefix("list") }, "\(requests)")
      #expect(requests.contains { $0.contains("changes") }, "\(requests)")
      #expect(requests.contains { $0.contains(path) }, "\(requests)")
      #expect(model.file.value?.path == path)
    }

    @Test("with nothing open, a change only reloads the lists")
    func filesInvalidatedWithNothingOpen() async {
      let source = SampleWorkspaceDataSource()
      let model = WorkspaceBrowserModel(source: source)
      await model.changedFilesInvalidated()
      #expect(model.document == nil)
      #expect(model.changes.state.value != nil)
    }

    @Test("closing a tab that's already gone changes nothing")
    func closeGoneTab() async {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      await model.open(.file(path: path, line: nil))
      await model.close(.file(path: "gone.txt", line: nil))
      #expect(model.openDocuments.count == 1)
      #expect(model.document == .file(path: path, line: nil))
    }

    @Test("answering a close for a tab with no editor just closes it")
    func finishCloseWithoutEditor() async {
      let model = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
      let diff = WorkspaceDocument.diff(path: WorkspaceSamples.mainDiff.path)
      await model.open(diff)
      await model.finishClose(of: diff, saving: true)
      #expect(model.openDocuments.isEmpty)
    }

    @Test("comments that can't be read are a failure on that file, and the file still opens")
    func commentsFail() async {
      let source = ListedSource([:])
      source.commentsFailure = WorkspaceFailure(.server, message: "No comments for you")
      let model = WorkspaceBrowserModel(source: source)
      await model.open(.file(path: path, line: nil))
      #expect(model.file.value?.path == path)
      guard case .failed(let failure) = model.comments[path] else {
        Issue.record("expected a failure, got \(String(describing: model.comments[path]))")
        return
      }
      #expect(failure.message == "No comments for you")
    }

    @Test("a selection move starts at the first result when nothing is selected")
    func movesFromNothing() async {
      let search = WorkspaceSamples.searchedModel()
      search.selection = nil
      search.moveSelection(by: 1)
      #expect(search.selection == search.matches.first?.id)
      search.selection = "gone"
      search.moveSelection(by: 1)
      #expect(search.selection == search.matches.first?.id)
      let changes = ChangesModel(source: SampleWorkspaceDataSource())
      await changes.reload()
      changes.selection = nil
      changes.moveSelection(by: 1)
      #expect(changes.selection == changes.state.value?.files.first?.path)
    }

    @Test("a load's state says when it's in flight")
    func loading() {
      #expect(LoadState<Int>.loading.isLoading)
      #expect(!LoadState<Int>.idle.isLoading)
      #expect(!LoadState.loaded(1).isLoading)
    }

    @Test("a path search with no filters asks with empty ones")
    func unfilteredPathSearch() async throws {
      let source = ListedSource([:])
      _ = try await source.searchPaths("needle")
      #expect(source.requests == ["search needle"])
    }

    /// A document showing `path` with one comment and its panel open.
    private func documentWithComment() async throws
      -> (SampleWorkspaceDataSource, OffscreenWindow<WorkspaceDocumentView>)
    {
      let source = SampleWorkspaceDataSource()
      let model = WorkspaceBrowserModel(source: source)
      await model.open(.file(path: path, line: nil))
      try await model.addComment(
        "Look here",
        on: FileTextSpan(path: path, start: 0, end: 2, firstLine: 1, lastLine: 1, text: "fn"))
      let screen = OffscreenWindow(
        WorkspaceDocumentView(model: model, actions: editing()), width: 900, height: 480)
      try screen.click(try #require(screen.appKitButtons.first))
      await flush(screen)
      return (source, screen)
    }

    @Test("Resolve and Delete in the document's panel reach the server")
    func commentsThroughTheDocument() async throws {
      let (source, screen) = try await documentWithComment()
      defer { screen.close() }
      let delete = try #require(screen.appKitButtons.last)
      #expect(delete.hasDestructiveAction)
      let resolve = screen.appKitButtons[screen.appKitButtons.count - 2]
      try screen.click(resolve)
      #expect(await settle(screen) { source.requests.contains { $0.hasPrefix("update-comment") } })
      await flush(screen)
    }

    @Test("Delete in the document's panel removes the comment on the server")
    func deleteThroughTheDocument() async throws {
      let (source, screen) = try await documentWithComment()
      defer { screen.close() }
      let delete = try #require(screen.appKitButtons.last)
      try screen.click(delete)
      #expect(await settle(screen) { source.requests.contains { $0.hasPrefix("delete-comment") } })
    }

    private static let file = WorkspaceFile(
      path: "poems/haiku.txt", byteCount: 9,
      preview: .text(TextPreview(text: "old pond\n", lineCount: 1)))

    @Test("a commented line's gutter mark opens the panel, and Hide closes it")
    func gutterMark() async throws {
      let screen = OffscreenWindow(
        FileViewerView(
          file: Self.file, source: SampleWorkspaceDataSource(), actions: editing(),
          editor: ReviewFixtures.editor(),
          review: ReviewFixtures.context(comments: [ReviewFixtures.comment("one")])),
        width: 900, height: 400)
      defer { screen.close() }
      #expect(!UserDefaults.standard.bool(forKey: "workspace.showsComments"))
      let mark = try #require(
        screen.controlFrames.first { $0.minX < 60 && $0.minY > 30 && $0.height < 30 })
      try screen.click(CGPoint(x: mark.midX, y: mark.midY))
      await flush(screen)
      #expect(UserDefaults.standard.bool(forKey: "workspace.showsComments"))
      #expect(try shownString(screen).contains("Check this"))
      // The panel's first plain button follows the header's Comments toggle.
      try screen.click(screen.appKitButtons[1])
      await flush(screen)
      #expect(!UserDefaults.standard.bool(forKey: "workspace.showsComments"))
    }

    @Test("unsaved edits show in Source until they're saved")
    func dirtySource() throws {
      let editor = ReviewFixtures.editor()
      editor.text = "new pond\n"
      let screen = OffscreenWindow(
        FileViewerView(
          file: Self.file, source: SampleWorkspaceDataSource(), actions: editing(), editor: editor),
        width: 900, height: 400)
      defer { screen.close() }
      #expect(try shownString(screen).contains("new pond"))
      #expect(try !shownString(screen).contains("old pond"))
    }

    @Test("revealing a line scrolls a long file to it")
    func revealScrolls() async throws {
      let text = (1...500).map { "row-\($0)" }.joined(separator: "\n")
      func view(_ line: UInt64?) -> CodeTextView {
        CodeTextView(preview: TextPreview(text: text, lineCount: 500), markedLine: line)
      }
      let screen = OffscreenWindow(view(nil), width: 500, height: 300)
      defer { screen.close() }
      #expect(try !shownString(screen).contains("row-400"))
      screen.host.rootView = view(400)
      await flush(screen)
      #expect(try shownString(screen).contains("row-400"))
    }

    @Test("an empty folder says so when expanded")
    func emptyFolder() async throws {
      let source = ListedSource([
        "": [WorkspaceEntry(path: "empty", kind: .directory)], "empty": [],
      ])
      let model = FileTreeModel(source: source)
      await model.loadRoot()
      await model.expand("empty")
      let screen = OffscreenWindow(
        FileTreeView(model: model, source: source, actions: .none), width: 320, height: 200)
      defer { screen.close() }
      #expect(try screen.shows("Empty folder"))
    }

    @Test("a search in flight says it's searching")
    func searching() async throws {
      let source = ListedSource([:])
      let (gate, release) = AsyncStream<Void>.makeStream()
      source.beforeContentSearch = {
        for await _ in gate { break }
      }
      let model = ContentSearchModel(source: source)
      let screen = OffscreenWindow(
        ContentSearchPanel(model: model, source: source, actions: .none, onOpen: { _ in }),
        width: 360, height: 480)
      defer { screen.close() }
      model.query.query = "needle"
      let search = Task { await model.search() }
      #expect(await settle(screen) { model.state.isLoading })
      await flush(screen)
      #expect(try screen.shows("Searching"))
      release.finish()
      await search.value
      await flush(screen)
      #expect(try !screen.shows("Searching"))
    }
  }
#endif
