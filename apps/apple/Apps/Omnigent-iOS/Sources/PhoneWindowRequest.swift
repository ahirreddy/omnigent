import Foundation
import OmnigentAppUI

/// What a new iPad window opens: its server, and a session or tabs torn off another window.
struct PhoneWindowRequest: Codable, Hashable {
  /// The new window's id. Unique per request, so opening one never just focuses another
  /// window; it also names the window's saved tabs.
  var window = UUID()
  /// The server to connect to; `nil` reconnects the last server.
  var serverURL: String?
  /// The session to show once connected.
  var sessionID: String?
  /// Tabs moved from another window.
  var tabs: [AppTab] = []
}
