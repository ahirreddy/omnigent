public import Foundation
public import OmnigentStores
public import UserNotifications

/// The signed-in connections of the app's windows and scenes, by server, so a notification's
/// action runs on the connection to the server it came from. Entries are weak: a closed window's
/// connection drops out.
@MainActor
public final class SupervisionConnections {
  /// The app's registry.
  public static let shared = SupervisionConnections()

  private struct Entry {
    weak var connection: ConnectionStore?
  }

  private var entries: [String: Entry] = [:]

  /// Creates an empty registry.
  public init() {}

  /// Records that `connection` is signed in to its server.
  /// - Parameter connection: The connection.
  public func register(_ connection: ConnectionStore) {
    guard let server = connection.supervisedServerURL else { return }
    entries = entries.filter { $0.value.connection != nil && $0.value.connection !== connection }
    entries[Self.key(server)] = Entry(connection: connection)
  }

  /// The signed-in connection to `serverURL`, if a window or scene has one.
  /// - Parameter serverURL: The server, as a notification names it.
  /// - Returns: The connection.
  public func connection(for serverURL: String) -> ConnectionStore? {
    guard let connection = entries[Self.key(serverURL)]?.connection,
      let server = connection.supervisedServerURL, Self.key(server) == Self.key(serverURL)
    else { return nil }
    return connection
  }

  /// The servers with a signed-in connection, for the pairing code.
  public var serverURLs: [String] {
    entries.values.compactMap { $0.connection?.supervisedServerURL }.sorted()
  }

  /// The signed-in connections, one per server, by server URL; for Settings' server picker.
  public var connections: [ConnectionStore] {
    entries.keys.sorted().compactMap { connection(for: $0) }
  }

  /// ``connections``, registering `scene` first when it is signed in but its scene hasn't
  /// registered it yet (Settings can open before the sign-in handlers run).
  /// - Parameter scene: The asking scene's connection.
  /// - Returns: The connections.
  public func connections(including scene: ConnectionStore?) -> [ConnectionStore] {
    if let scene, let server = scene.supervisedServerURL, connection(for: server) == nil {
      register(scene)
    }
    return connections
  }

  static func key(_ serverURL: String) -> String {
    var value = serverURL.lowercased()
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }
}

/// The notification categories, with their Approve, Deny and Reply actions. Approve requires
/// device authentication; on the Mac the app asks for it before acting.
public enum SupervisionNotificationCategories {
  /// Every category, for `UNUserNotificationCenter.setNotificationCategories`.
  public static var all: Set<UNNotificationCategory> {
    Set(
      SupervisionCategory.allCases.map { category in
        UNNotificationCategory(
          identifier: category.rawValue,
          actions: category.actions.map { action(for: $0, in: category) }, intentIdentifiers: [],
          hiddenPreviewsBodyPlaceholder: "Omnigent request", options: [])
      })
  }

  static func action(for action: SupervisionAction, in category: SupervisionCategory)
    -> UNNotificationAction
  {
    switch action {
    case .approve:
      return UNNotificationAction(
        identifier: action.rawValue, title: "Approve", options: [.authenticationRequired],
        icon: UNNotificationActionIcon(systemImageName: "checkmark"))
    case .deny:
      return UNNotificationAction(
        identifier: action.rawValue, title: "Deny", options: [.destructive],
        icon: UNNotificationActionIcon(systemImageName: "xmark"))
    case .reply:
      return UNTextInputNotificationAction(
        identifier: action.rawValue, title: "Reply", options: [],
        icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
        textInputButtonTitle: "Send",
        textInputPlaceholder: category == .question
          ? "An option, its number, or your answer" : "Tell the agent what to do instead")
    }
  }
}
