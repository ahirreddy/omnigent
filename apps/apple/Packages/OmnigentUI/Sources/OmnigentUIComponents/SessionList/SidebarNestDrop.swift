import SwiftUI

/// Where a drag over a session row would land: the row itself (a slot, Pinned or a project), or
/// its middle half, the row's nest (the web's `session-nest` target).
enum SidebarRowDropZone: Hashable {
  case row
  case nest

  /// Where a drop `offset` points down a row `height` tall lands: its middle half is the nest.
  static func at(_ offset: CGFloat, height: CGFloat) -> Self {
    height > 0 && abs(offset - height / 2) < height / 4 ? .nest : .row
  }
}

/// A session row as a drag source and a drop target.
struct SidebarRowDrag {
  /// The session.
  let id: String
  /// What a drag of the row carries; `nil` makes it no drag source.
  let payload: String?
  /// A drop on the row's middle joins its nest.
  let joinsNest: Bool
}

extension SidebarDropHandler {
  /// An owned, active session, which the server can move between nests (the web's
  /// `canMoveNest`).
  func movesBetweenNests(_ session: SessionSummary) -> Bool {
    actions.sessions.moveToNest != nil && !session.isArchived
      && state.rowInfo[session.id]?.isShared != true
  }

  /// `session`'s row as a drag source and target: a nested member drags only to move between
  /// nests, and a row of a nest takes sessions into it where the server lets them join.
  func rowDrag(_ session: SessionSummary, movesWithFamily: Bool) -> SidebarRowDrag {
    let moves = movesBetweenNests(session)
    return SidebarRowDrag(
      id: session.id,
      payload: movesWithFamily && !moves ? nil : SidebarDragItem.session(session.id).payload,
      joinsNest: moves && session.family != nil && actions.sessions.canJoinNests)
  }

  /// Whether the dragged session `id` is a nested member, which leaves its nest when dropped
  /// outside it.
  func leavesNest(_ id: String?) -> Bool {
    guard let id, let session = state.list.sessions.first(where: { $0.id == id }) else {
      return false
    }
    return session.isNestedMember && movesBetweenNests(session)
  }

  /// A drop on a session row: on its middle into its nest; elsewhere a nested member dragged
  /// out of its nest leaves it, and anything else lands on `target`, the row's slot.
  @MainActor func rowDrop(
    _ item: SidebarDragItem, on row: SessionSummary, zone: SidebarRowDropZone,
    target: SidebarDropTarget?
  ) -> Bool {
    if zone == .nest, drop(item, on: .nest(row)) { return true }
    if case .session(let id) = item, leavesNest(id),
      state.list.sessions.first(where: { $0.id == id })?.family?.id != row.family?.id
    {
      return drop(item, on: .leaveNest)
    }
    return target.map { drop(item, on: $0) } ?? false
  }

  /// Carries out a drop of `id` into `destination`'s nest, or with `nil` out of its own; `false`
  /// when it does nothing.
  @MainActor func nestDrop(_ id: String, into destination: SessionSummary?) -> Bool {
    guard let move = actions.sessions.moveToNest,
      let session = state.list.sessions.first(where: { $0.id == id }), movesBetweenNests(session)
    else { return false }
    if let destination {
      guard actions.sessions.canJoinNests, destination.id != id,
        destination.family?.id != session.family?.id
      else { return false }
    } else if session.family == nil {
      return false
    }
    move(session, destination)
    return true
  }
}

extension View {
  /// A session row's drag and drop: it drags `drag.payload`, and takes drops with `accept`,
  /// told which zone of the row they landed in.
  func sidebarRowDragDrop(
    _ drag: SidebarRowDrag,
    accept: @escaping @MainActor (SidebarDragItem, SidebarRowDropZone) -> Bool
  ) -> some View {
    modifier(SidebarRowDragDropModifier(drag: drag, accept: accept))
  }
}

/// The list's own drag and drop, which keep a row's clicks and selection.
private struct SidebarRowDragDropModifier: ViewModifier {
  let drag: SidebarRowDrag
  let accept: @MainActor (SidebarDragItem, SidebarRowDropZone) -> Bool
  @State private var isTargeted = false
  @State private var height: CGFloat = 0

  @ViewBuilder func body(content: Content) -> some View {
    let source = draggable(content)
    if drag.joinsNest {
      nestTarget(source)
    } else {
      // A row of no nest the session can join takes drops as every sidebar target does.
      source.sidebarDropTarget { accept($0, .row) }
    }
  }

  @ViewBuilder private func draggable(_ content: Content) -> some View {
    if let payload = drag.payload {
      content.draggable(payload)
    } else {
      content
    }
  }

  /// A row of a nest: a drop on its middle half takes the dragged session into the nest.
  private func nestTarget(_ source: some View) -> some View {
    source
      .onGeometryChange(for: CGFloat.self) {
        $0.size.height
      } action: {
        height = $0
      }
      .dropDestination(for: String.self) { payloads, location in
        guard let item = payloads.first.flatMap(SidebarDragItem.init(payload:)) else {
          return false
        }
        return accept(item, SidebarRowDropZone.at(location.y, height: height))
      } isTargeted: {
        isTargeted = $0
      }
      .overlay {
        if isTargeted {
          // A nest takes sessions in, as Finder highlights the folder a file drops into.
          RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
            .strokeBorder(Color.accentColor, lineWidth: 1.5)
            .allowsHitTesting(false)
        }
      }
  }
}
