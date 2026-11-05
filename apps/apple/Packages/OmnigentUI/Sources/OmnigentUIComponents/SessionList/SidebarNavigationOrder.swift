public import Foundation
import SwiftUI

/// The sidebar's rows in the order the user sees them, for Command-[ / Command-] and the pinned
/// session keys (the web's `useSessionSwitchHotkey` and `usePinnedSessionHotkeys`).
public enum SidebarNavigationOrder {
  /// Collapsed section titles, newline-separated (the sidebar's `@AppStorage`).
  static let collapsedSectionsKey = "omnigent:sidebar-collapsed-sections"
  /// Expanded project ids, newline-separated (the sidebar's `@AppStorage`).
  static let expandedProjectsKey = "omnigent:sidebar-expanded-projects"

  /// Session ids top to bottom, open sections and expanded projects only.
  /// - Parameters:
  ///   - state: The sidebar.
  ///   - defaults: Where the sidebar keeps its collapsed sections and expanded projects.
  /// - Returns: The ids.
  @MainActor public static func sessionIDs(
    _ state: SidebarViewState, defaults: UserDefaults = .standard
  ) -> [String] {
    sessionIDs(
      state, collapsed: lines(defaults.string(forKey: collapsedSectionsKey)),
      expandedProjects: lines(defaults.string(forKey: expandedProjectsKey)))
  }

  /// The Pinned section's ids in order; none while it is collapsed, as on the web.
  /// - Parameters:
  ///   - state: The sidebar.
  ///   - defaults: Where the sidebar keeps its collapsed sections.
  /// - Returns: The ids.
  @MainActor public static func pinnedIDs(
    _ state: SidebarViewState, defaults: UserDefaults = .standard
  ) -> [String] {
    let collapsed = lines(defaults.string(forKey: collapsedSectionsKey))
    let pinned = SidebarSections.sections(state).first(where: \.isPinned)
    guard let pinned, !collapsed.contains(pinned.title) else { return [] }
    return pinned.sessions.map(\.id)
  }

  /// The session `offset` rows from `current`, wrapping at the ends. Off the list, forward
  /// enters at the top and back at the bottom.
  /// - Parameters:
  ///   - current: The open session, if any.
  ///   - offset: `1` for next, `-1` for previous.
  ///   - ids: The sidebar's order.
  /// - Returns: The session to open, or `nil` when there is none to move to.
  public static func step(from current: String?, by offset: Int, in ids: [String]) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else {
      return offset > 0 ? ids.first : ids.last
    }
    let next = ids[((index + offset) % ids.count + ids.count) % ids.count]
    return next == current ? nil : next
  }

  static func sessionIDs(
    _ state: SidebarViewState, collapsed: Set<String>, expandedProjects: Set<String>,
    showsAllInProject: Set<String> = []
  ) -> [String] {
    let loaded = Set(state.list.sessions.map(\.id))
    let open = SidebarSections.sections(state).filter { !collapsed.contains($0.title) }
    return open.flatMap { (section: SidebarSections.Section) -> [String] in
      guard section.isProjects else { return section.sessions.map(\.id) }
      return state.projects.filter { expandedProjects.contains($0.id) }.flatMap { project in
        let members = project.sessionIds.filter(loaded.contains)
        return showsAllInProject.contains(project.id)
          ? members : Array(members.prefix(ProjectFolder<EmptyView>.collapsedCount))
      }
    }
  }

  static func lines(_ text: String?) -> Set<String> {
    Set((text ?? "").split(separator: "\n").map(String.init))
  }
}
