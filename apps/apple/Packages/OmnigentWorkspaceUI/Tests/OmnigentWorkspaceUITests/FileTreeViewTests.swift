#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  // A fake's witnesses are async because the protocol's are.
  // swiftlint:disable async_without_await

  /// A directory listing with no more behavior than the tests ask of it.
  @MainActor
  final class ListedSource: WorkspaceDataSource {
    var entries: [String: [WorkspaceEntry]]
    var nextCursors: [String: String] = [:]
    var absoluteRoot: String?
    var requests: [String] = []
    var failure: WorkspaceFailure?
    var matches = PathSearchResult(entries: [])
    private let sample = SampleWorkspaceDataSource()

    init(_ entries: [String: [WorkspaceEntry]], absoluteRoot: String? = nil) {
      self.entries = entries
      self.absoluteRoot = absoluteRoot
    }

    func listDirectory(_ path: String, after cursor: String?) async throws(WorkspaceFailure)
      -> DirectoryPage
    {
      requests.append("list \(path)")
      if let failure { throw failure }
      return DirectoryPage(
        directory: path, entries: entries[path] ?? [],
        nextCursor: cursor == nil ? nextCursors[path] : nil)
    }
    func readFile(_ path: String) async throws(WorkspaceFailure) -> WorkspaceFile {
      try await sample.readFile(path)
    }
    func searchPaths(_ query: String, include: String, exclude: String)
      async throws(WorkspaceFailure) -> PathSearchResult
    {
      requests.append("search \(query)")
      if let failure { throw failure }
      return matches
    }
    func searchContent(_ query: ContentSearchQuery) async throws(WorkspaceFailure)
      -> ContentSearchResult
    { try await sample.searchContent(query) }
    func changes() async throws(WorkspaceFailure) -> ChangesList { try await sample.changes() }
    func diff(_ path: String) async throws(WorkspaceFailure) -> FileDiff {
      try await sample.diff(path)
    }
    func absoluteLocation(of path: String) -> String? {
      absoluteRoot.map { path.isEmpty ? $0 : "\($0)/\(path)" }
    }
    func save(_ path: String, text: String, base: String?) async throws(WorkspaceFailure)
      -> FileSaveResult
    { .saved }
    func comments(on path: String, text: String) async throws(WorkspaceFailure)
      -> [FileCommentLine]
    { [] }
    func addComment(_ body: String, on span: FileTextSpan) async throws(WorkspaceFailure) {}
    // swiftlint:disable:next discouraged_optional_boolean
    func updateComment(_ id: String, body: String?, open: Bool?) async throws(WorkspaceFailure) {}
    func deleteComment(_ id: String) async throws(WorkspaceFailure) {}
    func sendCommentsToAgent(_ ids: [String]) async throws(WorkspaceFailure) {}
  }
  // swiftlint:enable async_without_await

  @MainActor
  @Suite("File tree view", .serialized)
  struct FileTreeViewTests {
    private static let files = [
      WorkspaceEntry(path: "a.txt", kind: .file, size: 12),
      WorkspaceEntry(path: "a-rather-longer-name.txt", kind: .file, size: 12_000),
      WorkspaceEntry(path: "mid.rs", kind: .file, size: 4_096),
      WorkspaceEntry(path: "z.md", kind: .file, size: 1_048_576),
    ]

    private func tree(_ source: ListedSource) async -> FileTreeModel {
      let model = FileTreeModel(source: source)
      await model.loadRoot()
      return model
    }

    private func render<Content: View>(_ screen: OffscreenWindow<Content>) throws
      -> NSBitmapImageRep
    {
      let bitmap = try #require(screen.host.bitmapImageRepForCachingDisplay(in: screen.host.bounds))
      screen.host.cacheDisplay(in: screen.host.bounds, to: bitmap)
      return bitmap
    }

    @Test(
      "file sizes line up on the right however long the name", arguments: [280.0, 360.0, 520.0])
    func sizesAlign(width: Double) async throws {
      let source = ListedSource(["": Self.files])
      let model = await tree(source)
      let screen = OffscreenWindow(
        FileTreeView(model: model, source: source, actions: .none), width: width, height: 200)
      defer { screen.close() }
      let image = try render(screen)
      let scale = CGFloat(image.pixelsWide) / width
      // Below the toolbar; the sizes are the only ink near the right edge.
      let rightColumns = Int((width - 60) * scale)...(image.pixelsWide - 4)
      let bands = InkScan.bands(image, xRange: rightColumns, scale: scale)
        .filter { CGFloat($0.lowerBound) > 44 * scale }
      #expect(bands.count == Self.files.count)
      let edges = bands.compactMap { InkScan.rightEdge(image, band: $0) }
      #expect(edges.count == Self.files.count)
      let spread = (edges.max() ?? 0) - (edges.min() ?? 0)
      #expect(CGFloat(spread) <= 2 * scale, "right edges \(edges) should line up")
      let margin = (CGFloat(image.pixelsWide) - CGFloat(edges.max() ?? 0)) / scale
      #expect(margin < 20, "the sizes sit at the right edge, not \(margin) points in")
    }

    @Test("a long name truncates before its size does")
    func longNameKeepsSize() async throws {
      let long = String(repeating: "very-long-file-name-", count: 8) + ".txt"
      let source = ListedSource(["": [WorkspaceEntry(path: long, kind: .file, size: 4_096)]])
      let model = await tree(source)
      let width = 260.0
      let screen = OffscreenWindow(
        FileTreeView(model: model, source: source, actions: .none), width: width, height: 120)
      defer { screen.close() }
      let image = try render(screen)
      let scale = CGFloat(image.pixelsWide) / width
      let bands = InkScan.bands(
        image, xRange: Int((width - 34) * scale)...(image.pixelsWide - 4), scale: scale
      )
      .filter { CGFloat($0.lowerBound) > 44 * scale }
      #expect(bands.count == 1, "the size is still drawn at the edge")
    }
  }
#endif
