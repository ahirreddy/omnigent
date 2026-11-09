#if os(macOS)
  internal import AppKit
  internal import Foundation
  internal import OmnigentBrowser
  internal import OmnigentWebLayer

  /// A `BrowserTab` over one `WebView`. Prompts, popups and downloads from the web layer are
  /// mapped to the engine-neutral types in `ChromiumBrowserTab+Prompts.swift`.
  final class ChromiumBrowserTab: BrowserTab {
    let engineKind = BrowserEngineKind.chromium
    let profile: BrowserProfile
    let state = BrowserTabState()
    let webView: WebView
    let platformView: BrowserPlatformView
    weak var delegate: (any BrowserTabDelegate)?
    private(set) weak var engine: ChromiumBrowserEngine?
    /// Web-layer prompt ID to the engine-neutral prompt handed to the delegate.
    var prompts: [UInt64: BrowserPrompt] = [:]
    /// The web view's error that `state.lastError` last took.
    private var syncedWebViewError: WebLayerError?
    private(set) lazy var agentInput: any BrowserAgentInput = ChromiumAgentInput(webView: webView)

    var popupPolicy = BrowserPopupPolicy.requireUserGesture {
      didSet { webView.popupPolicy = Self.webPolicy(popupPolicy) }
    }

    var urlPolicy: (any BrowserURLPolicy)? {
      didSet { webView.navigationRules = urlPolicy.map { Self.webRules($0.rules) } }
    }

    init(profile: BrowserProfile, webView: WebView, engine: ChromiumBrowserEngine?) {
      self.profile = profile
      self.webView = webView
      self.engine = engine
      platformView = WebLayerView(webView: webView)
      webView.uiDelegate = self
      webView.onStateChange = { [weak self] in self?.syncState() }
      syncState()
    }

    func load(_ url: URL) {
      if let urlPolicy, case .deny(let reason) = urlPolicy.evaluate(url) {
        state.report(.navigationBlocked(url: url, reason: reason))
        return
      }
      webView.load(url)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stopLoading() { webView.stopLoading() }

    func evaluateJavaScript(_ script: String) async throws(BrowserError) -> BrowserScriptValue {
      do {
        return Self.convert(try await webView.evaluateJavaScript(script))
      } catch {
        throw Self.convert(error)
      }
    }

    func takeSnapshotPNG() async throws(BrowserError) -> Data {
      do {
        return try await webView.snapshotPNG()
      } catch {
        throw Self.convert(error)
      }
    }

    func find(_ text: String, forward: Bool, caseSensitive: Bool) async throws(BrowserError)
      -> BrowserFindResult
    {
      do {
        let result = try await webView.find(text, forward: forward, caseSensitive: caseSensitive)
        return BrowserFindResult(
          matchFound: result.matchFound, matchCount: result.matchCount,
          activeMatch: result.activeMatch)
      } catch {
        throw Self.convert(error)
      }
    }

    func showDevTools() throws(BrowserError) {
      do {
        try webView.showDevTools()
      } catch {
        throw Self.convert(error)
      }
    }

    func close() {
      webView.close()
      syncState()
    }

    func syncState() {
      state.url = webView.url
      state.title = webView.title
      state.isLoading = webView.isLoading
      state.estimatedProgress = webView.estimatedProgress
      state.canGoBack = webView.canGoBack
      state.canGoForward = webView.canGoForward
      // The tab reports errors of its own, so only a change in the web view's replaces them.
      if webView.lastError != syncedWebViewError {
        syncedWebViewError = webView.lastError
        state.lastError = webView.lastError.map(Self.convert)
      }
      state.isClosed = webView.status == .closed
      state.faviconURL = webView.faviconURLs.first
      state.isAudible = webView.isAudible
      state.isMuted = webView.isAudioMuted
      state.zoomFactor = pow(1.2, webView.zoomLevel)
    }

    static func webPolicy(_ policy: BrowserPopupPolicy) -> WebPopupPolicy {
      switch policy {
      case .allow: .allow
      case .requireUserGesture: .requireUserGesture
      case .block: .block
      }
    }

    static func webRules(_ rules: BrowserURLRules) -> WebNavigationRules {
      WebNavigationRules(
        schemes: rules.schemes, allow: rules.allow, deny: rules.deny,
        blockPrivateAddresses: rules.blockPrivateAddresses, allowLoopback: rules.allowLoopback)
    }

    static func convert(_ value: WebScriptValue) -> BrowserScriptValue {
      switch value {
      case .undefined: .undefined
      case .null: .null
      case .bool(let bool): .bool(bool)
      case .number(let number): .number(number)
      case .string(let string): .string(string)
      case .array(let array): .array(array.map(convert))
      case .object(let object): .object(object.mapValues(convert))
      }
    }

    static func convert(_ error: WebLayerError) -> BrowserError {
      engineError(error) ?? policyError(error) ?? pageError(error)
    }

    /// Blocks by the tab's policies and answers to finished prompts; nil for anything else.
    private static func policyError(_ error: WebLayerError) -> BrowserError? {
      switch error {
      case .navigationBlocked(let url, let reason): .navigationBlocked(url: url, reason: reason)
      case .popupBlocked(let url, let reason): .popupBlocked(url: url, reason: reason)
      case .promptFinished(let message): .notAllowed(message)
      default: nil
      }
    }

    /// Host and engine lifecycle failures; nil for page-level errors.
    private static func engineError(_ error: WebLayerError) -> BrowserError? {
      let reason = error.localizedDescription
      switch error {
      case .hostNotBundled:
        return .engineNotBundled(.chromium, reason: reason)
      case .launchFailed, .channelFailed, .handshakeFailed, .protocolMismatch,
        .hostInitializationFailed, .hostTimedOut, .renderingUnavailable:
        return .engineFailedToStart(.chromium, reason: reason)
      case .hostExited, .hostUnresponsive:
        return .engineStopped(.chromium, reason: reason)
      case .hostError, .invalidArgument:
        return .engineError(.chromium, message: reason)
      case .notReady:
        return .tabNotReady
      case .viewClosed:
        return .tabClosed
      default:
        return nil
      }
    }

    private static func pageError(_ error: WebLayerError) -> BrowserError {
      switch error {
      case .navigationFailed(let url, let code, let message):
        .navigationFailed(url: url, code: code, message: message)
      case .navigationCancelled(let url):
        .navigationCancelled(url: url)
      case .rendererTerminated(let message):
        .contentProcessTerminated(reason: message)
      case .scriptFailed(let message):
        .scriptFailed(message: message)
      case .unsupportedScriptResult(let type):
        .unsupportedScriptResult(type)
      case .devToolsFailed(let method, let message):
        .devToolsFailed(method: method, message: message)
      case .snapshotFailed(let message):
        .snapshotFailed(message)
      case .downloadBlocked(let url):
        .downloadsUnsupported(url: url)
      case .featureBlocked(let feature, let detail):
        .featureUnsupported(feature: "\(feature) (\(detail))", engine: .chromium)
      default:
        .engineError(.chromium, message: error.localizedDescription)
      }
    }
  }
#endif
