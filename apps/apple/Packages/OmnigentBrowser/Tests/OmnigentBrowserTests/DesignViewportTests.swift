import CoreGraphics
import Foundation
import Testing

@testable import OmnigentBrowser

/// Where the visible page sits, as Draw reads it: the page's answer, checked, and the mapping
/// between a view's points and the page's CSS pixels.
@Suite("Design tools: the page's viewport")
struct DesignViewportTests {
  @Test("the page's answer is read, and anything else refused")
  func answers() throws {
    let read = try BrowserDesignViewport.viewport(
      from: .string(#"{"x":12.5,"y":300,"width":640}"#))
    #expect(read == BrowserDesignViewport(origin: CGPoint(x: 12.5, y: 300), width: 640))
    for answer: BrowserScriptValue in [
      .string(#"{"x":0,"y":0,"width":0}"#), .string(#"{"x":"0","y":0,"width":10}"#),
      .string(#"{"y":0,"width":10}"#), .string("null"), .string("[1,2]"), .number(3), .undefined,
    ] {
      #expect(throws: BrowserError.self) { try BrowserDesignViewport.viewport(from: answer) }
    }
  }

  @Test("a view's points and the page's CSS pixels map both ways, and onto a screenshot")
  func mapping() {
    // Scrolled to (10, 200) at 200%: a view 400 points wide shows 200 CSS pixels.
    let viewport = BrowserDesignViewport(origin: CGPoint(x: 10, y: 200), width: 200)
    let page = viewport.pagePoint(CGPoint(x: 100, y: 50), viewWidth: 400)
    #expect(page == CGPoint(x: 60, y: 225))
    #expect(viewport.viewPoint(page, viewWidth: 400) == CGPoint(x: 100, y: 50))
    // A screenshot 800 pixels wide of the same area.
    #expect(page.applying(viewport.transform(toWidth: 800)) == CGPoint(x: 200, y: 100))
    #expect(BrowserDesignViewport.unscrolled(viewWidth: 0).width == 1)
  }
}
