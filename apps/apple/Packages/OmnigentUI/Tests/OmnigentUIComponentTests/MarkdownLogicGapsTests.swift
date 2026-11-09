#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The Markdown layer's refusals and cancelled work.
  @Suite("Markdown edges", .serialized)
  @MainActor
  struct MarkdownLogicGapsTests {
    private func links(
      listFolder: @escaping @MainActor (String) async throws -> WorkspaceFolderListing,
      readImage: (@MainActor (String) async throws -> Data)? = nil
    ) -> WorkspaceFileLinks {
      WorkspaceFileLinks(
        root: { "/repo" }, home: { "/home" }, listFolder: listFolder, readImage: readImage,
        open: { _ in })
    }

    @Test("A listing cancelled by scrolling away is forgotten, so the next view lists it again")
    func cancelledListing() async {
      var calls = 0
      let cancels = EditedValue(true)
      let links = links { _ in
        calls += 1
        if cancels.value { throw CancellationError() }
        return WorkspaceFolderListing(files: ["a.txt"], folders: [])
      }
      let cited = [CitedPath(text: "src/a.txt", explicit: false)]
      await links.check(cited)
      #expect(links.failures.isEmpty, "being cancelled isn't a failure")
      #expect(links.target(for: "src/a.txt", explicit: false) == nil)
      cancels.value = false
      await links.check(cited)
      #expect(calls == 2)
      #expect(links.target(for: "src/a.txt", explicit: false)?.path == "src/a.txt")
    }

    @Test("An image can't be read without a reader or outside the workspace")
    func imageRefusals() async throws {
      let noReader = links { _ in WorkspaceFolderListing(files: [], folders: []) }
      await #expect(throws: WorkspaceImageError.self) { try await noReader.image(at: "a.png") }
      let reader = links(
        listFolder: { _ in WorkspaceFolderListing(files: [], folders: []) },
        readImage: { _ in Data([1]) })
      await #expect(throws: WorkspaceImageError.self) {
        try await reader.image(at: "/elsewhere/a.png")
      }
      #expect(try await reader.image(at: "a.png") == Data([1]))
    }

    @Test("A file URL on another machine isn't a path here")
    func fileURLHost() {
      #expect(WorkspacePaths.linkedPath("file://other.example/etc/hosts") == nil)
      #expect(WorkspacePaths.linkedPath("file:///etc/hosts") == "/etc/hosts")
      #expect(WorkspacePaths.linkedPath("file://localhost/etc/hosts") == nil)
    }

    @Test("A code span holding a shorter run of backticks stays code, math and all")
    func codeSpanRuns() {
      let text = "``a ` $x$ b`` then \\(y\\)"
      let result = MarkdownMath.delimited(text)
      #expect(result.contains("``a ` $x$ b``"))
      #expect(!result.contains("\\(y\\)"))
    }

    @Test("Mermaid unpacks to its text; garbage or non-UTF-8 is an error, not a blank diagram")
    func unpackMermaid() throws {
      func packed(_ bytes: [UInt8]) throws -> Data {
        // swiftlint:disable:next legacy_objc_type
        try (Data(bytes) as NSData).compressed(using: .lzma) as Data
      }
      #expect(try RichBlockRenderer.unpackMermaid(try packed(Array("graph".utf8))) == "graph")
      #expect(throws: (any Error).self) {
        try RichBlockRenderer.unpackMermaid(Data([1, 2, 3]))
      }
      #expect(throws: RichBlockError.unavailable("diagram")) {
        try RichBlockRenderer.unpackMermaid(try packed([0xFF, 0xFE]))
      }
    }

    @Test("A snapshot with nothing in it is a malformed result, not an empty image")
    func emptySnapshot() {
      #expect(throws: RichBlockError.malformedResult) {
        try RichBlockRenderer.cgImage(NSImage(), points: CGSize(width: 10, height: 10))
      }
    }

    @Test("Without the page the renderer says so each time, and asks again")
    func missingPage() async throws {
      let empty = FileManager.default.temporaryDirectory.appending(path: "rich-\(UUID())")
      try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: empty) }
      let renderer = RichBlockRenderer(resources: try #require(Bundle(url: empty)))
      let request = RichBlockRequest(kind: .math(display: true, size: 15), source: "x")
      for _ in 0..<2 {
        await #expect(throws: RichBlockError.unavailable("math and diagram")) {
          try await renderer.render(request)
        }
      }
      #expect(renderer.cached(request) == nil)
    }

    @Test("Without Mermaid a diagram says so each time, and the page stays usable")
    func missingMermaid() async throws {
      let root = FileManager.default.temporaryDirectory.appending(path: "rich-\(UUID())")
      let folder = root.appending(path: "RichRender")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      try Data("<html></html>".utf8).write(to: folder.appending(path: "render.html"))
      let renderer = RichBlockRenderer(resources: try #require(Bundle(url: root)))
      let request = RichBlockRequest(kind: .mermaid(dark: false), source: "graph TD")
      for _ in 0..<2 {
        await #expect(throws: RichBlockError.unavailable("diagram")) {
          try await renderer.render(request)
        }
      }
    }

    @Test("Math KaTeX rejects keeps its Unicode form, with the reason in its help")
    func rejectedMath() async throws {
      let tex = "\\frac{1}{"
      let screen = OffscreenWindow(MathBlockView(tex: tex), width: 400, height: 120)
      defer { screen.close() }
      let request = RichBlockRequest(
        kind: .math(display: true, size: TypeRamp.defaultBody), source: tex)
      await #expect(throws: RichBlockError.self) {
        try await RichBlockRenderer.shared.render(request)
      }
      try await screen.letTasksRun(passes: 20)
      #expect(try screen.shows(MathText.unicode(tex)))
      #expect(RichBlockRenderer.shared.cached(request) == nil)
    }
  }
#endif
