public import Foundation
public import Observation

/// The user's engine choice, persisted in `UserDefaults`.
///
/// Until the user picks, the default is Chromium on macOS when the build offers it and it is
/// available, and the system engine otherwise. A stored choice is honored even when that engine
/// later fails to start; the UI then shows the failure and offers the system engine instead of
/// switching on its own. A stored choice the build does not offer is ignored.
@Observable
public final class BrowserPreferences {
  /// `UserDefaults` key holding the chosen engine's raw value.
  public static let engineDefaultsKey = "ai.omnigent.browser.engine"

  @ObservationIgnored private let defaults: UserDefaults

  /// The engine used when the user has not chosen one.
  public let defaultEngine: BrowserEngineKind

  /// Engines a stored choice may name. Anything else falls back to `defaultEngine`.
  public let allowedEngines: [BrowserEngineKind]

  /// The user's explicit choice, if any.
  public private(set) var storedEngine: BrowserEngineKind?

  /// The engine to use.
  public var engine: BrowserEngineKind {
    get { storedEngine ?? defaultEngine }
    set {
      storedEngine = newValue
      defaults.set(newValue.rawValue, forKey: Self.engineDefaultsKey)
    }
  }

  /// Creates preferences with an explicit default.
  /// - Parameters:
  ///   - defaults: The store; tests pass a private suite.
  ///   - defaultEngine: The engine until the user picks one.
  ///   - allowedEngines: Engines a stored choice may name.
  public init(
    defaults: UserDefaults = .standard, defaultEngine: BrowserEngineKind,
    allowedEngines: [BrowserEngineKind] = BrowserEngineKind.supportedOnThisPlatform
  ) {
    self.defaults = defaults
    self.defaultEngine = defaultEngine
    self.allowedEngines = allowedEngines
    storedEngine = Self.readStoredEngine(from: defaults, allowed: allowedEngines)
  }

  /// Creates preferences whose default and allowed engines reflect what the provider offers.
  public convenience init(defaults: UserDefaults = .standard, provider: any BrowserEngineProvider) {
    let offered = provider.offeredEngines
    let chromium: BrowserEngineAvailability =
      offered.contains(.chromium)
      ? provider.availability(of: .chromium)
      : .unavailable(.engineNotBundled(.chromium, reason: "Not offered by this build."))
    self.init(
      defaults: defaults,
      defaultEngine: Self.defaultEngine(chromiumAvailability: chromium),
      allowedEngines: offered)
  }

  /// Chromium when supported and available, otherwise the system engine.
  public static func defaultEngine(chromiumAvailability: BrowserEngineAvailability)
    -> BrowserEngineKind
  {
    BrowserEngineKind.chromium.isSupportedOnThisPlatform && chromiumAvailability.isAvailable
      ? .chromium : .system
  }

  /// Forgets the explicit choice.
  public func resetToDefault() {
    storedEngine = nil
    defaults.removeObject(forKey: Self.engineDefaultsKey)
  }

  private static func readStoredEngine(from defaults: UserDefaults, allowed: [BrowserEngineKind])
    -> BrowserEngineKind?
  {
    guard let raw = defaults.string(forKey: engineDefaultsKey),
      let kind = BrowserEngineKind(rawValue: raw), kind.isSupportedOnThisPlatform,
      allowed.contains(kind)
    else {
      return nil
    }
    return kind
  }
}
