public import Foundation
internal import WebKit

#if os(macOS)
  internal import AppKit
#else
  internal import UIKit
#endif

/// The OS-provided web engine, currently WKWebView. Persistent profiles map to
/// `WKWebsiteDataStore(forIdentifier:)`, so each server gets its own cookies and storage.
public final class SystemBrowserEngine: BrowserEngine {
  /// Always `.system`.
  public let kind = BrowserEngineKind.system
  private var ephemeralStores: [String: WKWebsiteDataStore] = [:]

  /// Creates the engine. WebKit needs no global start-up.
  public init() {}

  /// See `BrowserEngine.makeTab(profile:initialURL:)`.
  public func makeTab(profile: BrowserProfile, initialURL: URL?) throws(BrowserError)
    -> any BrowserTab
  {
    let tab = SystemBrowserTab(profile: profile, dataStore: dataStore(for: profile))
    if let initialURL {
      tab.load(initialURL)
    }
    return tab
  }

  private func dataStore(for profile: BrowserProfile) -> WKWebsiteDataStore {
    switch profile.persistence {
    case .persistent:
      return WKWebsiteDataStore(forIdentifier: profile.dataStoreIdentifier)
    case .ephemeral:
      if let store = ephemeralStores[profile.identifier] {
        return store
      }
      let store = WKWebsiteDataStore.nonPersistent()
      ephemeralStores[profile.identifier] = store
      return store
    }
  }
}

final class SystemBrowserTab: NSObject, BrowserTab {
  let engineKind = BrowserEngineKind.system
  let profile: BrowserProfile
  let state = BrowserTabState()
  let webView: WKWebView
  private var observations: [NSKeyValueObservation] = []
  weak var delegate: (any BrowserTabDelegate)?
  /// Hosts whose certificate error the user chose to proceed past, for this tab's session.
  var certificateExceptions: Set<String> = []
  /// Downloads in flight, retained until they finish.
  var downloadTrackers: [ObjectIdentifier: SystemDownloadTracker] = [:]
  private(set) lazy var agentInput: any BrowserAgentInput = SystemAgentInput(tab: self)

  var popupPolicy = BrowserPopupPolicy.requireUserGesture {
    didSet { applyPopupPolicy() }
  }

  /// Checked for every navigation in `decidePolicyFor navigationAction`, redirects included.
  var urlPolicy: (any BrowserURLPolicy)?

  var platformView: BrowserPlatformView { webView }

  convenience init(profile: BrowserProfile, dataStore: WKWebsiteDataStore) {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    #if os(iOS)
      configuration.allowsInlineMediaPlayback = true
    #endif
    self.init(profile: profile, configuration: configuration)
  }

  /// `configuration` must be the one WebKit passes for a popup, so the opener link holds.
  init(profile: BrowserProfile, configuration: WKWebViewConfiguration) {
    self.profile = profile
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    applyPopupPolicy()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.isInspectable = true
    #if os(iOS)
      webView.isFindInteractionEnabled = true
    #endif
    observeWebView()
  }

