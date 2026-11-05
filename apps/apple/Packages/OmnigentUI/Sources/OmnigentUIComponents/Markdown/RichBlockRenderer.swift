import CoreGraphics
import Foundation
import WebKit

/// What ``RichBlockRenderer`` draws.
nonisolated enum RichBlockKind: Hashable, Sendable {
  /// TeX typeset by KaTeX in black on clear, so the view can tint it; `size` is the font size.
  case math(display: Bool, size: Double)
  /// A Mermaid diagram in the light or dark Mermaid theme, as the web picks it.
  case mermaid(dark: Bool)
}

/// One block to draw.
nonisolated struct RichBlockRequest: Hashable, Sendable {
  var kind: RichBlockKind
  var source: String
}

/// A drawn block: its snapshot and size in points, and its baseline from the top (inline math).
nonisolated struct RenderedRichBlock: Sendable {
  let image: CGImage
  let scale: CGFloat
  let size: CGSize
  let baseline: CGFloat
}

/// Why a block could not be drawn.
nonisolated enum RichBlockError: LocalizedError, Equatable {
  /// The bundled page or a library is missing from the app.
  case unavailable(String)
  /// KaTeX or Mermaid rejected the source; the library's message.
  case invalidSource(String)
  /// The page answered with something other than a size.
  case malformedResult
  /// The page did not load.
  case loadFailed(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let what): "The \(what) renderer is not part of this build."
    case .invalidSource(let message): message
    case .malformedResult: "The renderer returned an unexpected result."
    case .loadFailed(let reason): "The renderer page did not load: \(reason)"
    }
  }
}

/// Typesets math (KaTeX) and draws Mermaid diagrams in one offscreen WebKit view, and hands
/// back snapshots the transcript shows as native images. KaTeX and Mermaid are package
/// resources (never a CDN), the view has a non-persistent data store and never navigates, and
/// requests run one at a time, deduplicated and cached, so scrolling redraws nothing.
@MainActor
final class RichBlockRenderer: NSObject {
  static let shared = RichBlockRenderer()

  /// Layout width of the page; wider diagrams are drawn at this width.
  private static let pageWidth: CGFloat = 4096
  /// Tallest block drawn.
  private static let maxHeight: CGFloat = 8192

  private var page: Task<WKWebView, any Error>?
  private var pageLoad: CheckedContinuation<Void, any Error>?
  private var mermaidLoad: Task<Void, any Error>?
  private var queue: Task<Void, Never>?
  private var inFlight: [RichBlockRequest: Task<RenderedRichBlock, any Error>] = [:]
  private var cache = BoundedCache<RichBlockRequest, RenderedRichBlock>(limit: 160)

  /// The drawn block, when it is already cached.
  func cached(_ request: RichBlockRequest) -> RenderedRichBlock? {
    cache.cached(request)
  }

  /// Draws `request`, waiting behind earlier requests.
  func render(_ request: RichBlockRequest) async throws -> RenderedRichBlock {
    if let hit = cache.cached(request) { return hit }
    if let running = inFlight[request] { return try await running.value }
    let previous = queue
    let task = Task { @MainActor in
      // The previous request's outcome belongs to its own caller; this one only waits its turn.
      _ = await previous?.value
      return try await self.draw(request)
    }
    queue = Task { _ = await task.result }
    inFlight[request] = task
    defer { inFlight[request] = nil }
    let rendered = try await task.value
    return cache.value(for: request) { rendered }
  }

  private func draw(_ request: RichBlockRequest) async throws -> RenderedRichBlock {
    let view = try await loadedPage()
    view.frame = CGRect(x: 0, y: 0, width: Self.pageWidth, height: 1024)
    let result: Any?
    switch request.kind {
    case .math(let display, let size):
      result = try await view.callAsyncJavaScript(
        "return await omnigentRender.math(source, display, size)",
        arguments: ["source": request.source, "display": display, "size": size],
        contentWorld: .page)
    case .mermaid(let dark):
      try await loadMermaid(into: view)
      result = try await view.callAsyncJavaScript(
        "return await omnigentRender.mermaid(source, dark)",
        arguments: ["source": request.source, "dark": dark], contentWorld: .page)
    }
    guard let fields = result as? [String: Any] else { throw RichBlockError.malformedResult }
    if let message = fields["error"] as? String { throw RichBlockError.invalidSource(message) }
    guard let width = fields["width"] as? Double, let height = fields["height"] as? Double,
      width > 0, height > 0
    else { throw RichBlockError.malformedResult }
    let size = CGSize(width: min(width, Self.pageWidth), height: min(height, Self.maxHeight))
    view.frame = CGRect(x: 0, y: 0, width: Self.pageWidth, height: max(size.height, 1024))
    let configuration = WKSnapshotConfiguration()
    configuration.rect = CGRect(origin: .zero, size: size)
    let snapshot = try await view.takeSnapshot(configuration: configuration)
    guard let (image, scale) = Self.cgImage(snapshot, points: size) else {
      throw RichBlockError.malformedResult
    }
    let baseline = fields["baseline"] as? Double ?? size.height
    return RenderedRichBlock(image: image, scale: scale, size: size, baseline: baseline)
  }

