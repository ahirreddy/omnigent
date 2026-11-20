#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import SwiftUI
  import Testing
  import WebKit

  @testable import OmnigentWorkspaceUI

  /// Comments on an HTML file's rendered preview: the bridge's messages, the span a selection
  /// stores and the comment a selection lands on.
  @MainActor
  @Suite("HTML preview comments")
  struct HTMLCommentTests {
    @Test("bridge messages parse as the page script sends them, and malformed ones are refused")
    func messages() {
      #expect(HTMLBridgeMessage.parse(["type": "ready"]) == .ready)
      #expect(
        HTMLBridgeMessage.parse(["type": "selection", "text": "Aurora Sync", "occ": 1])
          == .selection(HTMLSelection(text: "Aurora Sync", occurrence: 1)))
      #expect(
        HTMLBridgeMessage.parse(["type": "selection", "text": "go"])
          == .selection(HTMLSelection(text: "go", occurrence: 0)), "an old page sends no copy")
      #expect(HTMLBridgeMessage.parse(["type": "selection", "text": " \n "]) == nil)
      #expect(HTMLBridgeMessage.parse(["type": "commentClick", "id": "c1"]) == .commentClick("c1"))
      #expect(HTMLBridgeMessage.parse(["type": "commentClick", "id": ""]) == nil)
      #expect(HTMLBridgeMessage.parse(["type": "selectionCleared"]) == .selectionCleared)
      #expect(HTMLBridgeMessage.parse(["type": "zoom", "action": "in"]) == .zoom(.zoomIn))
      #expect(HTMLBridgeMessage.parse(["type": "zoom", "action": "sideways"]) == nil)
      #expect(HTMLBridgeMessage.parse(["type": "scroll", "top": 4]) == nil)
      #expect(HTMLBridgeMessage.parse("ready") == nil)
    }

    @Test("a selection's span keeps the rendered text and takes the source's lines")
    func span() {
      let source = "<h1>Title</h1>\n<p>Hello\n  world</p>\n"
      let span = FileTextSpan.html("Hello world", range: 18..<31, in: source, path: "site/a.html")
      #expect(span.text == "Hello world")
      #expect(span.start == 18 && span.end == 31)
      #expect(span.firstLine == 2 && span.lastLine == 3)
      #expect(span.linesTitle == "lines 2-3")
      let missing = FileTextSpan.html("gone", range: nil, in: source, path: "site/a.html")
      #expect(missing.start == 0 && missing.end == 0 && missing.firstLine == 1)
      let past = FileTextSpan.html("end", range: 90..<99, in: source, path: "site/a.html")
      #expect(past.lastLine == past.firstLine)
    }

    @Test("selecting the text an open comment is on picks that comment, by copy")
    func existing() {
      var first = ReviewFixtures.comment("c1", anchor: "Aurora  Sync")
      first.htmlOccurrence = 0
      var second = ReviewFixtures.comment("c2", anchor: "Aurora Sync")
      second.htmlOccurrence = 1
      var sent = ReviewFixtures.comment("c3", anchor: "Sent text", isOpen: false)
      sent.htmlOccurrence = 0
      let review = HTMLPreviewReview(
        path: "a.html", review: ReviewFixtures.context(comments: [first, second, sent]),
        source: SampleWorkspaceDataSource(), isDirty: false, selectedCommentID: .constant("c3"),
        comment: { _ in }, show: { _ in })
      #expect(
        review.existingComment(on: HTMLSelection(text: "Aurora\nSync", occurrence: 1))?.id == "c2")
      #expect(
        review.existingComment(on: HTMLSelection(text: "Aurora Sync", occurrence: 0))?.id == "c1")
      #expect(review.existingComment(on: HTMLSelection(text: "Aurora Sync", occurrence: 2)) == nil)
      #expect(review.existingComment(on: HTMLSelection(text: "Sent text", occurrence: 0)) == nil)
      #expect(review.marks.map(\.id) == ["c1", "c2", "c3"], "the panel's sent comment shows too")
      #expect(HTMLSelection.folded("  a\t\n b  ") == "a b")
    }

    @Test("zoom shortcuts step through the presets and reset to 100%")
    func zoomKeys() {
      #expect(HTMLPreviewZoom.zoomed(1, by: .zoomIn) == 1.1)
      #expect(HTMLPreviewZoom.zoomed(1, by: .zoomOut) == 0.9)
      #expect(HTMLPreviewZoom.zoomed(2.5, by: .reset) == 1)
    }
  }

  /// The comment script in a real web view: it reports a selection and which copy it is, and
  /// paints the comments the app sends.
  @MainActor
  @Suite("HTML preview comment script", .serialized)
  struct HTMLCommentScriptTests {
    final class Received {
      var messages: [HTMLBridgeMessage] = []
    }

    private static let page = """
      <html><head><title>Aurora Sync</title></head><body>
      <h1>Aurora Sync</h1><p>Use <b>Aurora</b> Sync daily.</p><p id="b">Aurora Sync again</p>
      </body></html>
      """

    private func shown(_ received: Received, marks: [HTMLCommentMark] = [])
      async throws -> (OffscreenWindow<HTMLPreview>, WKWebView)
    {
      let preview = HTMLPreview(
        html: Self.page,
        commenting: HTMLPreviewCommenting(
          marks: marks, activeID: marks.first?.id, received: { received.messages.append($0) }))
      let screen = OffscreenWindow(preview, width: 600, height: 400)
      let webView = try #require(screen.allViews.compactMap { $0 as? WKWebView }.first)
      for _ in 0..<5 where !received.messages.contains(.ready) {
        _ = await screen.waitUntil(timeout: .seconds(5)) { received.messages.contains(.ready) }
      }
      try #require(received.messages.contains(.ready), "the comment script started")
      return (screen, webView)
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
      try await webView.callAsyncJavaScript(
        script, arguments: [:], in: nil, contentWorld: HTMLCommentBridge.world)
    }

    @Test("selecting the second copy of a phrase reports its text and copy")
    func selection() async throws {
      let received = Received()
      let (screen, webView) = try await shown(received)
      defer { screen.close() }
      _ = try await evaluate(
        """
        const text = document.getElementById("b").firstChild;
        const range = document.createRange();
        range.setStart(text, 0);
        range.setEnd(text, 11);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        """, in: webView)
      let expected = HTMLBridgeMessage.selection(HTMLSelection(text: "Aurora Sync", occurrence: 2))
      for _ in 0..<5 where !received.messages.contains(expected) {
        _ = await screen.waitUntil(timeout: .seconds(5)) { received.messages.contains(expected) }
      }
      #expect(received.messages.contains(expected), "\(received.messages)")
    }

    @Test("the comments the app sends are highlighted, the selected one apart")
    func highlights() async throws {
      let received = Received()
      let marks = [
        HTMLCommentMark(id: "c1", anchor: "Aurora Sync", occurrence: 1),
        HTMLCommentMark(id: "c2", anchor: "again", occurrence: nil),
      ]
      let (screen, webView) = try await shown(received, marks: marks)
      defer { screen.close() }
      // The app sent the comments on the script's ready, so they were set before this runs.
      let counted = try await evaluate(
        """
        return [CSS.highlights.get("omni-comment")?.size ?? 0,
                CSS.highlights.get("omni-comment-active")?.size ?? 0];
        """, in: webView)
      let sizes = counted as? [Int]
      #expect(sizes == [1, 1], "one plain and one selected highlight")
      let activeText = try await evaluate(
        """
        const [range] = CSS.highlights.get("omni-comment-active");
        return range.toString().replace(/\\s+/g, " ");
        """, in: webView)
      #expect(activeText as? String == "Aurora Sync")
    }
  }
#endif
