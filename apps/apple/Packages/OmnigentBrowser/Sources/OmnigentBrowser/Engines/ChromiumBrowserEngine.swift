#if os(macOS)
  public import Foundation
  internal import AppKit
  internal import OmnigentCEFBridge
#else
  internal import Foundation
#endif

#if os(macOS)

  /// Start-up settings for the Chromium engine.
  nonisolated public struct ChromiumConfiguration: Hashable, Sendable {
    /// Base name of the helper bundles in `Contents/Frameworks` (for example "Omnigent Helper").
    public var helperName: String
    /// App-private directory holding every persistent Chromium profile.
    public var rootCacheURL: URL
    /// Chrome remote debugging port; 0 disables it.
    public var remoteDebuggingPort: Int
    /// Disables Chromium's helper-process sandbox. Only for diagnosing sandbox failures.
    public var disableSandbox: Bool
    /// Uses Chromium's mock keychain so unsigned rebuilds do not trigger Keychain prompts.
    public var useMockKeychain: Bool
    /// Keychain service for Chromium's cookie-encryption key.
    public var keychainServiceName: String?

    /// Creates a configuration.
    public init(
      helperName: String,
      rootCacheURL: URL,
      remoteDebuggingPort: Int = 0,
      disableSandbox: Bool = false,
      useMockKeychain: Bool = false,
      keychainServiceName: String? = nil
    ) {
      self.helperName = helperName
      self.rootCacheURL = rootCacheURL
      self.remoteDebuggingPort = remoteDebuggingPort
      self.disableSandbox = disableSandbox
      self.useMockKeychain = useMockKeychain
      self.keychainServiceName = keychainServiceName
    }

    /// Defaults derived from `bundle`: helper "<executable> Helper", profiles under
    /// `Application Support/<bundle id>/Chromium`, and a bundle-specific Keychain service.
    /// Debug builds use the mock keychain.
    public static func standard(bundle: Bundle = .main) -> Self {
      let executable = bundle.executableURL?.lastPathComponent ?? "Omnigent"
      let bundleID = bundle.bundleIdentifier ?? "ai.omnigent.browser"
      let support = URL.applicationSupportDirectory
        .appending(path: bundleID, directoryHint: .isDirectory)
        .appending(path: "Chromium", directoryHint: .isDirectory)
      #if DEBUG
        let mockKeychain = true
      #else
        let mockKeychain = false
      #endif
      return Self(
        helperName: "\(executable) Helper",
        rootCacheURL: support,
        useMockKeychain: mockKeychain,
        keychainServiceName: "\(bundleID) Browser Safe Storage")
    }

    @MainActor fileprivate var bridgeConfiguration: OMCEFConfiguration {
      let configuration = OMCEFConfiguration(helperName: helperName, rootCacheURL: rootCacheURL)
      configuration.remoteDebuggingPort = remoteDebuggingPort
      configuration.disableSandbox = disableSandbox
      configuration.useMockKeychain = useMockKeychain
      configuration.keychainServiceName = keychainServiceName
      return configuration
    }
  }

  /// Chromium via CEF. One instance per process; CEF cannot restart after shutdown.
  public final class ChromiumBrowserEngine: BrowserEngine {
    /// Always `.chromium`.
    public let kind = BrowserEngineKind.chromium

    private init() {}

    /// The CEF version compiled into this build, or nil when built without CEF.
    public static var compiledVersion: String? {
      OMCEFRuntime.isCompiledIn ? OMCEFRuntime.compiledVersion : nil
    }

    /// Checks the build and app bundle without loading CEF.
    public static func availability(configuration: ChromiumConfiguration)
      -> BrowserEngineAvailability
    {
      do {
        try OMCEFRuntime.validateBundle(with: configuration.bridgeConfiguration)
        if let reason = appSandboxConflict(configuration) {
          return .unavailable(.engineFailedToStart(.chromium, reason: reason))
        }
        return .available
      } catch {
        return .unavailable(.engineNotBundled(.chromium, reason: error.localizedDescription))
      }
    }

    /// Loads and initializes CEF. Must run on the main thread after `NSApp` exists.
    /// - Throws: `.engineNotBundled` or `.engineFailedToStart`.
    public static func start(configuration: ChromiumConfiguration) throws(BrowserError) -> Self {
      if case .unavailable(let error) = availability(configuration: configuration) {
        throw error
      }
      do {
        try OMCEFRuntime.start(with: configuration.bridgeConfiguration)
      } catch {
        throw .engineFailedToStart(.chromium, reason: error.localizedDescription)
      }
      return Self()
    }

    /// Closes all Chromium browsers and shuts CEF down. Also runs on app termination.
    public static func shutdown() {
      OMCEFRuntime.shutdown()
    }

    /// Stock CEF's helper sandbox cannot nest inside App Sandbox.
    private static func appSandboxConflict(_ configuration: ChromiumConfiguration) -> String? {
      guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
        !configuration.disableSandbox
      else {
        return nil
      }
      return "The app runs inside App Sandbox, which stock CEF builds do not support."
    }

    /// See `BrowserEngine.makeTab(profile:initialURL:)`.
    public func makeTab(profile: BrowserProfile, initialURL: URL?) throws(BrowserError)
      -> any BrowserTab
    {
      let view: OMCEFBrowserView
      do {
        view = try OMCEFBrowserView(
          profileKey: profile.storageKey,
          persistent: profile.persistence == .persistent,
          initialURL: initialURL?.absoluteString ?? "about:blank")
      } catch {
        throw .engineFailedToStart(.chromium, reason: error.localizedDescription)
      }
      return ChromiumBrowserTab(profile: profile, view: view, initialURL: initialURL)
    }
  }

  final class ChromiumBrowserTab: NSObject, BrowserTab {
    let engineKind = BrowserEngineKind.chromium
    let profile: BrowserProfile
    let state = BrowserTabState()
    private let view: OMCEFBrowserView
    private var pendingFind: CheckedContinuation<BrowserFindResult, Never>?

    var platformView: BrowserPlatformView { view }

    init(profile: BrowserProfile, view: OMCEFBrowserView, initialURL: URL?) {
      self.profile = profile
      self.view = view
      super.init()
      state.url = initialURL
      state.isLoading = initialURL != nil
      view.delegate = self
    }

    func load(_ url: URL) {
      guard !state.isClosed else { return }
      state.lastError = nil
      view.loadURL(url.absoluteString)
    }

    func goBack() {
      guard !state.isClosed else { return }
      view.goBack()
    }

    func goForward() {
      guard !state.isClosed else { return }
      view.goForward()
    }

    func reload() {
      guard !state.isClosed else { return }
      view.reload()
    }

    func stopLoading() {
      guard !state.isClosed else { return }
      view.stopLoading()
    }

    func evaluateJavaScript(_ script: String) async throws(BrowserError) -> BrowserScriptValue {
      let params: [String: Any] = [
        "expression": script,
        "returnByValue": true,
        "awaitPromise": false,
        "userGesture": true,
      ]
      let json = try await devTools("Runtime.evaluate", params: params)
      return try ChromiumDevTools.evaluateResult(json: json)
    }

    func takeSnapshotPNG() async throws(BrowserError) -> Data {
      let json = try await devTools("Page.captureScreenshot", params: ["format": "png"])
      return try ChromiumDevTools.screenshotData(json: json)
    }

    func find(_ text: String, forward: Bool, caseSensitive: Bool) async throws(BrowserError)
      -> BrowserFindResult
    {
      guard !state.isClosed else { throw .tabClosed }
      guard view.hasBrowser else { throw .tabNotReady }
      finishFind(BrowserFindResult(matchFound: false, matchCount: 0, activeMatch: nil))
      return await withCheckedContinuation { continuation in
        pendingFind = continuation
        view.findText(text, forward: forward, matchCase: caseSensitive)
      }
    }

    private func finishFind(_ result: BrowserFindResult) {
      pendingFind?.resume(returning: result)
      pendingFind = nil
    }

    func showDevTools() throws(BrowserError) {
      guard !state.isClosed else { throw .tabClosed }
      do {
        try view.showDevTools()
      } catch {
        throw .devToolsFailed(method: "ShowDevTools", message: error.localizedDescription)
      }
    }

    func close() {
      guard !state.isClosed else { return }
      state.isClosed = true
      finishFind(BrowserFindResult(matchFound: false, matchCount: 0, activeMatch: nil))
      view.close()
    }

    private func devTools(_ method: String, params: [String: Any]) async throws(BrowserError)
      -> String
    {
      guard !state.isClosed else { throw .tabClosed }
      let data: Data
      do {
        data = try JSONSerialization.data(withJSONObject: params)
      } catch {
        throw .devToolsFailed(method: method, message: error.localizedDescription)
      }
      guard let paramsJSON = String(bytes: data, encoding: .utf8) else {
        throw .devToolsFailed(method: method, message: "Parameters are not UTF-8.")
      }
      let result: Result<String, BrowserError> = await withCheckedContinuation { continuation in
        view.executeDevToolsMethod(method, paramsJSON: paramsJSON) { json, error in
          if let json {
            continuation.resume(returning: .success(json))
          } else {
            continuation.resume(returning: .failure(Self.bridgeError(error, method: method)))
          }
        }
      }
      return try result.get()
    }

    private static func bridgeError(_ error: (any Error)?, method: String) -> BrowserError {
      guard let nsError = error as NSError? else {
        return .devToolsFailed(method: method, message: "No result and no error from CEF.")
      }
      switch nsError.code {
      case OMCEFError.Code.browserNotReady.rawValue: return .tabNotReady
      case OMCEFError.Code.browserClosed.rawValue: return .tabClosed
      default: return .devToolsFailed(method: method, message: nsError.localizedDescription)
      }
    }
  }

  extension ChromiumBrowserTab: OMCEFBrowserViewDelegate {
    func browserViewDidCreateBrowser(_ view: OMCEFBrowserView) {}

    func browserView(_ view: OMCEFBrowserView, didChangeURL url: String) {
      state.url = URL(string: url)
    }

    func browserView(_ view: OMCEFBrowserView, didChangeTitle title: String) {
      state.title = title
    }

    func browserView(
      _ view: OMCEFBrowserView, didChangeLoading isLoading: Bool, canGoBack: Bool,
      canGoForward: Bool
    ) {
      if isLoading, !state.isLoading {
        state.lastError = nil
      }
      state.isLoading = isLoading
      state.canGoBack = canGoBack
      state.canGoForward = canGoForward
    }

    func browserView(_ view: OMCEFBrowserView, didChangeProgress progress: Double) {
      state.estimatedProgress = progress
    }

    func browserView(
      _ view: OMCEFBrowserView, didFailLoadWithErrorCode code: Int, text: String, url: String
    ) {
      let failedURL = URL(string: url)
      state.lastError =
        code == ChromiumDevTools.netErrorAborted
        ? .navigationCancelled(url: failedURL)
        : .navigationFailed(url: failedURL, code: code, message: text)
    }

    func browserView(
      _ view: OMCEFBrowserView, renderProcessTerminatedWithStatus status: Int, errorCode: Int,
      message: String
    ) {
      state.lastError = .contentProcessTerminated(
        reason: "Chromium renderer exited (status \(status), code \(errorCode)) \(message)")
    }

    func browserView(_ view: OMCEFBrowserView, didBlockDownloadOfURL url: String) {
      state.lastError = .downloadsUnsupported(url: URL(string: url))
    }

    func browserView(
      _ view: OMCEFBrowserView, didFindMatches count: Int, activeMatch: Int, finalUpdate: Bool
    ) {
      guard finalUpdate else { return }
      finishFind(
        BrowserFindResult(
          matchFound: count > 0, matchCount: count, activeMatch: count > 0 ? activeMatch : nil))
    }

    func browserViewDidClose(_ view: OMCEFBrowserView) {
      state.isClosed = true
      state.isLoading = false
    }
  }