  private func loadedPage() async throws -> WKWebView {
    if let page { return try await page.value }
    let task = Task { @MainActor in try await self.makePage() }
    page = task
    do {
      return try await task.value
    } catch {
      page = nil
      throw error
    }
  }

  private func makePage() async throws -> WKWebView {
    guard
      let url = Bundle.module.url(
        forResource: "render", withExtension: "html", subdirectory: "RichRender")
    else { throw RichBlockError.unavailable("math and diagram") }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    let view = WKWebView(
      frame: CGRect(x: 0, y: 0, width: Self.pageWidth, height: 1024), configuration: configuration)
    Self.makeTransparent(view)
    view.navigationDelegate = self
    try await withCheckedThrowingContinuation { continuation in
      pageLoad = continuation
      view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    return view
  }

  /// Evaluates the bundled Mermaid once per page; most transcripts never need it.
  private func loadMermaid(into view: WKWebView) async throws {
    if let mermaidLoad {
      try await mermaidLoad.value
      return
    }
    let task = Task { @MainActor in
      guard
        let url = Bundle.module.url(
          forResource: "mermaid.min.js", withExtension: "lzma", subdirectory: "RichRender")
      else { throw RichBlockError.unavailable("diagram") }
      let source = try await Task.detached(priority: .userInitiated) {
        let packed = try Data(contentsOf: url)
        // Foundation's LZMA decoder exists only on NSData.
        // swiftlint:disable:next legacy_objc_type
        let script = try (packed as NSData).decompressed(using: .lzma) as Data
        guard let source = String(bytes: script, encoding: .utf8) else {
          throw RichBlockError.unavailable("diagram")
        }
        return source
      }.value
      _ = try await view.evaluateJavaScript(source + "\n;true")
    }
    mermaidLoad = task
    do {
      try await task.value
    } catch {
      mermaidLoad = nil
      throw error
    }
  }

  /// Drops the page so the next request loads a fresh one.
  private func reset() {
    page = nil
    mermaidLoad = nil
  }

  private static func makeTransparent(_ view: WKWebView) {
    #if os(macOS)
      // WKWebView has no public transparency switch on macOS; without it snapshots are opaque.
      // Key-value coding reaches its `_setDrawsBackground:`; check first so a removal can't raise.
      if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
        view.setValue(false, forKey: "drawsBackground")
      }
    #else
      view.isOpaque = false
      view.backgroundColor = .clear
      view.scrollView.backgroundColor = .clear
    #endif
  }

  #if os(macOS)
    private static func cgImage(_ snapshot: NSImage, points: CGSize) -> (CGImage, CGFloat)? {
      // A nil proposed rect is the whole image; no pointer is dereferenced.
      guard let image = unsafe snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else {
        return nil
      }
      return (image, CGFloat(image.width) / max(points.width, 1))
    }
  #else
    private static func cgImage(_ snapshot: UIImage, points: CGSize) -> (CGImage, CGFloat)? {
      guard let image = snapshot.cgImage else { return nil }
      return (image, CGFloat(image.width) / max(points.width, 1))
    }
  #endif
}

extension RichBlockRenderer: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    // Only the bundled page itself loads; links in diagrams never navigate.
    decisionHandler(
      navigationAction.request.url?.isFileURL == true && pageLoad != nil ? .allow : .cancel)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
    pageLoad?.resume()
    pageLoad = nil
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error
  ) {
    failLoad(error)
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?,
    withError error: any Error
  ) {
    failLoad(error)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    failLoad(RichBlockError.loadFailed("the web content process ended"))
    reset()
  }

  private func failLoad(_ error: any Error) {
    pageLoad?.resume(throwing: RichBlockError.loadFailed(error.localizedDescription))
    pageLoad = nil
  }
}
