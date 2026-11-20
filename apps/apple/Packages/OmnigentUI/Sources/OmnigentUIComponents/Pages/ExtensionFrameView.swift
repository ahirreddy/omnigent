public import Foundation
import SwiftUI
import WebKit

/// The relay between an extension page's frame and its host: the host page reports the frame
/// loading and every message from the extension, and takes the host's messages back. Only the
/// host page's own main frame is heard; the extension's sandboxed frame never is.
@MainActor
public final class ExtensionFrameChannel {
  /// The frame loaded for the first time: the channel is open and waits for `init`.
  public var loaded: () -> Void = {}
  /// The frame loaded again, which a page may not do.
  public var reloaded: () -> Void = {}
  /// The page's web content stopped.
  public var stopped: () -> Void = {}
  /// A message from the extension, as JSON text.
  public var received: (String) -> Void = { _ in }
  weak var webView: WKWebView?

  /// Creates a channel.
  public init() {}

  /// Hands the extension `message` (`init`) with the channel's other port.
  /// - Parameter message: The `init` message as JSON text.
  /// - Returns: Whether the frame took it.
  public func start(_ message: String) async -> Bool {
    await call("return window.__omnigentHost.init(text) === true", text: message)
  }

  /// Sends `message` to the extension; messages arrive in the order sent.
  /// - Parameter message: The message as JSON text.
  public func send(_ message: String) {
    guard let webView, let literal = Self.literal(message) else { return }
    webView.evaluateJavaScript("window.__omnigentHost.post(\(literal))") { _, _ in
      // The page is going away or reloading; its own load handling reports that.
    }
  }

  /// Closes the extension's end of the channel.
  public func close() {
    webView?.evaluateJavaScript("window.__omnigentHost && window.__omnigentHost.close()") { _, _ in
      // Closing a page that already went away needs nothing more.
    }
  }

  private func call(_ body: String, text: String) async -> Bool {
    guard let webView else { return false }
    do {
      let value = try await webView.callAsyncJavaScript(
        body, arguments: ["text": text], in: nil, contentWorld: .page)
      return value as? Bool ?? false
    } catch {
      return false
    }
  }

  /// `text` as a JavaScript string literal.
  nonisolated static func literal(_ text: String) -> String? {
    guard let data = try? JSONEncoder().encode(text) else { return nil }
    return String(bytes: data, encoding: .utf8)
  }

  /// A message from the host page: `loaded`, `reloaded`, or a `message` with its text.
  func receive(_ body: Any) {
    guard let fields = body as? [String: Any], let kind = fields["kind"] as? String else {
      return
    }
    switch kind {
    case "loaded": loaded()
    case "reloaded": reloaded()
    case "message":
      if let text = fields["text"] as? String { received(text) }
    default: break
    }
  }
}

/// An extension page's web view: the host page framing the bundle, with no persistent data, no
/// pop-up windows and no navigation away from it.
struct ExtensionFrameView {
  static let handlerName = "omnigentExtension"

  let hostPage: String
  let title: String
  let channel: ExtensionFrameChannel

  func makeCoordinator() -> ExtensionFrameCoordinator {
    ExtensionFrameCoordinator(channel: channel)
  }

  private func makeWebView(_ coordinator: ExtensionFrameCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.userContentController.add(
      ExtensionMessageProxy(coordinator: coordinator), name: Self.handlerName)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = coordinator
    view.uiDelegate = coordinator
    #if os(macOS)
      view.setAccessibilityLabel(title)
    #else
      view.accessibilityLabel = title
      view.isOpaque = false
      view.backgroundColor = .clear
    #endif
    channel.webView = view
    view.loadHTMLString(hostPage, baseURL: nil)
    return view
  }

  fileprivate static func dismantle(_ view: WKWebView) {
    view.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
    view.navigationDelegate = nil
    view.uiDelegate = nil
    view.stopLoading()
  }
}

#if os(macOS)
  extension ExtensionFrameView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: ExtensionFrameCoordinator) {
      dismantle(view)
    }
  }
#else
  extension ExtensionFrameView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: ExtensionFrameCoordinator) {
      dismantle(view)
    }
  }
#endif

/// Keeps the page on its host page and its frame, and hears the host page's main frame only.
final class ExtensionFrameCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
  let channel: ExtensionFrameChannel

  init(channel: ExtensionFrameChannel) {
    self.channel = channel
  }

  func receive(_ message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame else { return }
    channel.receive(message.body)
  }

  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    // The host page is `about:blank` and its frame `about:srcdoc`; nothing else may load.
    decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
  }

  func webView(
    _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    nil
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    channel.stopped()
  }
}

/// Holds the coordinator weakly: the content controller keeps its handlers alive.
private final class ExtensionMessageProxy: NSObject, WKScriptMessageHandler {
  weak var coordinator: ExtensionFrameCoordinator?

  init(coordinator: ExtensionFrameCoordinator) {
    self.coordinator = coordinator
  }

  func userContentController(
    _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    coordinator?.receive(message)
  }
}
