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

    /// Mirrors web-layer downloads into the engine-neutral records the tabs handed out.
    private var downloads: [UInt32: BrowserDownload] = [:]

    private init(session: Session) {
      self.session = session
      session.downloads.onChange = { [weak self] download in self?.downloadChanged(download) }
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

    /// An engine over a session the caller already started, so the app and its browser tabs
    /// share one web host.
    public static func attach(to session: Session) -> Self {
      session.start()
      return Self(session: session)
    }

    /// See `BrowserEngine.makeTab(profile:initialURL:)`.
    public func makeTab(profile: BrowserProfile, initialURL: URL?) -> any BrowserTab {
      let webProfile = session.profile(
        identifier: profile.identifier,
        persistence: profile.persistence == .persistent ? .persistent : .ephemeral)
      return ChromiumBrowserTab(
        profile: profile, webView: webProfile.makeWebView(initialURL: initialURL), engine: self)
    }

    func track(_ download: BrowserDownload, as webDownload: WebDownload) {
      downloads[webDownload.id] = download
      downloadChanged(webDownload)
    }

    private func downloadChanged(_ webDownload: WebDownload) {
      guard let download = downloads[webDownload.id] else { return }
      download.receivedBytes = webDownload.receivedBytes
      download.totalBytes = webDownload.totalBytes
      switch webDownload.state {
      case .inProgress: download.state = .inProgress
      case .paused: download.state = .paused
      case .complete: download.state = .complete
      case .cancelled: download.state = .cancelled
      case .interrupted: download.state = .failed("Chromium interrupted the download.")
      }
      if webDownload.state.isFinal {
        downloads[webDownload.id] = nil
      }
    }
  }

#endif
