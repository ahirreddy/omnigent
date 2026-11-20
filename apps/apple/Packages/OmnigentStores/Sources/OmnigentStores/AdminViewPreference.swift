public import Foundation
import OmnigentCoreFFI

/// Whether an admin uses the admin view on a server, as the web keeps it in the
/// `omnigent_admin_view` cookie: per origin, on unless turned off.
public enum AdminViewPreference {
  /// The key for `serverURL`'s origin; `nil` for a URL without a host.
  static func key(for serverURL: String) -> String? {
    guard let components = URLComponents(string: serverURL), let host = components.host,
      !host.isEmpty
    else { return nil }
    let scheme = components.scheme?.lowercased() ?? "https"
    let port = components.port.map { ":\($0)" } ?? ""
    return "omnigent.admin-view-off.\(scheme)://\(host.lowercased())\(port)"
  }

  /// Whether the admin view is on for `serverURL`: on unless the admin turned it off there.
  public static func isOn(for serverURL: String, defaults: UserDefaults = .standard) -> Bool {
    guard let key = key(for: serverURL) else { return true }
    return !defaults.bool(forKey: key)
  }

  /// Keeps the admin view on or off for `serverURL`'s origin.
  public static func set(
    _ enabled: Bool, for serverURL: String, defaults: UserDefaults = .standard
  ) {
    guard let key = key(for: serverURL) else { return }
    if enabled {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(true, forKey: key)
    }
  }
}

extension ConnectionStore {
  /// Turns the admin view on or off for this server and connects again with it, as the web
  /// reloads after setting its cookie: every request, stream and socket then carries it.
  /// - Parameter enabled: Use the admin view.
  public func setAdminView(_ enabled: Bool) async {
    guard let server = connectedServer else { return }
    AdminViewPreference.set(enabled, for: server.baseUrl)
    await connect(serverURL: server.baseUrl, expectedUserID: server.userId)
  }
}