  private func observeWebView() {
    observations = [
      webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.syncState() }
      },
      webView.observe(\.title, options: [.new]) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.syncState() }
      },
      webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.syncState() }
      },
      webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.syncState() }
      },
      webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.syncState() }
      },
      webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.syncState() }
      },
    ]
  }

  private func syncState() {
    state.url = webView.url
    state.title = webView.title ?? ""
    state.isLoading = webView.isLoading
    state.estimatedProgress = webView.estimatedProgress
    state.canGoBack = webView.canGoBack
    state.canGoForward = webView.canGoForward
  }

  func load(_ url: URL) {
    guard !state.isClosed else { return }
    if let urlPolicy, case .deny(let reason) = urlPolicy.evaluate(url) {
      state.lastError = .navigationBlocked(url: url, reason: reason)
      return
    }
    state.lastError = nil
    if url.isFileURL {
      webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    } else {
      webView.load(URLRequest(url: url))
    }
  }

  func goBack() {
    guard !state.isClosed else { return }
    webView.goBack()
  }

  func goForward() {
    guard !state.isClosed else { return }
    webView.goForward()
  }

  func reload() {
    guard !state.isClosed else { return }
    webView.reload()
  }

  func stopLoading() {
    guard !state.isClosed else { return }
    webView.stopLoading()
  }

  func evaluateJavaScript(_ script: String) async throws(BrowserError) -> BrowserScriptValue {
    guard !state.isClosed else { throw .tabClosed }
    typealias Outcome = Result<BrowserScriptValue, BrowserError>
    let result: Outcome = await withCheckedContinuation { continuation in
      webView.evaluateJavaScript(script) { value, error in
        if let error {
          continuation.resume(returning: .failure(Self.scriptError(error)))
          return
        }
        do throws(BrowserError) {
          continuation.resume(returning: .success(try BrowserScriptValue(foundationObject: value)))
        } catch {
          continuation.resume(returning: .failure(error))
        }
      }
    }
    return try result.get()
  }

  private static func scriptError(_ error: any Error) -> BrowserError {
    let nsError = error as NSError
    if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
      return .scriptFailed(message: message)
    }
    return .scriptFailed(message: nsError.localizedDescription)
  }

  func takeSnapshotPNG() async throws(BrowserError) -> Data {
    guard !state.isClosed else { throw .tabClosed }
    let image: BrowserPlatformImage
    do {
      image = try await webView.takeSnapshot(configuration: nil)
    } catch {
      throw .snapshotFailed(error.localizedDescription)
    }
    guard let data = image.browserPNGData() else {
      throw .snapshotFailed("PNG encoding failed.")
    }
    return data
  }

  func find(_ text: String, forward: Bool, caseSensitive: Bool) async throws(BrowserError)
    -> BrowserFindResult
  {
    guard !state.isClosed else { throw .tabClosed }
    let configuration = WKFindConfiguration()
    configuration.backwards = !forward
    configuration.caseSensitive = caseSensitive
    configuration.wraps = true
    let result: WKFindResult
    do {
      result = try await webView.find(text, configuration: configuration)
    } catch {
      throw .findFailed(error.localizedDescription)
    }
    return BrowserFindResult(matchFound: result.matchFound, matchCount: nil, activeMatch: nil)
  }

  func showDevTools() throws(BrowserError) {
    throw .featureUnsupported(
      feature: "opening DevTools from the app (use Safari's Develop menu; the view is inspectable)",
      engine: .system)
  }

  func close() {
    guard !state.isClosed else { return }
    state.isClosed = true
    withdrawPrompts(reason: "The tab was closed.")
    observations.removeAll()
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()
  }

  func report(_ error: any Error, url: URL?) {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      state.lastError = .navigationCancelled(url: url)
      return
    }
    if nsError.domain == WKErrorDomain, nsError.code == Self.frameLoadInterruptedByPolicyChange {
      return  // The tab cancelled it on purpose (download or policy) and reported why.
    }
    state.lastError = .navigationFailed(
      url: url, code: nsError.code, message: nsError.localizedDescription)
  }

  /// WebKitErrorFrameLoadInterruptedByPolicyChange: a navigation the tab turned into a download
  /// or blocked by policy.
  static let frameLoadInterruptedByPolicyChange = 102

  private func applyPopupPolicy() {
    // WebKit's own blocker handles opens without a user gesture; such blocks are not reported
    // because WebKit exposes no callback for them.
    webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = popupPolicy == .allow
  }
}

#if os(macOS)
  typealias BrowserPlatformImage = NSImage

  extension NSImage {
    fileprivate func browserPNGData() -> Data? {
      guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
      }
      return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
  }
#else
  typealias BrowserPlatformImage = UIImage

  extension UIImage {
    fileprivate func browserPNGData() -> Data? {
      pngData()
    }
  }
#endif
