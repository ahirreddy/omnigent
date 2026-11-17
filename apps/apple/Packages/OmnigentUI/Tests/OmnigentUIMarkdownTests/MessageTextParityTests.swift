#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The TextKit renderer beside the SwiftUI one: the same markdown takes the same height, and
  /// its lines sit on the same baselines.
  @MainActor
  @Suite("TextKit message text beside SwiftUI's", .serialized)
  struct MessageTextParityTests {
    nonisolated static let samples: [(name: String, markdown: String)] = [
      ("line", "Hello there, a single line."),
      (
        "wrapped",
        String(repeating: "A paragraph long enough to wrap over several lines here. ", count: 5)
      ),
      ("heading", "# A heading\n\nA paragraph under it."),
      ("headings", "## Second level\n\nText.\n\n### Third level\n\nMore text."),
      ("list", "- one\n- two\n  - nested with *emphasis*\n- three"),
      ("ordered", "1. first\n2. second\n3. third"),
      ("tasks", "- [x] reproduce\n- [x] fix\n- [ ] ship the release"),
      ("quote", "> Note: this is quoted.\n>\n> A second quoted paragraph."),
      ("code", "Before.\n\n```swift\n\(Self.code(lines: 10))\n```\n\nAfter."),
      ("rule", "Above.\n\n---\n\nBelow."),
      ("table", Self.table(rows: 4)),
      ("inline", "Calls `process(batch:)` once per item; see [the note](https://example.com/n)."),
      ("answer", Self.answer),
    ]

    nonisolated static func code(lines: Int) -> String {
      (1...lines).map { "let value\($0) = \($0)" }.joined(separator: "\n")
    }

    nonisolated static func table(rows: Int) -> String {
      let head = [
        "| Step | Owner | Status | Latency (ms) | Notes |", "| --- | :---: | --- | ---: | --- |",
      ]
      let body = (0..<rows).map { row in
        "| \(row + 1) | team-\(row % 4) | done | \(row * 37 % 900) | `item_\(row)` with **bold** |"
      }
      return (head + body).joined(separator: "\n")
    }

    /// One of the long transcript's answers (seed-large-fixtures.py, turn 12).
    nonisolated static let answer = """
      ## Step 12: caching

      I looked at the caching path again. The handler calls `process(batch:)` once per item, \
      which is quadratic for large batches; batching the writes fixes it. See \
      [the design note](https://example.com/design) for the background.

      - Moved the parsing out of the hot loop
      - Kept the public API unchanged
        - nested detail with *emphasis*
      - Added a regression test

      ```swift
      struct Model12: Codable, Hashable {
      \(Self.code(lines: 48))
      }
      ```

      \(Self.table(rows: 8))

      - [x] reproduce
      - [ ] ship the release

      > Note: this is seeded profiling data, not a real answer.
      """

    private func height(_ renderer: MessageTextRenderer, _ markdown: String) -> CGFloat {
      let view = MessageMarkdown(text: markdown).environment(\.messageTextRenderer, renderer)
      let host = NSHostingView(
        rootView: view.frame(width: 600).fixedSize(horizontal: false, vertical: true))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }

    @Test("Every kind of block takes the height SwiftUI gives it", arguments: samples.map(\.name))
    func heights(name: String) throws {
      let markdown = try #require(Self.samples.first { $0.name == name }?.markdown)
      let swiftUI = height(.swiftUI, markdown)
      let textKit = height(.textKit, markdown)
      #expect(abs(swiftUI - textKit) < 1, "SwiftUI \(swiftUI), TextKit \(textKit)")
    }

    @Test("Body, heading, list and code lines sit on SwiftUI's baselines, within a point")
    func baselines() throws {
      let markdown = """
        Hello there

        # H1 line

        ## H2 line

        ### H3 line

        - item

        ```swift
        let code = 1
        ```

        After `code` text
        """
      let swiftUI = try swiftUIBaselines(markdown)
      let textKit = try textKitBaselines(markdown)
      #expect(textKit.count == 7)
      for baseline in textKit {
        let nearest = swiftUI.min { abs($0 - baseline) < abs($1 - baseline) } ?? .infinity
        // SwiftUI rounds a heading's baseline to the backing scale's pixel; TextKit to a point.
        #expect(abs(nearest - baseline) <= 1, "\(baseline) vs \(swiftUI)")
      }
    }

    @Test("Renders both renderers' samples where OMNIGENT_UI_RENDER_DIR says, to compare by eye")
    func renders() throws {
      guard RenderSupport.outputDirectory != nil else { return }
      for sample in Self.samples {
        for renderer in [MessageTextRenderer.swiftUI, .textKit] {
          for scheme in [ColorScheme.light, .dark] {
            let rendered = try RenderSupport.render(
              MessageMarkdown(text: sample.markdown)
                .environment(\.messageTextRenderer, renderer).padding(20),
              width: 700, scheme: scheme, layout: .regular)
            let look = scheme == .dark ? "dark" : "light"
            try RenderSupport.write(rendered, name: "\(sample.name)-\(renderer.rawValue)-\(look)")
          }
        }
      }
    }

    /// Each line's baseline as SwiftUI lays out `markdown`, from the top.
    private func swiftUIBaselines(_ markdown: String) throws -> [CGFloat] {
      let captured = CapturedBaselines()
      let screen = OffscreenWindow(
        AnyView(
          MarkdownView(markdown)
            .overlayPreferenceValue(Text.LayoutKey.self) { layouts in
              GeometryReader { proxy in
                Color.clear.onAppear {
                  for anchored in layouts {
                    let origin = proxy[anchored.origin]
                    captured.values += anchored.layout.map { origin.y + $0.origin.y }
                  }
                }
              }
            }
            .frame(width: 600, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)),
        width: 600, height: 600)
      defer { screen.close() }
      return captured.values
    }

    /// Each line's baseline as the TextKit view draws `markdown`, from the top, without code
    /// block headers (whose label is a control).
    private func textKitBaselines(_ markdown: String) throws -> [CGFloat] {
      let screen = OffscreenWindow(
        AnyView(
          MessageMarkdown(text: markdown).environment(\.messageTextRenderer, .textKit)
            .frame(width: 600, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)),
        width: 600, height: 600)
      defer { screen.close() }
      var baselines: [CGFloat] = []
      for content in screen.allViews.compactMap({ $0 as? MessageTextContentView }) {
        let text = content.textView
        let top = text.convert(CGPoint.zero, to: screen.host).y
        let layout = try #require(text.textLayoutManager)
        _ = layout.enumerateTextLayoutFragments(
          from: layout.documentRange.location, options: [.ensuresLayout]
        ) { fragment in
          guard let paragraph = fragment.textElement as? NSTextParagraph,
            paragraph.attributedString.length > 0
          else { return true }
          let string = paragraph.attributedString
          // Nothing reads the effective range back.
          let mark =
            unsafe string.attribute(.messageBlock, at: 0, effectiveRange: nil) as? MessageBlockMark
          if case .codeHeader? = mark?.role { return true }
          baselines += fragment.textLineFragments.map { line in
            top + fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
              + line.glyphOrigin.y
          }
          return true
        }
      }
      return baselines
    }
  }

  @MainActor
  final class CapturedBaselines {
    var values: [CGFloat] = []
  }
#endif
