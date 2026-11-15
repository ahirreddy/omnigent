import OmnigentCoreFFI
import OmnigentStores

/// Whether the server lets the viewer add nested agents (`/v1/info.sibling_sessions`): every
/// "Add nested agent" entry point and its shortcut need it. Existing families show either way.
enum NestedAgentGate {
  /// The capability, as the server's pages last reported it.
  static func offered(_ connection: ConnectionStore) -> Bool {
    connection.pages?.offered?.siblingSessions == true
  }
}
