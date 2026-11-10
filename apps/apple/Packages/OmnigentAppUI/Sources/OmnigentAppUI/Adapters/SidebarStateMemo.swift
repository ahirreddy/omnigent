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

  /// ``SidebarAdapter/state(list:display:server:servers:)``, reused until the list changes.
  func state(
    list: SessionListStore, display: SessionDisplayOptions, server: ConnectedServer?,
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
      phase: SidebarAdapter.phase(list), display: display, server: server, servers: servers)
    // Paging is a store of its own and cheap to read, so a reused state takes it afresh.
    if var cached, !isStale, current == inputs {
      cached.paging = SidebarAdapter.paging(list.paging)
      return cached
    }
    let state = SidebarAdapter.state(list: list, display: display, server: server, servers: servers)
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
    guard let inputs, let cached, Self.followsRows(inputs.display) else { return }
    let next = SidebarAdapter.state(
      list: list, display: inputs.display, server: inputs.server, servers: inputs.servers)
    if SidebarArrangement(next) != SidebarArrangement(cached) { rearrangements += 1 }
  }

  /// Whether a row's own status, marks or time can move it: grouping by status or last update.
  /// Every row carries its creation date, so the created order never falls back to the update.
  private static func followsRows(_ display: SessionDisplayOptions) -> Bool {
    display.groupBy == .status || display.groupBy == .updated
  }
}
