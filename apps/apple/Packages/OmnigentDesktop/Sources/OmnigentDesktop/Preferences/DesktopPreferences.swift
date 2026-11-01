public import Foundation
public import Observation

/// User-chosen desktop settings, persisted in `UserDefaults`. The browser engine is not here:
/// `OmnigentBrowser.BrowserPreferences` owns it, and the app injects its picker into Settings.
@Observable
public final class DesktopPreferences {
  enum Key {
    static let defaultServerURL = "desktop.defaultServerURL"
    static let notifyTurnEnded = "desktop.notifications.turnEnded"
    static let notifyElicitations = "desktop.notifications.elicitations"
    static let notifyRunnerOffline = "desktop.notifications.runnerOffline"
    static let soundEnabled = "desktop.notifications.soundEnabled"
    static let soundName = "desktop.notifications.soundName"
  }

  @ObservationIgnored private let defaults: UserDefaults

  /// The server new windows open on, or `nil` for the connect screen.
  public var defaultServerURL: URL? {
    didSet { defaults.set(defaultServerURL?.absoluteString, forKey: Key.defaultServerURL) }
  }
  /// Notify when a turn finishes or fails.
  public var notifyTurnEnded: Bool {
    didSet { defaults.set(notifyTurnEnded, forKey: Key.notifyTurnEnded) }
  }
  /// Notify when an agent asks for input.
  public var notifyElicitations: Bool {
    didSet { defaults.set(notifyElicitations, forKey: Key.notifyElicitations) }
  }
  /// Notify when a runner goes offline.
  public var notifyRunnerOffline: Bool {
    didSet { defaults.set(notifyRunnerOffline, forKey: Key.notifyRunnerOffline) }
  }
  /// Play a sound with notifications. Off until the user turns it on.
  public var soundEnabled: Bool {
    didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) }
  }
  /// The system sound to play.
  public var soundName: String {
    didSet { defaults.set(soundName, forKey: Key.soundName) }
  }

  /// Loads settings.
  /// - Parameter defaults: The store; tests pass a private suite.
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    defaultServerURL = defaults.string(forKey: Key.defaultServerURL).flatMap(URL.init(string:))
    notifyTurnEnded = defaults.object(forKey: Key.notifyTurnEnded) as? Bool ?? true
    notifyElicitations = defaults.object(forKey: Key.notifyElicitations) as? Bool ?? true
    notifyRunnerOffline = defaults.object(forKey: Key.notifyRunnerOffline) as? Bool ?? true
    soundEnabled = defaults.object(forKey: Key.soundEnabled) as? Bool ?? false
    soundName = defaults.string(forKey: Key.soundName) ?? SystemSounds.defaultName
  }

  /// The notification subset, for `NotificationPolicy`.
  public var notificationPreferences: NotificationPreferences {
    NotificationPreferences(
      turnEnded: notifyTurnEnded, elicitations: notifyElicitations,
      runnerOffline: notifyRunnerOffline, soundEnabled: soundEnabled)
  }
}
