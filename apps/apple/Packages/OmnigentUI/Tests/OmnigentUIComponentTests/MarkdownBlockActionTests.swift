#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The controls on Markdown's blocks: saving code and tables through the save panel, and
  /// zooming an enlarged image.
  @Suite("Markdown blocks: download and zoom", .serialized)
  @MainActor
  struct MarkdownBlockActionTests {
    init() {
      SystemSideEffects.reset()
    }

    /// A file in a new folder, which the save panel is told the person chose.
    private func exportURL(_ name: String) throws -> URL {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("markdown-export-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      return folder.appendingPathComponent(name)
    }

    private func savedText(at url: URL) -> String? {
      guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
      return String(bytes: data, encoding: .utf8)
    }

    // MARK: Code blocks

    @Test("Download on a code block saves the code where the save panel says")
    func codeDownloadSaves() async throws {
      let url = try exportURL("snippet.swift")
      SystemSideEffects.answer(panel: .OK, panelURL: url)
      let screen = transcriptScreen(CodeBlockView(code: "let a = 1", language: "swift"))
      defer { screen.close() }
      try screen.clickControl(at: 1)
      let saved = await screen.waitUntil { savedText(at: url) != nil }
      #expect(saved, "panels shown: \(SystemSideEffects.record.panelCount)")
      #expect(savedText(at: url) == "let a = 1")
      #expect(SystemSideEffects.record.panelCount == 1)
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }

    @Test("Cancelling the save panel saves nothing and reports nothing")
    func codeDownloadCancelled() async throws {
      let url = try exportURL("snippet.swift")
      SystemSideEffects.answer(panel: .cancel, panelURL: url)
      let screen = transcriptScreen(CodeBlockView(code: "let a = 1", language: "swift"))
      defer { screen.close() }
      try screen.clickControl(at: 1)
      let asked = await screen.waitUntil { SystemSideEffects.record.panelCount == 1 }
      #expect(asked)
      try await letTasksRun(screen, milliseconds: 200)
      #expect(savedText(at: url) == nil)
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
    }

    // MARK: Tables

    @Test("A table downloads as CSV and as Markdown, each to the file the panel names")
    func tableDownloads() async throws {
      let screen = transcriptScreen(
        MarkdownView("| Name | Size |\n| --- | ---: |\n| a | 1 |\n| b | 2 |"))
      defer { screen.close() }
      let frames = screen.controlFrames
      #expect(frames.count == 3, "Copy, Download and Expand")
      let download = CGPoint(x: frames[1].midX, y: frames[1].midY)

      let csv = try exportURL("table.csv")
      SystemSideEffects.answer(panel: .OK, panelURL: csv)
      try screen.choose("Download CSV", in: try screen.openMenu(download))
      let rows = { savedText(at: csv)?.split(whereSeparator: \.isNewline).map(String.init) }
      #expect(await screen.waitUntil { rows() == ["Name,Size", "a,1", "b,2"] }, "\(rows() ?? [])")
      // The exporter closes once the file is written; the next download needs it closed.
      await screen.settleTasks()

      let markdown = try exportURL("table.md")
      SystemSideEffects.answer(panel: .OK, panelURL: markdown)
      try screen.choose("Download Markdown", in: try screen.openMenu(download))
      #expect(await screen.waitUntil { savedText(at: markdown) != nil })
      #expect(savedText(at: markdown)?.hasPrefix("| Name") == true)
      #expect(SystemSideEffects.record.panelCount == 2)
    }

    // MARK: The enlarged image

    /// The enlarged image as a sheet, as the transcript shows it, drawn far larger than the sheet.
    private func lightbox() -> OffscreenWindow<AnyView> {
      let screen = OffscreenWindow(
        AnyView(
          ComposerSheetHost(
            sheet: ImageLightbox(
              image: Image(systemName: "photo"), size: CGSize(width: 4_000, height: 3_000),
              title: "A chart"))), width: 1_000, height: 800)
      _ = MainLoop.settle(until: { screen.window.attachedSheet != nil })
      return screen
    }

    /// How many times larger than its viewport the image's canvas is, along its longer side.
    private func extent(_ screen: OffscreenWindow<AnyView>) throws -> CGFloat {
      let scroll = try #require(screen.allViews.compactMap { $0 as? NSScrollView }.first)
      let canvas = try #require(scroll.documentView).frame.size
      let viewport = scroll.contentView.bounds.size
      return max(canvas.width / viewport.width, canvas.height / viewport.height)
    }

    /// Expects the image's canvas to be `expected` viewports along its longer side.
    private func expectExtent(
      _ expected: CGFloat, on screen: OffscreenWindow<AnyView>,
      sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      let found = try extent(screen)
      #expect(
        abs(found - expected) < 0.05, "\(found) viewports, not \(expected)",
        sourceLocation: sourceLocation)
    }

    /// The sheet's last four buttons: Zoom Out, Fit to Window, Zoom In and Done.
    private func tap(_ button: LightboxButton, on screen: OffscreenWindow<AnyView>) throws {
      try screen.clickControl(at: screen.controlFrames.count - 1 - button.rawValue)
      screen.settle(0.1)
    }

    private enum LightboxButton: Int {
      case done = 0
      case zoomIn = 1
      case fit = 2
      case zoomOut = 3
    }

    @Test("Zoom In enlarges the image by half again, Zoom Out undoes it, and Fit goes back")
    func lightboxButtons() throws {
      let screen = lightbox()
      defer { screen.close() }
      #expect(screen.window.attachedSheet != nil)
      try expectExtent(1, on: screen)
      try tap(.zoomIn, on: screen)
      try expectExtent(1.5, on: screen)
      try tap(.zoomIn, on: screen)
      try expectExtent(2.25, on: screen)
      try tap(.zoomOut, on: screen)
      try expectExtent(1.5, on: screen)
      try tap(.fit, on: screen)
      try expectExtent(1, on: screen)
    }

    @Test("Zooming in stops at eight times the fitted size")
    func lightboxZoomLimit() throws {
      let screen = lightbox()
      defer { screen.close() }
      // Six steps of half again pass eight times; the seventh changes nothing.
      for _ in 0..<6 { try tap(.zoomIn, on: screen) }
      try expectExtent(8, on: screen)
      try tap(.zoomIn, on: screen)
      try expectExtent(8, on: screen)
      try tap(.zoomOut, on: screen)
      try expectExtent(8 / 1.5, on: screen)
    }

    private func pressCommand(_ key: String, on screen: OffscreenWindow<AnyView>) throws -> Bool {
      let sheet = screen.activeWindow
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
        keyCode: 0)
      guard let event else { throw OffscreenWindowError.eventUnavailable }
      let handled = sheet.performKeyEquivalent(with: event)
      screen.settle(0.1)
      return handled
    }

    @Test("Command-Equals, Command-Minus and Command-0 zoom as the buttons do")
    func lightboxKeys() throws {
      let screen = lightbox()
      defer { screen.close() }
      #expect(try pressCommand("=", on: screen))
      #expect(try pressCommand("=", on: screen))
      try expectExtent(2.25, on: screen)
      #expect(try pressCommand("-", on: screen))
      try expectExtent(1.5, on: screen)
      #expect(try pressCommand("0", on: screen))
      try expectExtent(1, on: screen)
    }

    @Test("A pinch zooms the image, and the zoom stays when the fingers lift")
    func lightboxPinch() throws {
      let screen = lightbox()
      defer { screen.close() }
      let sheet = screen.activeWindow
      let scroll = try #require(screen.allViews.compactMap { $0 as? NSScrollView }.first)
      let middle = scroll.convert(
        CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
      let steps: [(NSEvent.Phase, CGFloat)] = [(.began, 0), (.changed, 0.5), (.ended, 0)]
      for (phase, amount) in steps {
        screen.send(
          PinchEventStub(window: sheet, location: middle, phase: phase, amount: amount), to: sheet)
        screen.settle(0.05)
      }
      try expectExtent(1.5, on: screen)
    }
  }
#endif
