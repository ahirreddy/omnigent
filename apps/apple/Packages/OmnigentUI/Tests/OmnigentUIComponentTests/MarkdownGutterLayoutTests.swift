#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Markdown gutter layout", .serialized)
  @MainActor
  struct MarkdownGutterLayoutTests {
    /// Records where each named piece lands.
    private final class Frames {
      var byName: [String: CGRect] = [:]
    }

    private struct Tracked<Content: View>: View {
      let name: String
      let frames: Frames
      @ViewBuilder let content: Content

      var body: some View {
        content.onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .named("root"))
        } action: { frame in
          frames.byName[name] = frame
        }
      }
    }

    private func host(_ view: some View) -> OffscreenWindow<AnyView> {
      transcriptScreen(view.coordinateSpace(.named("root")), width: 400, height: 300)
    }

    private func renderTime(_ source: String) -> Duration {
      ContinuousClock().measure {
        let screen = transcriptScreen(ScrollView { MarkdownView(source) })
        screen.close()
      }
    }

    /// Steps up in depth, so exponential layout fails here instead of hanging the run. The limit
    /// grows with a shallow render's time, so a busy machine slows both sides of the comparison.
    private func expectCheapRender(_ source: (Int) -> String) {
      let shallow = min(renderTime(source(1)), renderTime(source(1)))
      let limit = max(.seconds(5), shallow * 30)
      for depth in [4, 8, 10, 12, 14, 16, 18, 20, 40] {
        let spent = renderTime(source(depth))
        guard spent < limit else {
          Issue.record("Depth \(depth) took \(spent); the limit was \(limit)")
          return
        }
      }
    }

    @Test("A deeply nested answer draws quickly instead of freezing the app")
    func deepNestingIsCheap() {
      expectCheapRender { depth in
        (0..<depth).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
      }
      expectCheapRender { depth in
        (0..<depth).map { String(repeating: "   ", count: $0) + "1. item" }.joined(separator: "\n")
      }
      expectCheapRender { String(repeating: "> ", count: $0) + "bottom" }
      expectCheapRender { depth in
        (0..<depth).map { index in
          String(repeating: "> ", count: index) + (index.isMultiple(of: 2) ? "- item" : "text")
        }.joined(separator: "\n")
      }
    }

    @Test("Nesting past the limit keeps its words, as text")
    func nestingLimit() throws {
      let source = String(repeating: "> ", count: MarkdownParser.maxNesting + 4) + "bottom"
      var blocks = MarkdownParser.parse(source)
      var depth = 0
      while case .quote(let inner)? = blocks.first {
        blocks = inner
        depth += 1
      }
      #expect(depth == MarkdownParser.maxNesting)
      guard case .paragraph(let text)? = blocks.first else {
        Issue.record("Expected the remainder as text")
        return
      }
      #expect(String(text.characters).contains("bottom"))
      let view = transcriptScreen(MarkdownView(source))
      defer { view.close() }
      #expect(try view.shows("bottom"))
    }

    @Test("A quote's rule runs the content's height, and the content takes the remaining width")
    func rule() throws {
      let frames = Frames()
      let screen = host(
        MarkdownGutterLayout(gutter: .fullHeightRule, spacing: 10) {
          Tracked(name: "rule", frames: frames) { Color.red.frame(width: 3) }
          Tracked(name: "content", frames: frames) {
            Color.blue.frame(maxWidth: .infinity).frame(height: 80)
          }
        })
      defer { screen.close() }
      let rule = try #require(frames.byName["rule"])
      let content = try #require(frames.byName["content"])
      #expect(rule.width == 3)
      #expect(rule.height == 80)
      #expect(content.minX == 13)
      #expect(content.width == 387)
    }

    @Test("A marker sits on the content's first baseline, whichever is taller")
    func baselines() throws {
      for (markerSize, contentSize) in [(CGFloat(30), CGFloat(10)), (10, 30)] {
        let frames = Frames()
        let screen = host(
          MarkdownGutterLayout(gutter: .baselineMarker, spacing: 8) {
            Tracked(name: "marker", frames: frames) { Text("1.").font(.system(size: markerSize)) }
            Tracked(name: "content", frames: frames) {
              Text("Body").font(.system(size: contentSize))
            }
          })
        defer { screen.close() }
        let marker = try #require(frames.byName["marker"])
        let content = try #require(frames.byName["content"])
        if markerSize > contentSize {
          #expect(content.minY > marker.minY)
        } else {
          #expect(marker.minY > content.minY)
        }
        #expect(content.minX == marker.maxX + 8)
      }
    }

    @Test("A list opening with a list lines its marker up with the inner first line")
    func nestedBaseline() throws {
      let frames = Frames()
      let screen = host(
        MarkdownGutterLayout(gutter: .baselineMarker, spacing: 8) {
          Tracked(name: "outer", frames: frames) { Text("1.").font(.system(size: 10)) }
          MarkdownGutterLayout(gutter: .baselineMarker, spacing: 8) {
            Text("a.").font(.system(size: 30))
            Tracked(name: "inner", frames: frames) { Text("Body").font(.system(size: 30)) }
          }
        })
      defer { screen.close() }
      let outer = try #require(frames.byName["outer"])
      let inner = try #require(frames.byName["inner"])
      #expect(outer.minY > inner.minY)
    }

    @Test("A width too narrow for the gutter still gives the content a size")
    func narrow() throws {
      let frames = Frames()
      let screen = transcriptScreen(
        MarkdownGutterLayout(gutter: .baselineMarker, spacing: 8) {
          Text("1.").frame(minWidth: 22)
          Tracked(name: "content", frames: frames) { Text("Body") }
        }
        .frame(width: 10)
        .coordinateSpace(.named("root")), width: 400, height: 300)
      defer { screen.close() }
      let content = try #require(frames.byName["content"])
      #expect(content.width >= 0)
    }

    @Test("Without its two pieces the layout takes no room")
    func wrongCount() {
      let screen = host(MarkdownGutterLayout(gutter: .fullHeightRule, spacing: 8) { Text("Only") })
      defer { screen.close() }
      #expect(screen.host.fittingSize.width >= 0)
    }
  }
#endif