#endif

/// Parsers for Chrome DevTools Protocol results. Engine-independent so they are unit-testable.
nonisolated enum ChromiumDevTools {
  /// net::ERR_ABORTED, reported when a navigation is stopped or superseded.
  static let netErrorAborted = -3

  static func evaluateResult(json: String) throws(BrowserError) -> BrowserScriptValue {
    let root = try object(json, method: "Runtime.evaluate")
    if let details = root["exceptionDetails"] as? [String: Any] {
      let exception = details["exception"] as? [String: Any]
      let message =
        exception?["description"] as? String ?? details["text"] as? String
        ?? "Uncaught exception"
      throw .scriptFailed(message: message)
    }
    guard let result = root["result"] as? [String: Any] else {
      throw .devToolsFailed(method: "Runtime.evaluate", message: "Missing result: \(json)")
    }
    if let unserializable = result["unserializableValue"] as? String {
      switch unserializable {
      case "NaN": return .number(.nan)
      case "Infinity": return .number(.infinity)
      case "-Infinity": return .number(-.infinity)
      case "-0": return .number(-0.0)
      default: return .string(unserializable)
      }
    }
    if result["type"] as? String == "undefined" {
      return .undefined
    }
    guard result.keys.contains("value") else {
      let type = result["className"] as? String ?? result["type"] as? String ?? "unknown"
      throw .unsupportedScriptResult(type)
    }
    return try BrowserScriptValue(foundationObject: result["value"])
  }

  static func screenshotData(json: String) throws(BrowserError) -> Data {
    let root = try object(json, method: "Page.captureScreenshot")
    guard let base64 = root["data"] as? String, let data = Data(base64Encoded: base64) else {
      throw .snapshotFailed("Page.captureScreenshot returned no image data.")
    }
    return data
  }

  private static func object(_ json: String, method: String) throws(BrowserError)
    -> [String: Any]
  {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
    } catch {
      throw .devToolsFailed(method: method, message: "Invalid JSON: \(error.localizedDescription)")
    }
    guard let object = parsed as? [String: Any] else {
      throw .devToolsFailed(method: method, message: "Expected a JSON object: \(json)")
    }
    return object
  }
}
