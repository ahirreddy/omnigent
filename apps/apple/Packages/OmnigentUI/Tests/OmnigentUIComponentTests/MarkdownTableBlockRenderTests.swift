#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  @Suite("Markdown table block")
  struct MarkdownTableBlockRenderTests {
    static let reply = """
      Summary:

      | Column | Value |
      | --- | --- |
      | Rows | 2 |
      | Mock | yes |

      Done.
      """

    @Test("a table sits in the text with no card behind it", arguments: [ColorScheme.light, .dark])
    func noCard(scheme: ColorScheme) throws {
      let rendered = try RenderSupport.render(
        MarkdownView(Self.reply).padding(), width: 720, scheme: scheme, layout: .regular)
      try RenderSupport.write(
        rendered, name: "markdown-table-\(scheme == .dark ? "dark" : "light")")
      let image = rendered.image
      let background = try #require(image.colorAt(x: 1, y: 1))
      // The narrow table leaves the right edge of the reply empty; a card would fill it.
      let column = image.pixelsWide - image.pixelsWide / 20
      let painted = (0..<image.pixelsHigh).filter { row in
        guard let color = image.colorAt(x: column, y: row) else { return true }
        return Self.distance(color, background) > 0.02
      }
      #expect(painted.isEmpty, "\(painted.count) rows painted at x=\(column)")
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
      guard let lhs = lhs.usingColorSpace(.deviceRGB), let rhs = rhs.usingColorSpace(.deviceRGB)
      else { return 1 }
      return max(
        abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
        abs(lhs.blueComponent - rhs.blueComponent))
    }
  }
#endif
