import Foundation

/// User defaults shared by the connect form, settings and menu commands.
public enum OmnigentDefaults {
  /// `UserDefaults` key holding the last server URL.
  public static let serverURLKey = "omnigent.serverURL"
  /// The local development server.
  public static let defaultServerURL = "http://127.0.0.1:6767"

  /// The stored server URL, or ``defaultServerURL``.
  public static var serverURL: String {
    UserDefaults.standard.string(forKey: serverURLKey) ?? defaultServerURL
  }
}
