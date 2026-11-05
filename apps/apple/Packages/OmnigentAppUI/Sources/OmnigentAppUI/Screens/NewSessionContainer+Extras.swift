public import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
public import SwiftUI

/// Connects this Mac as a host for a server ("Use this machine"). The app sets it where the
/// edition can run the CLI; it returns a status line for the Connect a Host sheet.
public struct UseThisMachineAction: Sendable {
  private let run: @MainActor @Sendable (URL) async -> String?

  /// Creates the action.
  /// - Parameter run: Starts hosting for the server URL; returns a status line.
  public init(_ run: @escaping @MainActor @Sendable (URL) async -> String?) {
    self.run = run
  }

  /// Starts hosting for `serverURL`.
  @MainActor public func callAsFunction(_ serverURL: URL) async -> String? {
    await run(serverURL)
  }
}

extension EnvironmentValues {
  /// Connects this Mac as a host; `nil` where the edition cannot.
  @Entry public var useThisMachine: UseThisMachineAction?
}

extension NewSessionContainer {
  /// "Import your recent sessions" while the server has none: the Settings window's Import pane
  /// for this server, or the server's web import page where there is no Settings window.
  func importSessions(_ openURL: OpenURLAction, _ openSettingsAt: OpenSettingsDestinationAction?)
    -> (@MainActor () -> Void)?
  {
    let list = connection.sessionList
    guard list.isLoaded, list.sessionsByID.isEmpty else { return nil }
    if let openSettingsAt {
      let server = connection.supervisedServerURL ?? serverURLText
      return { openSettingsAt(.server(url: server, pane: .importSessions)) }
    }
    guard let url = URL(string: serverURLText)?.appending(path: "settings/import") else {
      return nil
    }
    return { openURL(url) }
  }

  /// The server URL a new host connects to.
  var serverURLText: String {
    connection.connectedServer?.baseUrl ?? ""
  }
}
