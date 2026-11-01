public import Foundation
public import Observation

/// The user's engine choice, persisted in `UserDefaults`.
///
/// Until the user picks, the default is Chromium on macOS when it is available and the system
/// engine otherwise. A stored choice is honored even when that engine later fails to start; the
/// UI then shows the failure and offers the system engine instead of switching on its own.
@Observable
public final class BrowserPreferences {
  /// `UserDefaults` key holding the chosen engine's raw value.
  public static let engineDefaultsKey = "ai.omnigent.browser.engine"

  @ObservationIgnored private let defaults: UserDefaults

  /// The engine used when the user has not chosen one.
  public let defaultEngine: BrowserEngineKind

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
  public init(defaults: UserDefaults = .standard, defaultEngine: BrowserEngineKind) {
    self.defaults = defaults
    self.defaultEngine = defaultEngine
    storedEngine = Self.readStoredEngine(from: defaults)
  }

  /// Creates preferences whose default reflects what the provider can run.
  public convenience init(defaults: UserDefaults = .standard, provider: any BrowserEngineProvider) {
    self.init(
      defaults: defaults,
      defaultEngine: Self.defaultEngine(chromiumAvailability: provider.availability(of: .chromium)))
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

  private static func readStoredEngine(from defaults: UserDefaults) -> BrowserEngineKind? {
    guard let raw = defaults.string(forKey: engineDefaultsKey),
      let kind = BrowserEngineKind(rawValue: raw), kind.isSupportedOnThisPlatform
    else {
      return nil
    }
    return kind
  }
}
