public import Foundation

/// Whether an engine can be used right now.
nonisolated public enum BrowserEngineAvailability: Hashable, Sendable {
  /// Ready, or expected to start on first use.
  case available
  /// Cannot be used; the error says why.
  case unavailable(BrowserError)

  /// Whether the engine can be used.
  public var isAvailable: Bool { self == .available }
}

/// A started engine that creates tabs.
public protocol BrowserEngine: AnyObject {
  /// The engine kind.
  var kind: BrowserEngineKind { get }
  /// Creates a tab, optionally starting a load.
  func makeTab(profile: BrowserProfile, initialURL: URL?) throws(BrowserError) -> any BrowserTab
}

/// Resolves engine kinds to engines. Inject a fake in tests.
public protocol BrowserEngineProvider: AnyObject {
  /// Cheap check that never starts an engine.
  func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability
  /// Returns the engine, starting it on first use.
  func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine
}

/// The production provider: the system engine everywhere, Chromium on macOS.
public final class DefaultBrowserEngineProvider: BrowserEngineProvider {
  private var systemEngine: SystemBrowserEngine?
  #if os(macOS)
    private let chromiumConfiguration: ChromiumConfiguration
    private var chromiumEngine: ChromiumBrowserEngine?
    private var chromiumStartError: BrowserError?

    /// Creates a provider using the given Chromium settings.
    public init(chromiumConfiguration: ChromiumConfiguration = .standard()) {
      self.chromiumConfiguration = chromiumConfiguration
    }
  #else
    /// Creates a provider.
    public init() {}
  #endif

  /// See `BrowserEngineProvider.availability(of:)`.
  public func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability {
    guard kind.isSupportedOnThisPlatform else {
      return .unavailable(.engineUnsupported(kind))
    }
    switch kind {
    case .system:
      return .available
    case .chromium:
      #if os(macOS)
        if let chromiumStartError {
          return .unavailable(chromiumStartError)
        }
        return ChromiumBrowserEngine.availability(configuration: chromiumConfiguration)
      #else
        return .unavailable(.engineUnsupported(kind))
      #endif
    }
  }

  /// See `BrowserEngineProvider.engine(for:)`.
  public func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine {
    guard kind.isSupportedOnThisPlatform else {
      throw .engineUnsupported(kind)
    }
    switch kind {
    case .system:
      if let systemEngine {
        return systemEngine
      }
      let engine = SystemBrowserEngine()
      systemEngine = engine
      return engine
    case .chromium:
      #if os(macOS)
        if let chromiumEngine {
          return chromiumEngine
        }
        if let chromiumStartError {
          throw chromiumStartError
        }
        do {
          let engine = try ChromiumBrowserEngine.start(configuration: chromiumConfiguration)
          chromiumEngine = engine
          return engine
        } catch {
          chromiumStartError = error
          throw error
        }
      #else
        throw .engineUnsupported(kind)
      #endif
    }
  }
}
