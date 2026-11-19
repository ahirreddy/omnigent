import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The sidebar's view state, rebuilt only when the list changed.
///
/// A view that reads it is drawn again when a row can have moved (the list's
/// `placementRevision`, the filter, the projects, the display options), not when a session says
/// something new: each row reads its own session (`SidebarAdapter.live`). Building the state
/// walks every session through the core, so the window's other redraws reuse the last one.
@MainActor
@Observable
final class SidebarStateMemo: SessionListFollower {
  private struct Inputs: Equatable {
    var placement: Int
    var filter: OmnigentCoreFFI.SessionFilter
    var projects: [ProjectSummary]
    var viewerID: String?
    var environments: [String: SessionEnvironment]
    var phase: SessionListPhase
    var display: SessionDisplayOptions
    var sorts: SessionGroupSorts
    var server: ConnectedServer?
    var servers: [ServerChoice]
  }

  @ObservationIgnored private var inputs: Inputs?
  @ObservationIgnored private var cached: SidebarViewState?
  /// The list this follows, and whether it changed since `cached` was built.
  @ObservationIgnored private weak var followed: SessionListStore?
  @ObservationIgnored private var isStale = false
  /// Counts the changes to a row's own content that moved it (grouping by status or update).
  private var rearrangements = 0
  /// How many times the state was built for a reader, for tests.
  @ObservationIgnored private(set) var builds = 0

  /// ``SidebarAdapter/state(list:display:sorts:server:servers:)``, reused until the list
  /// changes.
  func state(
    list: SessionListStore, display: SessionDisplayOptions,
    sorts: SessionGroupSorts = SessionGroupSorts(), server: ConnectedServer?,
    servers: [ServerChoice] = []
  ) -> SidebarViewState {
    _ = rearrangements
    if followed !== list {
      list.follow(self)
      followed = list
      isStale = true
    }
    let current = Inputs(
      placement: list.placementRevision, filter: list.filter, projects: list.projects,
      viewerID: list.viewerID, environments: list.hostEnvironments,
      phase: SidebarAdapter.phase(list), display: display, sorts: sorts, server: server,
      servers: servers)
    // Paging is a store of its own and cheap to read, so a reused state takes it afresh.
    if var cached, !isStale, current == inputs {
      cached.paging = SidebarAdapter.paging(list.paging)
      return cached
    }
    let state = SidebarLoadSignposts.measure("sidebar state", detail: Self.signpostDetail) {
      SidebarAdapter.state(
        list: list, display: display, sorts: sorts, server: server, servers: servers)
    }
    inputs = current
    cached = state
    isStale = false
    builds += 1
    return state
  }

  /// Marks the kept state old. Where rows are grouped by what they say, a change that regroups
  /// them is one the list must draw, so its reader is told.
  func sessionListChanged(_ list: SessionListStore) {
    // A list this no longer reads still tells it.
    guard list === followed else { return }
    isStale = true
    guard let inputs, let cached, Self.followsRows(inputs.display, sorts: inputs.sorts) else {
      return
    }
    let next = SidebarAdapter.state(
      list: list, display: inputs.display, sorts: inputs.sorts, server: inputs.server,
      servers: inputs.servers)
    if SidebarArrangement(next) != SidebarArrangement(cached) { rearrangements += 1 }
  }

  /// The counts a sidebar build's signpost carries.
  private static func signpostDetail(_ state: SidebarViewState) -> String {
    let foldered = state.projects.reduce(0) { $0 + $1.sessionIds.count }
    let phase =
      switch state.list.phase {
      case .loaded: "loaded"
      case .loading: "loading"
      case .failed: "failed"
      }
    return "sessions=\(state.list.sessions.count) projects=\(state.projects.count) "
      + "foldered=\(foldered) phase=\(phase)"
  }

  /// Whether a row's own status, marks, time or title can move it: grouping by status or last
  /// update, or a group sorted by what its rows say. Every row carries its creation date, so the
  /// created order never falls back to the update.
  private static func followsRows(_ display: SessionDisplayOptions, sorts: SessionGroupSorts)
    -> Bool
  {
    display.groupBy == .status || display.groupBy == .updated || sorts.followsRows
  }
}
