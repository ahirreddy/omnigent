public import Foundation
internal import OWLProtocol

/// How the host delivers pixels to the client. See DESIGN.md, "Rendering".
nonisolated public enum RenderMode: String, Sendable, Hashable, CaseIterable {
  /// The host draws into its own CAContext; the client embeds it with the private CALayerHost.
  case remoteLayer
  /// The host sends each frame's IOSurface over the channel; the client sets it as layer
  /// contents. Public API only.
  case ioSurface

  var wireValue: OWLRenderMode { self == .remoteLayer ? .remoteLayer : .ioSurface }

  init(wireValue: UInt64) {
    self = wireValue == OWLRenderMode.ioSurface.rawValue ? .ioSurface : .remoteLayer
  }
}

/// Start-up and supervision settings for the web host.
nonisolated public struct SessionConfiguration: Sendable, Hashable {
  /// Name of the host bundle and executable.
  public static let hostAppName = "Omnigent Web Host"

  /// The `Omnigent Web Host.app` bundle to launch.
  public var hostAppURL: URL
  /// App-private directory holding every persistent Chromium profile.
  public var rootCacheURL: URL
  /// Preferred rendering path. Falls back to `.ioSurface` when the private API is missing.
  public var renderMode: RenderMode
  /// Chrome remote debugging port; 0 disables it.
  public var remoteDebuggingPort: Int
  /// Uses Chromium's mock keychain so unsigned rebuilds do not trigger Keychain prompts.
  public var useMockKeychain: Bool
  /// Keychain service for Chromium's cookie-encryption key.
  public var keychainServiceName: String?
  /// UI locale for Chromium, for example "en-US".
  public var locale: String?
  /// Disables Chromium's helper-process sandbox. Only for diagnosing sandbox failures.
  public var disableSandbox: Bool
  /// Time allowed from spawn to the host's Hello.
  public var handshakeTimeout: Duration
  /// Time allowed from spawn to Chromium being ready.
  public var readyTimeout: Duration
  /// Interval between watchdog pings.
  public var pingInterval: Duration
  /// A ping unanswered for this long marks the host as hung; it is killed.
  public var hangTimeout: Duration
  /// Time the host gets to exit after a shutdown request before it is killed.
  public var shutdownGrace: Duration
  /// Time a request (evaluate, snapshot, DevTools call) may take before it fails.
  public var requestTimeout: Duration

  /// Creates a configuration.
  public init(
    hostAppURL: URL,
    rootCacheURL: URL,
    renderMode: RenderMode = .remoteLayer,
    remoteDebuggingPort: Int = 0,
    useMockKeychain: Bool = false,
    keychainServiceName: String? = nil,
    locale: String? = nil,
    disableSandbox: Bool = false
  ) {
    self.hostAppURL = hostAppURL
    self.rootCacheURL = rootCacheURL
    self.renderMode = renderMode
    self.remoteDebuggingPort = remoteDebuggingPort
    self.useMockKeychain = useMockKeychain
    self.keychainServiceName = keychainServiceName
    self.locale = locale
    self.disableSandbox = disableSandbox
    handshakeTimeout = .seconds(10)
    readyTimeout = .seconds(30)
    pingInterval = .seconds(1)
    hangTimeout = .seconds(8)
    shutdownGrace = .seconds(3)
    requestTimeout = .seconds(30)
  }

  /// The host bundle inside `bundle`'s `Contents/Helpers`.
  public static func bundledHostURL(in bundle: Bundle = .main) -> URL {
    bundle.bundleURL
      .appending(path: "Contents/Helpers", directoryHint: .isDirectory)
      .appending(path: "\(hostAppName).app", directoryHint: .isDirectory)
  }

  /// Defaults derived from `bundle`: the bundled host, profiles under
  /// `Application Support/<bundle id>/Chromium`, and a bundle-specific Keychain service. Debug
  /// builds use the mock keychain.
  public static func standard(bundle: Bundle = .main) -> Self {
    let bundleID = bundle.bundleIdentifier ?? "ai.omnigent.weblayer"
    let root = URL.applicationSupportDirectory
      .appending(path: bundleID, directoryHint: .isDirectory)
      .appending(path: "Chromium", directoryHint: .isDirectory)
    #if DEBUG
      let mockKeychain = true
    #else
      let mockKeychain = false
    #endif
    return Self(
      hostAppURL: bundledHostURL(in: bundle),
      rootCacheURL: root,
      useMockKeychain: mockKeychain,
      keychainServiceName: "\(bundleID) Browser Safe Storage")
  }

  var hostExecutableURL: URL {
    hostAppURL.appending(path: "Contents/MacOS/\(Self.hostAppName)", directoryHint: .notDirectory)
  }
}

/// What the client knows about a running host.
nonisolated public struct HostInfo: Sendable, Hashable {
  /// Host process ID.
  public let pid: pid_t
  /// CEF version the host was built with.
  public let cefVersion: String
  /// Chromium version.
  public let chromiumVersion: String
  /// Protocol version the host speaks, "major.minor".
  public let protocolVersion: String
  /// The rendering path in effect.
  public let renderMode: RenderMode
  /// From `start()` to the process being spawned.
  public let spawnDuration: Duration
  /// From `start()` to the handshake.
  public let helloDuration: Duration
  /// From `start()` to Chromium being ready.
  public let readyDuration: Duration
  /// The host's own measurement from its launch to Chromium being ready.
  public let hostInitMilliseconds: UInt64
}

/// Lifecycle of the web host.
nonisolated public enum SessionState: Sendable, Hashable {
  /// Not started.
  case idle
  /// Spawned; waiting for the handshake and for Chromium to initialize.
  case launching
  /// Chromium is running.
  case ready(HostInfo)
  /// The host could not start. `start()` tries again.
  case failed(WebLayerError)
  /// The host was running and then exited or hung. `start()` restarts it.
  case crashed(WebLayerError)
  /// Shut down on request.
  case stopped

  /// The error behind `.failed` or `.crashed`.
  public var error: WebLayerError? {
    switch self {
    case .failed(let error), .crashed(let error): error
    default: nil
    }
  }
}
