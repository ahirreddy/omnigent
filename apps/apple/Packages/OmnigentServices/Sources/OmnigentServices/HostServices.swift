public import Foundation
public import OmnigentCoreFFI

/// One instance of every non-UI host implementation, for the app to hand to the core.
public struct HostServices: Sendable {
  /// The request/response transport.
  public let http: URLSessionHttpTransport
  /// The server-sent event stream transport.
  public let eventStreams: URLSessionEventStreamTransport
  /// The WebSocket transport.
  public let webSockets: URLSessionWebSocketTransport
  /// The monotonic and wall clocks.
  public let clock: SystemClock
  /// Timers and background tasks.
  public let scheduler: TaskScheduler
  /// Secure storage: the Keychain, or files in Debug Mac builds (``CredentialFileStore``).
  public let secureStore: any SecureStore
  /// The system random source.
  public let entropy: SystemEntropySource
  /// UserDefaults-backed settings.
  public let settings: UserDefaultsSettingsStorage
  /// Organization-managed preferences.
  public let managedPreferences: ManagedPreferencesSource

  /// Creates the bundle from explicit parts.
  public init(
    http: URLSessionHttpTransport,
    eventStreams: URLSessionEventStreamTransport,
    webSockets: URLSessionWebSocketTransport,
    clock: SystemClock,
    scheduler: TaskScheduler,
    secureStore: any SecureStore,
    entropy: SystemEntropySource,
    settings: UserDefaultsSettingsStorage,
    managedPreferences: ManagedPreferencesSource
  ) {
    self.http = http
    self.eventStreams = eventStreams
    self.webSockets = webSockets
    self.clock = clock
    self.scheduler = scheduler
    self.secureStore = secureStore
    self.entropy = entropy
    self.settings = settings
    self.managedPreferences = managedPreferences
  }

  /// The production bundle.
  /// - Parameters:
  ///   - defaults: The defaults database for settings. Apps pass `.standard`.
  ///   - keychainMode: The Keychain the secure store uses.
  ///   - credentialDirectory: Store credentials in files here instead of the Keychain (Debug Mac
  ///     builds only; see ``CredentialFileStore``).
  /// - Returns: The bundle.
  public static func live(
    defaults: UserDefaults = .standard,
    keychainMode: KeychainStorageMode = .dataProtection,
    credentialDirectory: URL? = nil
  ) -> Self {
    Self(
      http: URLSessionHttpTransport(),
      eventStreams: URLSessionEventStreamTransport(),
      webSockets: URLSessionWebSocketTransport(),
      clock: SystemClock(),
      scheduler: TaskScheduler(),
      secureStore: credentialDirectory.map { CredentialFileStore(directory: $0) }
        ?? KeychainSecureStore(mode: keychainMode),
      entropy: SystemEntropySource(),
      settings: UserDefaultsSettingsStorage(defaults: defaults),
      managedPreferences: ManagedPreferencesSource()
    )
  }
}
