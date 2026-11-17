#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A TextKit message's table, as ``MarkdownTableBlock``'s: its cells, the scroll a wide one
  /// takes, and its Copy, Download and Expand.
  @MainActor
  @Suite("A TextKit message's tables", .serialized)
  struct MessageTextTableTests {
    @Test("A table's cells start where SwiftUI's grid puts them, inline code and all")
    func tableCells() throws {
      let markdown = MessageTextParityTests.table(rows: 2)
      let captured = CapturedBaselines()
      let swiftUI = OffscreenWindow(
        AnyView(
          MarkdownView(markdown)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
              GeometryReader { proxy in
                Color.clear.onAppear {
                  captured.values = layouts.map { proxy[$0.origin].x }
                }
              }
            }
            .frame(width: 700, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)),
        width: 700, height: 400)
      defer { swiftUI.close() }
      let document = MessageTextFixture.document(markdown)
      let content = MessageTextContentView(document: document)
      _ = content.fittingSize(for: 700, fillsWidth: true)
      let layout = try #require(content.textView.textLayoutManager)
      var starts: [CGFloat] = []
      _ = layout.enumerateTextLayoutFragments(
        from: layout.documentRange.location, options: [.ensuresLayout]
      ) { fragment in
        guard let paragraph = fragment.textElement as? NSTextParagraph,
          let line = fragment.textLineFragments.first
        else { return true }
        let string = paragraph.attributedString.string
        // Each cell starts the line or follows a tab.
        var index = string.startIndex
        var offsets = [0]
        while let tab = string[index...].firstIndex(of: "\t") {
          offsets.append(string.utf16.distance(from: string.startIndex, to: tab) + 1)
          index = string.index(after: tab)
        }
        if string.hasPrefix("\t") { offsets.removeFirst() }
        starts += offsets.map {
          fragment.layoutFragmentFrame.minX + line.typographicBounds.minX
            + line.locationForCharacter(at: $0).x
        }
        return true
      }
      #expect(starts.count == captured.values.count, "\(starts) vs \(captured.values)")
      for (textKit, swiftUIStart) in zip(starts, captured.values) {
        #expect(abs(textKit - swiftUIStart) < 1, "\(starts) vs \(captured.values)")
      }
    }

    @Test("A table wider than its column scrolls sideways; Download saves it; Expand shows it")
    func tableControls() async throws {
      SystemSideEffects.reset()
      let markdown = MessageTextParityTests.table(rows: 3)
      let screen = transcriptScreen(
        MessageMarkdown(text: markdown).environment(\.messageTextRenderer, .textKit)
          .frame(maxHeight: .infinity, alignment: .top),
        width: 320, height: 600)
      defer { screen.close() }
      let content = try #require(MessageTextFixture.contentViews(in: screen).first)
      let overflow = try #require(content.overflows.values.first, "a table too wide scrolls")
      #expect(overflow.contentWidth > 320)
      #expect(overflow.textView.string.contains("team-2"))
      #expect(abs(overflow.frame.width - content.bounds.width) < 0.5)
      #expect(content.fittingSize(for: 900, fillsWidth: true).height > 0)
      content.frame.size.width = 900
      content.layoutSubtreeIfNeeded()
      #expect(content.overflows.isEmpty, "a table that fits draws as text")
      content.frame.size.width = 320
      content.layoutSubtreeIfNeeded()
      #expect(!content.overflows.isEmpty)
      let controls = try #require(
        content.subviews.compactMap { $0 as? MessageTableControlsView }.first)
      #expect(controls.downloadChoices.map(\.title) == ["Download CSV", "Download Markdown"])
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("message-text-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let csv = folder.appendingPathComponent("table.csv")
      SystemSideEffects.answer(panel: .OK, panelURL: csv)
      let download = controls.downloadButton.convert(
        controls.downloadButton.bounds, to: screen.host)
      let host = screen.host
      let hit = unsafe host.hitTest(
        host.convert(CGPoint(x: download.midX, y: download.midY), to: host.superview))
      #expect(hit === controls.downloadButton, "\(String(describing: hit)) at \(download)")
      try screen.choose(
        "Download CSV", in: try screen.openMenu(CGPoint(x: download.midX, y: download.midY)))
      #expect(await screen.waitUntil { FileManager.default.fileExists(atPath: csv.path) })
      #expect(try String(contentsOf: csv, encoding: .utf8).hasPrefix("Step,Owner,Status"))
      try screen.click(controls.expandButton)
      _ = MainLoop.settle(until: { screen.window.attachedSheet != nil })
      #expect(screen.window.attachedSheet != nil)
      #expect(controls.expandButton.isHidden, "Expand hides while the table is out")
      #expect(try screen.shows("team-2"))
      let done = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: done.midX, y: done.midY))
      _ = MainLoop.settle(until: { screen.window.attachedSheet == nil })
      #expect(screen.window.attachedSheet == nil)
      #expect(!controls.expandButton.isHidden)
    }
  }
#endif
