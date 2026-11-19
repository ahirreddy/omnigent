public import Foundation
import SwiftUI

/// The sidebar's rows in the order the user sees them, for Command-[ / Command-] and the pinned
/// session keys (the web's `useSessionSwitchHotkey` and `usePinnedSessionHotkeys`).
public enum SidebarNavigationOrder {
  /// Collapsed section titles, newline-separated (the sidebar's `@AppStorage`).
  static let collapsedSectionsKey = "omnigent:sidebar-collapsed-sections"
  /// Expanded project ids, newline-separated (the sidebar's `@AppStorage`).
  static let expandedProjectsKey = "omnigent:sidebar-expanded-projects"

  /// The project folders the sidebar keeps open, as it saved them.
  /// - Parameter defaults: Where the sidebar keeps them.
  /// - Returns: Their ids.
  public static func expandedProjects(defaults: UserDefaults = .standard) -> Set<String> {
    lines(defaults.string(forKey: expandedProjectsKey))
  }

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

  /// The Pinned section's ids in order, without the members of collapsed families; none while
  /// it is collapsed, as on the web.
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
    return state.visibleRows(pinned.sessions, in: .section(pinned.title))
      .map(\.id)
  }

  /// A group's saved-order ids top to bottom, as its sort shows them: a project's families by
  /// their ids, once each, and Pinned's pins.
  /// - Parameters:
  ///   - group: Pinned, or a project.
  ///   - state: The sidebar.
  /// - Returns: The ids.
  public static func groupIDs(_ group: SessionGroup, in state: SidebarViewState) -> [String] {
    SidebarSections.orderIDs(SidebarSections.units(of: group, in: state), in: group)
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
    shownInProject: [String: Int] = [:]
  ) -> [String] {
    let open = SidebarSections.sections(state).filter { !collapsed.contains($0.title) }
    // A collapsed family's members are not on screen; its head is.
    return open.flatMap { (section: SidebarSections.Section) -> [String] in
      guard section.isProjects else {
        return state.visibleRows(section.sessions, in: .section(section.title))
          .map(\.id)
      }
      return state.projects.filter { expandedProjects.contains($0.id) }.flatMap { project in
        let members = SidebarSections.sessions(of: project, in: state)
        let count = ProjectFolderPaging.visibleCount(
          count: members.count,
          shown: shownInProject[project.id] ?? ProjectShowAll.shown(project.id), selectedIndex: nil)
        return state.visibleRows(members.prefix(count), in: .project(project.id))
          .map(\.id)
      }
    }
  }

  static func lines(_ text: String?) -> Set<String> {
    Set((text ?? "").split(separator: "\n").map(String.init))
  }
}
