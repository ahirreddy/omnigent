public import SwiftUI

/// Where a nested session sits, as the web's search rows show it: its project folder, then the
/// session it is nested under.
nonisolated public struct PaletteBreadcrumb: Hashable, Sendable {
  /// The project folder's name, when it is filed.
  public var project: String?
  /// The title of the session it is nested under.
  public var parent: String

  /// Creates a breadcrumb.
  /// - Parameters:
  ///   - project: The project's name.
  ///   - parent: The parent's title.
  public init(project: String? = nil, parent: String) {
    self.project = project
    self.parent = parent
  }

  /// A nested member's breadcrumb, `nil` for any other session. The parent is its family's
  /// representative: by its title, a loaded row's, or "Session group".
  /// - Parameters:
  ///   - session: The session.
  ///   - project: Its project's name.
  ///   - loadedTitle: A loaded session's title, by id.
  /// - Returns: The breadcrumb.
  public static func nested(
    _ session: SessionSummary, project: String?, loadedTitle: (String) -> String?
  ) -> Self? {
    guard let representative = session.nestedUnder else { return nil }
    let parent =
      session.family?.representativeTitle ?? loadedTitle(representative) ?? "Session group"
    return Self(project: project, parent: parent)
  }
}

/// A palette row's breadcrumb line: folder, project, chevron, corner arrow, parent.
struct PaletteBreadcrumbLine: View {
  let breadcrumb: PaletteBreadcrumb

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      if let project = breadcrumb.project {
        Image(systemName: "folder").accessibilityHidden(true)
        Text(project).lineLimit(1).accessibilityLabel("Project: \(project)")
        Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
      }
      Image(systemName: "arrow.turn.down.right").accessibilityHidden(true)
      Text(breadcrumb.parent).lineLimit(1)
        .accessibilityLabel("Nested under: \(breadcrumb.parent)")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("palette-breadcrumb")
  }
}
