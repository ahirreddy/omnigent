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
  /// Engines this build offers, in display order. Pickers list exactly these. A build that
  /// does not include an engine (the Mac App Store edition has no Chromium) leaves it out.
  var offeredEngines: [BrowserEngineKind] { get }
  /// Cheap check that never starts an engine.
  func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability
  /// Returns the engine, starting it on first use.
  func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine
}

extension BrowserEngineProvider {
  /// Every engine this platform supports. Providers that ship fewer engines override this.
  public var offeredEngines: [BrowserEngineKind] { BrowserEngineKind.supportedOnThisPlatform }
}

/// An engine that is not part of the core package, such as Chromium from
/// `OmnigentBrowserChromium`. Apps that ship it register it with `DefaultBrowserEngineProvider`.
public protocol BrowserEngineFactory: AnyObject {
  /// The engine kind this factory starts.
  var kind: BrowserEngineKind { get }
  /// Cheap check that never starts the engine.
  func availability() -> BrowserEngineAvailability
  /// Starts the engine. Called at most once per successful start; failures are remembered by
  /// the provider.
  func start() throws(BrowserError) -> any BrowserEngine
}

/// The production provider: the system engine, plus any engines the app registers.
///
/// The core package never links an engine that a build may not ship. The Developer ID Mac app
/// registers Chromium (`ChromiumEngineFactory`); the Mac App Store and iOS builds register
/// nothing, so they offer only the system engine.
public final class DefaultBrowserEngineProvider: BrowserEngineProvider {
  private var systemEngine: SystemBrowserEngine?
  private let factories: [BrowserEngineKind: any BrowserEngineFactory]
  private var startedEngines: [BrowserEngineKind: any BrowserEngine] = [:]
  private var startErrors: [BrowserEngineKind: BrowserError] = [:]

  /// Creates a provider.
  /// - Parameter additionalEngines: Engines beyond the system engine. Factories for kinds this
  ///   platform cannot host are ignored and reported as unsupported.
  public init(additionalEngines: [any BrowserEngineFactory] = []) {
    var factories: [BrowserEngineKind: any BrowserEngineFactory] = [:]
    for factory in additionalEngines where factory.kind != .system {
      factories[factory.kind] = factory
    }
    self.factories = factories
  }

  /// The system engine and every registered engine the platform supports, in
  /// `BrowserEngineKind.allCases` order.
  public var offeredEngines: [BrowserEngineKind] {
    BrowserEngineKind.supportedOnThisPlatform.filter { $0 == .system || factories[$0] != nil }
  }

  /// See `BrowserEngineProvider.availability(of:)`.
  public func availability(of kind: BrowserEngineKind) -> BrowserEngineAvailability {
    guard kind.isSupportedOnThisPlatform else {
      return .unavailable(.engineUnsupported(kind))
    }
    if kind == .system {
      return .available
    }
    guard let factory = factories[kind] else {
      return .unavailable(Self.notOffered(kind))
    }
    if let startError = startErrors[kind] {
      return .unavailable(startError)
    }
    return factory.availability()
  }

  /// See `BrowserEngineProvider.engine(for:)`.
  public func engine(for kind: BrowserEngineKind) throws(BrowserError) -> any BrowserEngine {
    guard kind.isSupportedOnThisPlatform else {
      throw .engineUnsupported(kind)
    }
    if kind == .system {
      if let systemEngine {
        return systemEngine
      }
      let engine = SystemBrowserEngine()
      systemEngine = engine
      return engine
    }
    guard let factory = factories[kind] else {
      throw Self.notOffered(kind)
    }
    if let engine = startedEngines[kind] {
      return engine
    }
    if let startError = startErrors[kind] {
      throw startError
    }
    do {
      let engine = try factory.start()
      startedEngines[kind] = engine
      return engine
    } catch {
      startErrors[kind] = error
      throw error
    }
  }

  private static func notOffered(_ kind: BrowserEngineKind) -> BrowserError {
    .engineNotBundled(kind, reason: "This edition of the app ships only the system engine.")
  }
}
