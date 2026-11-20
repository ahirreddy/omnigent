import Foundation

/// A project (folder) in the sidebar's Projects section.
nonisolated public struct SessionProject: Hashable, Sendable, Identifiable {
  /// Stable id: the project id, or the name of a label-only project.
  public var id: String
  /// Display name.
  public var name: String
  /// Its sessions, in the core's order.
  public var sessionIds: [String]
  /// The server's project id; `nil` for a legacy label-only project.
  public var projectID: String?
  /// An emoji icon, shown instead of the folder.
  public var icon: String?
  /// It stands in for a project the viewer doesn't have yet, to hold other users' automation
  /// runs: it has no menu, board, drag or drop.
  public var isPlaceholder = false

  /// Creates a project.
  /// - Parameters:
  ///   - id: Project id.
  ///   - name: Name.
  ///   - sessionIds: Session ids.
  ///   - projectID: The server's id, when first-class.
  ///   - icon: An emoji icon.
  public init(
    id: String, name: String, sessionIds: [String], projectID: String? = nil, icon: String? = nil
  ) {
    self.id = id
    self.name = name
    self.sessionIds = sessionIds
    self.projectID = projectID
    self.icon = icon
  }
}
