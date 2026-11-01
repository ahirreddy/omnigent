// Chromium engine. A separate product from `OmnigentBrowser` so builds that must not contain
// Chromium (the Mac App Store edition, iOS) never link it. Chromium itself runs out of process in
// `Omnigent Web Host.app`; this file adapts the OmnigentWebLayer client to `BrowserEngine`.
// Register it with `DefaultBrowserEngineProvider.withChromium()`.

#if os(macOS)
  public import Foundation
  public import OmnigentBrowser
  public import OmnigentWebLayer

  /// Starts Chromium for `DefaultBrowserEngineProvider`.
  public final class ChromiumEngineFactory: BrowserEngineFactory {
    /// Always `.chromium`.
    public let kind = BrowserEngineKind.chromium
    private let configuration: ChromiumConfiguration

    /// Creates a factory.
    /// - Parameter configuration: Chromium start-up settings.
    public init(configuration: ChromiumConfiguration = .standard()) {
      self.configuration = configuration
    }

    /// See `BrowserEngineFactory.availability()`.
    public func availability() -> BrowserEngineAvailability {
      ChromiumBrowserEngine.availability(configuration: configuration)
    }

    /// See `BrowserEngineFactory.start()`.
    public func start() throws(BrowserError) -> any BrowserEngine {
      try ChromiumBrowserEngine.start(configuration: configuration)
    }
  }

  extension DefaultBrowserEngineProvider {
    /// A provider offering Chromium and the system engine.
    /// - Parameter configuration: Chromium start-up settings.
    /// - Returns: The provider.
    public static func withChromium(configuration: ChromiumConfiguration = .standard())
      -> DefaultBrowserEngineProvider
    {
      DefaultBrowserEngineProvider(
        additionalEngines: [ChromiumEngineFactory(configuration: configuration)])
    }
  }

  /// Start-up settings for the Chromium engine.
  nonisolated public struct ChromiumConfiguration: Hashable, Sendable {
    /// The web host session settings.
    public var session: SessionConfiguration

    /// Creates a configuration.
    public init(session: SessionConfiguration) {
      self.session = session
    }

    /// Defaults derived from `bundle`; see `SessionConfiguration.standard(bundle:)`.
    public static func standard(bundle: Bundle = .main) -> Self {
      Self(session: .standard(bundle: bundle))
    }
  }

  /// Chromium in the out-of-process web host. One engine owns one host `Session`; the host boots
  /// asynchronously, so tabs show progress until it is ready, and a host crash or hang leaves
  /// the app running with a recoverable error.
  public final class ChromiumBrowserEngine: BrowserEngine {
    /// Always `.chromium`.
    public let kind = BrowserEngineKind.chromium
    /// The host session behind every tab.
    public let session: Session

    private init(session: Session) {
      self.session = session
    }

    /// The CEF version of the running host, once it is ready.
    public var hostVersion: String? { session.hostInfo?.cefVersion }

    /// Checks the app bundle without launching anything.
    public static func availability(configuration: ChromiumConfiguration)
      -> BrowserEngineAvailability
    {
      let host = configuration.session.hostAppURL
      let executable = host.appending(
        path: "Contents/MacOS/\(SessionConfiguration.hostAppName)", directoryHint: .notDirectory)
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        return .unavailable(
          .engineNotBundled(
            .chromium, reason: "\(host.lastPathComponent) is not in the app bundle."))
      }
      // The host inherits the app's sandbox, and stock CEF's helper sandbox cannot nest in it.
      if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
        !configuration.session.disableSandbox
      {
        return .unavailable(
          .engineFailedToStart(
            .chromium,
            reason: "The app runs inside App Sandbox, which stock CEF builds do not support."))
      }
      return .available
    }

    /// Starts the host and returns immediately; tabs created now appear once it is ready.
    /// - Throws: `.engineNotBundled` or `.engineFailedToStart` when the host cannot be used.
    public static func start(configuration: ChromiumConfiguration) throws(BrowserError) -> Self {
      if case .unavailable(let error) = availability(configuration: configuration) {
        throw error
      }
      let session = Session(configuration: configuration.session)
      session.start()
      return Self(session: session)
    }

    /// See `BrowserEngine.makeTab(profile:initialURL:)`.
    public func makeTab(profile: BrowserProfile, initialURL: URL?) throws(BrowserError)
      -> any BrowserTab
    {
      let webProfile = session.profile(
        identifier: profile.identifier,
        persistence: profile.persistence == .persistent ? .persistent : .ephemeral)
      return ChromiumBrowserTab(
        profile: profile, webView: webProfile.makeWebView(initialURL: initialURL))
    }
  }

  /// A `BrowserTab` over one `WebView`.
  final class ChromiumBrowserTab: BrowserTab {
    let engineKind = BrowserEngineKind.chromium
    let profile: BrowserProfile
    let state = BrowserTabState()
    let webView: WebView
    let platformView: BrowserPlatformView

    init(profile: BrowserProfile, webView: WebView) {
      self.profile = profile
      self.webView = webView
      platformView = WebLayerView(webView: webView)
      webView.onStateChange = { [weak self] in self?.syncState() }
      syncState()
    }

    func load(_ url: URL) { webView.load(url) }
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

    private func syncState() {
      state.url = webView.url
      state.title = webView.title
      state.isLoading = webView.isLoading
      state.estimatedProgress = webView.estimatedProgress
      state.canGoBack = webView.canGoBack
      state.canGoForward = webView.canGoForward
      state.lastError = webView.lastError.map(Self.convert)
      state.isClosed = webView.status == .closed
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
      engineError(error) ?? pageError(error)
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
