import SwiftUI
import WebKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The comments an HTML preview shows, and where it reports what the reader does with its text.
struct HTMLPreviewCommenting {
  /// The highlights.
  var marks: [HTMLCommentMark]
  /// The comment the panel shows, highlighted more strongly and scrolled to.
  var activeID: String?
  /// Told the reader's selections, clicks on highlights and zoom shortcuts.
  var received: (HTMLBridgeMessage) -> Void
}

/// HTML and SVG rendered by WebKit: stateless (a non-persistent store), the page's scripts off,
/// and links opening in the default browser rather than in the preview. With comments, the
/// app's comment script runs in its own content world.
struct HTMLPreview {
  let html: String
  /// The page zoom: 1 is 100%.
  var zoom = 1.0
  /// The latest find; a new id runs it.
  var find = HTMLFindRequest()
  /// Told whether the find matched.
  var found: (Bool) -> Void = { _ in }
  /// Comments on the page; `nil` leaves it without the comment script.
  var commenting: HTMLPreviewCommenting?

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
    private var loaded: String?
    private var lastFind = 0
    private var commenting: HTMLPreviewCommenting?
    /// The page's comment script is running and has the comments.
    private var bridgeReady = false
    private var pushed: (marks: [HTMLCommentMark], activeID: String?)?
    private weak var webView: WKWebView?

    /// Applies the zoom, runs a find not yet run and shows changed comments.
    func update(_ preview: HTMLPreview, in webView: WKWebView) {
      self.webView = webView
      commenting = preview.commenting
      load(preview.html, into: webView)
      if webView.pageZoom != preview.zoom { webView.pageZoom = preview.zoom }
      pushComments()
      guard preview.find.id != lastFind else { return }
      lastFind = preview.find.id
      let configuration = WKFindConfiguration()
      configuration.backwards = preview.find.backwards
      configuration.caseSensitive = false
      configuration.wraps = true
      let found = preview.found
      webView.find(preview.find.query, configuration: configuration) { result in
        found(result.matchFound)
      }
    }

    /// Loads `html` unless it is already showing.
    func load(_ html: String, into webView: WKWebView) {
      guard loaded != html else { return }
      loaded = html
      // The new page's script says when it is ready for the comments.
      bridgeReady = false
      pushed = nil
      webView.loadHTMLString(html, baseURL: nil)
    }

    /// Relays a message from the page's comment script.
    func received(_ message: HTMLBridgeMessage) {
      if message == .ready {
        bridgeReady = true
        pushed = nil
        pushComments()
      }
      commenting?.received(message)
    }

    private func pushComments() {
      guard bridgeReady, let commenting, let webView else { return }
      guard pushed?.marks != commenting.marks || pushed?.activeID != commenting.activeID else {
        return
      }
      pushed = (commenting.marks, commenting.activeID)
      let active = commenting.activeID.flatMap { id in commenting.marks.first { $0.id == id } }
      HTMLCommentBridge.push(commenting.marks, active: active, to: webView)
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard navigationAction.navigationType == .linkActivated,
        let url = navigationAction.request.url
      else { return .allow }
      #if os(macOS)
        NSWorkspace.shared.open(url)
      #else
        await UIApplication.shared.open(url)
      #endif
      return .cancel
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // The page's own scripts stay off; the comment script is the app's and runs regardless.
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    if commenting != nil {
      let bridge = HTMLCommentBridge()
      bridge.received = { [weak coordinator] message in coordinator?.received(message) }
      bridge.install(in: configuration.userContentController)
    }
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    coordinator.update(self, in: webView)
    return webView
  }
}

#if os(macOS)
  extension HTMLPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) {
      context.coordinator.update(self, in: webView)
    }
  }
#else
  extension HTMLPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) {
      context.coordinator.update(self, in: webView)
    }
  }
#endif
