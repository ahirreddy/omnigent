import SwiftUI

/// What a sidebar drag carries: a session or a project, as tagged text so a drop from outside
/// the sidebar is ignored.
nonisolated enum SidebarDragItem: Hashable {
  case session(String)
  case project(String)

  private static let sessionPrefix = "omnigent-session:"
  private static let projectPrefix = "omnigent-project:"

  init?(payload: String) {
    if payload.hasPrefix(Self.sessionPrefix) {
      self = .session(String(payload.dropFirst(Self.sessionPrefix.count)))
    } else if payload.hasPrefix(Self.projectPrefix) {
      self = .project(String(payload.dropFirst(Self.projectPrefix.count)))
    } else {
      return nil
    }
  }

  var payload: String {
    switch self {
    case .session(let id): Self.sessionPrefix + id
    case .project(let id): Self.projectPrefix + id
    }
  }
}

/// Where a session was dropped (the web's `SidebarDropTarget`).
nonisolated public enum SidebarDropTarget: Hashable, Sendable {
  /// A project folder or one of its rows.
  case project(SessionProject)
  /// The Pinned header.
  case pinned
  /// A pinned row: the dragged session takes its slot.
  case pinSlot(String)
  /// The Sessions list: out of its project.
  case sessions
}

/// What a session drop does (the web's `resolveSidebarDrop`).
nonisolated public enum SidebarDropAction: Hashable, Sendable {
  /// File into the project, unpinning a pin so it shows there.
  case move(to: SessionProject, unpin: Bool)
  /// Take it out of its project, unpinning a pin.
  case ungroup(unpin: Bool)
  /// Pin it, into a pinned row's slot when given (also reorders a pin).
  case pin(slotOf: String?)
  /// Unpin it.
  case unpin
  /// Nothing to do.
  case none

  /// The action for dropping `session` (filed in `project`, shared with the viewer or not) on
  /// `target`. Filing is owner-only, so a shared session only pins and unpins.
  public static func resolve(
    session: SessionSummary, project: SessionProject?, isShared: Bool, target: SidebarDropTarget
  ) -> Self {
    switch target {
    case .project(let destination):
      if isShared || (destination.id == project?.id && !session.isPinned) { return .none }
      return .move(to: destination, unpin: session.isPinned)
    case .pinned:
      return session.isPinned || !session.canPin || session.isArchived ? .none : .pin(slotOf: nil)
    case .pinSlot(let id):
      return id == session.id || !session.canPin || session.isArchived ? .none : .pin(slotOf: id)
    case .sessions:
      if project != nil, !isShared { return .ungroup(unpin: session.isPinned) }
      return session.isPinned ? .unpin : .none
    }
  }
}

extension SessionProject {
  /// `projects` with `moving` placed at `target`'s index (the web's `arrayMove`); empty when
  /// either is missing or they are the same.
  static func reordered(_ projects: [Self], moving: String, onto target: String) -> [Self] {
    guard let from = projects.firstIndex(where: { $0.id == moving }),
      let to = projects.firstIndex(where: { $0.id == target }), from != to
    else { return [] }
    var result = projects
    result.insert(result.remove(at: from), at: to)
    return result
  }
}

/// Resolves sidebar drops into host actions: a session onto Pinned, a pinned row, a project or
/// the Sessions list, and a project onto another project (reorder). Only the default grouping
/// has drop targets, as on the web.
struct SidebarDropHandler {
  let state: SidebarViewState
  let actions: SidebarActions

  /// Where a drop on a row of `section` goes: a pinned row's slot, or out of a project.
  func rowTarget(_ session: SessionSummary, in section: SidebarSections.Section)
    -> SidebarDropTarget?
  {
    if session.isPinned { return .pinSlot(session.id) }
    guard state.display.groupBy == .default else { return nil }
    return section.showsDisplayMenu ? .sessions : nil
  }

  /// Where a drop on `section`'s header goes.
  func sectionTarget(_ section: SidebarSections.Section) -> SidebarDropTarget? {
    if section.isPinned { return .pinned }
    guard state.display.groupBy == .default else { return nil }
    return section.showsDisplayMenu ? .sessions : nil
  }

  /// Carries out the drop; `false` when it does nothing.
  @MainActor func drop(_ item: SidebarDragItem, on target: SidebarDropTarget) -> Bool {
    switch item {
    case .project(let id):
      guard case .project(let destination) = target, let reorder = actions.reorderProjects
      else { return false }
      let order = SessionProject.reordered(state.projects, moving: id, onto: destination.id)
      if order.isEmpty { return false }
      reorder(order)
      return true
    case .session(let id):
      guard let dropSession = actions.dropSession,
        let session = state.list.sessions.first(where: { $0.id == id })
      else { return false }
      let action = SidebarDropAction.resolve(
        session: session, project: state.projects.first { $0.sessionIds.contains(id) },
        isShared: state.rowInfo[id]?.isShared == true, target: target)
      if action == .none { return false }
      if case .pin = action, !session.isPinned, state.pinnedCount >= state.pinLimit {
        return false
      }
      dropSession(session, action)
      return true
    }
  }
}

extension View {
  /// Accepts sidebar drags that `accept` handles, outlining the row while one is over it.
  func sidebarDropTarget(_ accept: @escaping @MainActor (SidebarDragItem) -> Bool) -> some View {
    modifier(SidebarDropModifier(accept: accept))
  }
}

private struct SidebarDropModifier: ViewModifier {
  let accept: @MainActor (SidebarDragItem) -> Bool
  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .dropDestination(for: String.self) { payloads, _ in
        guard let item = payloads.first.flatMap(SidebarDragItem.init(payload:)) else {
          return false
        }
        return accept(item)
      } isTargeted: {
        isTargeted = $0
      }
      .overlay {
        if isTargeted {
          RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .strokeBorder(ThemeColor.border, lineWidth: 1.5)
            .allowsHitTesting(false)
        }
      }
  }
}
