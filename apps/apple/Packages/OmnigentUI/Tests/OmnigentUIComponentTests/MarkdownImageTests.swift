#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Markdown images and diagrams", .serialized)
  @MainActor
  struct MarkdownImageTests {
    private static let pixelBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    private var pixel: Data { Data(base64Encoded: Self.pixelBase64) ?? Data() }

    private func links(readImage: (@MainActor (String) async throws -> Data)?) -> WorkspaceFileLinks
    {
      WorkspaceFileLinks(
        root: { "/repo" }, home: { "/home" },
        listFolder: { _ in WorkspaceFolderListing(files: []) },
        readImage: readImage, open: { _ in })
    }

    private func imageScreen(
      _ source: String, alt: String = "A chart", links: WorkspaceFileLinks? = nil
    )
      -> OffscreenWindow<AnyView>
    {
      transcriptScreen(
        MarkdownImageView(source: source, alt: alt).environment(\.workspaceFileLinks, links))
    }

    @Test("A data image draws and opens large; Done closes it")
    func dataImage() async throws {
      let screen = imageScreen("data:image/png;base64,\(Self.pixelBase64)")
      defer { screen.close() }
      try await letTasksRun(screen)
      #expect(try !screen.shows("A chart"))
      try screen.clickControl(at: 0)
      #expect(screen.window.attachedSheet != nil)
      screen.settle(0.2)
      for title in ["Zoom Out", "Fit to Window", "Zoom In", "Done"] {
        #expect(try screen.shows(title), "\(title)")
      }
      let frames = screen.controlFrames
      #expect(frames.count == 5)
      // Zoom out past its limit, in past its limit, then fit, and the sheet stays through it all.
      for _ in 0..<5 { try screen.clickControl(at: 1) }
      for _ in 0..<8 { try screen.clickControl(at: 3) }
      try screen.clickControl(at: 2)
      #expect(screen.window.attachedSheet != nil)
      try screen.clickControl(at: 4)
      screen.settle(0.2)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("Bytes that aren't an image, or a read that fails, become the chip")
    func failures() async throws {
      struct ReadFailed: LocalizedError {
        var errorDescription: String? { "Disk on fire" }
      }
      let garbage = imageScreen("data:image/png;base64,AAAA")
      defer { garbage.close() }
      try await letTasksRun(garbage)
      #expect(try garbage.shows("A chart"))

      let unreadable = imageScreen(
        "images/p.png", links: links(readImage: { _ in throw ReadFailed() }))
      defer { unreadable.close() }
      try await letTasksRun(unreadable)
      #expect(try unreadable.shows("A chart"))

      let noReader = imageScreen("images/p.png", alt: "", links: links(readImage: nil))
      defer { noReader.close() }
      try await letTasksRun(noReader)
      #expect(try noReader.shows("Image"))

      let noLinks = imageScreen("images/p.png")
      defer { noLinks.close() }
      try await letTasksRun(noLinks)
      #expect(try noLinks.shows("A chart"))

      let refused = imageScreen("https://example.com/p.png")
      defer { refused.close() }
      try await letTasksRun(refused)
      #expect(try refused.shows("A chart"))
    }

    @Test("A workspace image reads through the host's links")
    func workspaceImage() async throws {
      var read: [String] = []
      let bytes = pixel
      let screen = imageScreen(
        "images/p.png",
        links: links(readImage: {
          read.append($0)
          return bytes
        }))
      defer { screen.close() }
      try await letTasksRun(screen)
      #expect(read == ["images/p.png"])
      #expect(try !screen.shows("A chart"))
      #expect(screen.controlFrames.count == 1)
    }

    @Test("A slow image shows its placeholder while it loads")
    func loadingPlaceholder() throws {
      let screen = transcriptScreen(
        LoadedImageView(
          id: "x", alt: "Slow",
          load: {
            try await Task.sleep(for: .seconds(30))
            return Data()
          },
          unavailable: { Text($0) }))
      defer { screen.close() }
      #expect(try !screen.shows("Slow"))
      #expect(screen.controlFrames.isEmpty)
    }

    @Test("A diagram offers its code and copies it, and Show Diagram comes back")
    func mermaidDiagram() async throws {
      SystemSideEffects.reset()
      let screen = transcriptScreen(MermaidBlockView(source: "graph TD; A-->B"))
      defer { screen.close() }
      let drawn = try await waitUntil(screen) { try screen.shows("Diagram") }
      #expect(drawn)
      let frames = screen.controlFrames
      #expect(frames.count == 4)
      try screen.clickControl(at: 2)
      #expect(copiedText() == "graph TD; A-->B")
      try screen.clickControl(at: 0)
      #expect(try screen.shows("graph TD; A-->B"))
      #expect(try screen.shows("Show Diagram"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(try !screen.shows("Show Diagram"))
      try screen.clickControl(at: 1)
      #expect(screen.window.attachedSheet != nil)
    }

    @Test("Clicking a drawn diagram opens it full size")
    func mermaidDiagramEnlarges() async throws {
      let screen = transcriptScreen(MermaidBlockView(source: "graph TD; C-->D"))
      defer { screen.close() }
      let drawn = try await waitUntil(screen) { try screen.shows("Diagram") }
      #expect(drawn)
      #expect(screen.window.attachedSheet == nil)
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(screen.window.attachedSheet != nil)
    }

    @Test("A diagram Mermaid rejects says so, above its code; an open block stays code")
    func mermaidFailure() async throws {
      let source = "graph TD; A--"
      let screen = transcriptScreen(MermaidBlockView(source: source))
      defer { screen.close() }
      let failed = try await waitUntil(screen) {
        try screen.shows("Mermaid couldn\u{2019}t render this diagram")
      }
      #expect(failed)
      #expect(try screen.shows(source))

      let open = transcriptScreen(
        MermaidBlockView(source: "graph TD; X-->Y").environment(\.markdownBlockIsOpen, true))
      defer { open.close() }
      try await letTasksRun(open)
      #expect(try open.shows("graph TD; X-->Y"))
      #expect(try !open.shows("Diagram"))
    }
  }
#endif
