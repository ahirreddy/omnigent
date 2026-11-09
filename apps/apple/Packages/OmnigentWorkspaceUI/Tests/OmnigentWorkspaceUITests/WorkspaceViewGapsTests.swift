#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing
  import WebKit

  @testable import OmnigentWorkspaceUI

  /// A navigation as WebKit would ask about it, which nothing but WebKit can make otherwise.
  private final class NavigationStub: WKNavigationAction {
    private let stubbedType: WKNavigationType
    private let stubbedRequest: URLRequest

    init(type: WKNavigationType, url: URL) {
      stubbedType = type
      stubbedRequest = URLRequest(url: url)
      super.init()
    }

    override var navigationType: WKNavigationType { stubbedType }
    override var request: URLRequest { stubbedRequest }
  }

  /// The viewer's paths that need a sheet or a navigation decision.
  @MainActor
  @Suite("Workspace view gaps", .serialized)
  struct WorkspaceViewGapsTests {
    init() {
      SystemSideEffects.install()
      SystemSideEffects.reset()
      UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
      UserDefaults.standard.removeObject(forKey: "workspace.showsComments")
    }

    @Test("a link in an HTML preview opens in the browser, never in the preview")
    func previewLink() async throws {
      let coordinator = HTMLPreview(html: "").makeCoordinator()
      let url = try #require(URL(string: "https://example.com/page"))
      let policy = await coordinator.webView(
        WKWebView(), decidePolicyFor: NavigationStub(type: .linkActivated, url: url))
      #expect(policy == .cancel)
      #expect(SystemSideEffects.record.openedURLs == [url])
    }

    @Test("the preview's own load goes ahead without opening anything")
    func previewLoad() async throws {
      let coordinator = HTMLPreview(html: "").makeCoordinator()
      let url = try #require(URL(string: "about:blank"))
      let policy = await coordinator.webView(
        WKWebView(), decidePolicyFor: NavigationStub(type: .other, url: url))
      #expect(policy == .allow)
      #expect(SystemSideEffects.record.openedURLs.isEmpty)
    }

    @Test("Comment on a line opens the composer, and adding sends that line's span")
    func commentFromLineMenu() async throws {
      let spy = ReviewSpy()
      let text = "old pond\n"
      let file = WorkspaceFile(
        path: "poems/haiku.txt", byteCount: UInt64(text.utf8.count),
        preview: .text(TextPreview(text: text, lineCount: 1)))
      let screen = OffscreenWindow(
        FileViewerView(
          file: file, source: SampleWorkspaceDataSource(), review: ReviewFixtures.context(spy: spy)),
        width: 900, height: 400)
      defer { screen.close() }
      let lineMenu = try stride(from: 10, to: 400, by: 6).lazy
        .compactMap { try screen.contextMenuUnder(CGPoint(x: 50, y: $0)) }
        .first { $0.items.contains { $0.title == "Comment" } }
      try screen.choose("Comment", in: try #require(lineMenu))
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("Comment on line 1"))
      let field = try #require(
        screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
      try screen.click(field)
      try screen.type("Lovely")
      await flush(screen)
      let add = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: add.midX, y: add.midY))
      #expect(await settle(screen) { spy.added.count == 1 })
      #expect(spy.added.map(\.0) == ["Lovely"])
      #expect(spy.added.first?.1.firstLine == 1)
      #expect(spy.added.first?.1.path == "poems/haiku.txt")
    }
  }
#endif
