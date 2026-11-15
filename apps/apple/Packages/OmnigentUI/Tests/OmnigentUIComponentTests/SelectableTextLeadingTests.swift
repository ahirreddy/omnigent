#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A selectable text draws through the window's field editor once clicked; its lines must sit
  /// where SwiftUI drew them, through a selection, its popup and after focus moves on.
  @Suite("Selectable text keeps its lines when focused", .serialized)
  @MainActor
  struct SelectableTextLeadingTests {
    private static let source = """
      Plain words with [a link](https://a.test/first) and then enough more words after it that \
      this paragraph wraps on to several lines in the narrow window.

      ```bash
      echo one
      echo two
      echo three
      ```
      """

    /// The rows of device pixels each text inks, line by line; a selection's highlight is darker.
    private func lines(_ screen: OffscreenWindow<AnyView>, in frames: [CGRect]) throws
      -> [[ClosedRange<Int>]]
    {
      let image = try RenderSupport.capture(screen.host).image
      let scale = CGFloat(image.pixelsWide) / screen.host.bounds.width
      return frames.map { frame in
        var runs: [ClosedRange<Int>] = []
        let columns = Int(frame.minX * scale)..<Int(frame.maxX * scale)
        for row in Int(frame.minY * scale)..<Int(frame.maxY * scale) {
          let inked = columns.contains { column in
            guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else {
              return false
            }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3 > 0.55
          }
          guard inked else { continue }
          if let last = runs.last, last.upperBound == row - 1 {
            runs[runs.count - 1] = last.lowerBound...row
          } else {
            runs.append(row...row)
          }
        }
        return runs
      }
    }

    /// Whether each text's lines are where they were, to `slack` device pixels.
    private func same(
      _ lines: [[ClosedRange<Int>]], _ resting: [[ClosedRange<Int>]], slack: Int = 0
    ) -> Bool {
      lines.count == resting.count
        && zip(lines, resting).allSatisfy { text, rest in
          text.count == rest.count
            && zip(text, rest).allSatisfy {
              abs($0.lowerBound - $1.lowerBound) <= slack
                && abs($0.upperBound - $1.upperBound) <= slack
            }
        }
    }

    @Test("Prose and code keep their line positions through a selection and after focus moves")
    func linesStayPut() async throws {
      let screen = transcriptScreen(
        MarkdownView(Self.source)
          .foregroundStyle(.white)
          .padding(.horizontal, 20)
          .padding(.top, 60)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .background(Color.black)
          .transcriptSelectionPopup(reply: { _ in }, ask: nil),
        width: 420, height: 480)
      defer { screen.close() }
      restKeyboard(screen)
      let texts = screen.allViews.compactMap { $0 as? NSTextField }.filter(\.isSelectable)
        .map { $0.convert($0.bounds, to: screen.host) }.sorted { $0.minY < $1.minY }
      try #require(texts.count == 2, "the paragraph and the code")
      let (paragraph, code) = (texts[0], texts[1])
      let resting = try lines(screen, in: texts)
      #expect(resting[0].count >= 3 && resting[1].count == 3, "\(resting)")

      // A double-click selects a word and shows the popup; the highlight brightens edge pixels.
      try screen.click(CGPoint(x: paragraph.minX + 15, y: paragraph.minY + 10), clickCount: 2)
      try await announceSelection(screen)
      #expect(try screen.shows("Reply"))
      let editor = try #require(screen.window.firstResponder as? NSTextView)
      #expect(editor.textLayoutManager != nil, "the field editor stays on TextKit 2")
      let selected = try lines(screen, in: texts)
      #expect(same(selected, resting, slack: 1), "selected \(selected), resting \(resting)")

      try screen.click(CGPoint(x: code.minX + 20, y: code.minY + 8))
      try await letTasksRun(screen)
      let focused = try lines(screen, in: texts)
      #expect(same(focused, resting), "code focused \(focused), resting \(resting)")

      try screen.click(CGPoint(x: 210, y: 460))
      try await letTasksRun(screen)
      let after = try lines(screen, in: texts)
      #expect(same(after, resting), "after \(after), resting \(resting)")
    }
  }
#endif
