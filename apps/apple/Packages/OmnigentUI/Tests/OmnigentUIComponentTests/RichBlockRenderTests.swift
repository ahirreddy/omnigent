#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Typeset math and Mermaid diagrams through the bundled KaTeX and Mermaid in WebKit.
  @Suite("Math and diagram rendering", .serialized)
  @MainActor
  struct RichBlockRenderTests {
    private let renderer = RichBlockRenderer.shared

    @Test("display math typesets to a tintable image taller than a line")
    func displayMath() async throws {
      let request = RichBlockRequest(
        kind: .math(display: true, size: 15), source: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}")
      let typeset = try await renderer.render(request)
      #expect(typeset.size.width > 100 && typeset.size.height > 30)
      #expect(typeset.image.width >= Int(typeset.size.width))
      #expect(renderer.cached(request) != nil)
    }

    @Test("inline math reports a baseline inside its height")
    func inlineBaseline() async throws {
      let typeset = try await renderer.render(
        RichBlockRequest(kind: .math(display: false, size: 15), source: "x_i^2"))
      #expect(typeset.baseline > 0 && typeset.baseline < typeset.size.height)
    }

    @Test("bad TeX fails with KaTeX's message")
    func badTeX() async {
      await #expect(throws: RichBlockError.self) {
        try await renderer.render(
          RichBlockRequest(kind: .math(display: true, size: 15), source: "\\frac{1}{"))
      }
    }

    @Test("a Mermaid flowchart draws at its natural size; a broken one says why")
    func mermaid() async throws {
      let diagram = try await renderer.render(
        RichBlockRequest(kind: .mermaid(dark: false), source: Self.flowchart))
      #expect(diagram.size.width > 100 && diagram.size.height > 100)
      do {
        _ = try await renderer.render(
          RichBlockRequest(kind: .mermaid(dark: true), source: "graph TD\nA -->"))
        Issue.record("a broken diagram rendered")
      } catch let RichBlockError.invalidSource(message) {
        #expect(!message.isEmpty)
      }
    }

    @Test("rendered math and diagrams show in a reply", arguments: [ColorScheme.light, .dark])
    func reply(scheme: ColorScheme) async throws {
      let size = TypeRamp.defaultBody
      for request in Self.requests(size: size, dark: scheme == .dark) {
        _ = try await renderer.render(request)
      }
      let rendered = try RenderSupport.render(
        MarkdownView(Self.reply).padding(), width: 720, scheme: scheme, layout: .regular)
      try RenderSupport.write(rendered, name: "rich-blocks-\(scheme == .dark ? "dark" : "light")")
      #expect(rendered.size.height > 600)
    }

    static let flowchart =
      "graph TD\n  A[Start] --> B{Ready?}\n  B -->|Yes| C[Ship]\n  B -->|No| D[Fix]"

    static let reply = """
      The roots are \\(x_{1,2}\\) where \\(\\frac{-b}{2a}\\) is the vertex, so
      $$
      x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}
      $$
      and the plan:

      ```mermaid
      \(flowchart)
      ```
      """

    static func requests(size: CGFloat, dark: Bool) -> [RichBlockRequest] {
      [
        RichBlockRequest(kind: .math(display: false, size: size), source: "x_{1,2}"),
        RichBlockRequest(kind: .math(display: false, size: size), source: "\\frac{-b}{2a}"),
        RichBlockRequest(
          kind: .math(display: true, size: size), source: "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}"),
        RichBlockRequest(kind: .mermaid(dark: dark), source: flowchart),
      ]
    }
  }
#endif
