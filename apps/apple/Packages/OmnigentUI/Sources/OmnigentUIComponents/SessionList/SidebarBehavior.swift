import Observation
import SwiftUI

/// The web sidebar's behavior beyond its saved choices: every section opens while searching
/// (the user can still collapse one for that search), and rows hold still while the pointer is
/// over the list, so a session that updates doesn't jump out from under it.
@MainActor
@Observable
final class SidebarBehavior {
  /// Sections collapsed during the current search; the others are open while it lasts.
  var searchCollapsed: Set<String> = []
  /// Each session's position when the pointer entered the list; empty while it is outside.
  private(set) var heldOrder: [String: Int] = [:]

  /// The pointer entered or left the list.
  /// - Parameters:
  ///   - inside: Whether it is over the list now.
  ///   - sessions: The order to hold.
  func pointer(inside: Bool, sessions: [SessionSummary]) {
    if inside {
      guard heldOrder.isEmpty else { return }
      var order: [String: Int] = [:]
      for (index, session) in sessions.enumerated() where order[session.id] == nil {
        order[session.id] = index
      }
      heldOrder = order
    } else if !heldOrder.isEmpty {
      heldOrder = [:]
    }
  }

  /// `state` with its sessions in the held order, if any.
  func holding(_ state: SidebarViewState) -> SidebarViewState {
    guard !heldOrder.isEmpty else { return state }
    var state = state
    state.list.sessions = Self.holding(state.list.sessions, order: heldOrder)
    return state
  }

  /// Pins keep the core's order (they move only when dragged); the other sessions keep their
  /// held positions, and sessions that arrived since go first.
  nonisolated static func holding(_ sessions: [SessionSummary], order: [String: Int])
    -> [SessionSummary]
  {
    let pinned = sessions.filter(\.isPinned)
    let rest = sessions.filter { !$0.isPinned }.enumerated().sorted { left, right in
      let leftHeld = order[left.element.id] ?? -1
      let rightHeld = order[right.element.id] ?? -1
      return leftHeld != rightHeld ? leftHeld < rightHeld : left.offset < right.offset
    }
    return pinned + rest.map(\.element)
  }

  /// Whether `new` pins a session `old` didn't, so the Pinned section should open.
  nonisolated static func addsPin(_ old: [String], _ new: [String]) -> Bool {
    !Set(new).subtracting(old).isEmpty
  }
}

/// The strongest state among a collapsed section's or folder's hidden rows, shown on its header
/// as the row itself would show it (the web's `projectMarkerState`).
nonisolated enum SidebarMarker: Hashable {
  case needsYou(requests: Int)
  case working
  case failed
  case disconnected
  case unread

  /// The marker for `sessions`, or `nil` when none has anything to show.
  static func strongest(
    _ sessions: some Sequence<SessionSummary>, list: SessionListViewState,
    rowInfo: [String: SessionRowInfo]
  ) -> Self? {
    var requests = 0
    var found: Set<Self> = []
    for session in sessions {
      switch session.attention {
      case .needsYou: requests += max(1, list.attentionCounts[session.id] ?? 1)
      case .working: found.insert(.working)
      case .failed: found.insert(.failed)
      case .unread, .idle:
        if rowInfo[session.id]?.isDisconnected == true {
          found.insert(.disconnected)
        } else if session.attention == .unread || list.unreadIds.contains(session.id) {
          found.insert(.unread)
        }
      }
    }
    if requests > 0 { return .needsYou(requests: requests) }
    return [Self.working, .failed, .disconnected, .unread].first(where: found.contains)
  }
}

/// A ``SidebarMarker`` drawn as a row draws the same state.
struct SidebarMarkerView: View {
  let marker: SidebarMarker

  var body: some View {
    switch marker {
    case .needsYou(let requests):
      NeedsYouCapsule(requests: requests)
    case .working:
      ProgressView().controlSize(.mini)
        .accessibilityLabel("Running")
    case .failed:
      Image(systemName: "exclamationmark.circle")
        .foregroundStyle(Theme.failure)
        .accessibilityLabel("Failed")
    case .disconnected:
      Image(systemName: "bolt.horizontal.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Disconnected")
    case .unread:
      Circle().fill(Theme.unread).frame(width: 6, height: 6)
        .accessibilityLabel("Unread")
    }
  }
}
