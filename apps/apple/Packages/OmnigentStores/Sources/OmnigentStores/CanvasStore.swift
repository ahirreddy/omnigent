import Foundation
public import Observation
public import OmnigentCoreFFI

/// The Canvas page: the caller's top-level sessions, the board on screen, and the card spots the
/// user placed. Spots and the board are kept on this device per server and user, as the web keeps
/// them in local storage; the server never learns the layout.
@Observable
public final class CanvasStore {
  /// The caller's canvas sessions.
  public private(set) var sessions: CreationLoad<[SessionSummary]> = .idle
  /// A reload is in flight with the list already on screen.
  public private(set) var isRefreshing = false
  /// The last reload's failure, while the earlier list stays on screen.
  public private(set) var refreshError: CoreError?
  /// Saved card spots by session.
  public private(set) var saved: [String: CanvasPosition] = [:]
  /// The board on screen: ``mainCanvasId()`` or a project's ``projectCanvasId(project:)``.
  public private(set) var activeBoard = mainCanvasId()
  /// Every listed card's position, saved or on its board's grid.
  public private(set) var positions: [String: CanvasPosition] = [:]
  /// The board each listed session is on.
  public private(set) var boardOf: [String: String] = [:]
  /// The board id of each project, in the projects' order.
  public private(set) var projectBoards: [String] = []

  private let core: ClientCore
  private let defaults: UserDefaults
  @ObservationIgnored private var key: String?
  @ObservationIgnored private var projects: [ProjectSummary] = []
  @ObservationIgnored private var viewerID: String?

  /// The most spots kept; spots of sessions no longer listed go first.
  static let maxSavedPositions = 5_000

  init(core: ClientCore, defaults: UserDefaults = .standard) {
    self.core = core
    self.defaults = defaults
  }

  /// Loads the spots and board saved for `key` (one server and user).
  /// - Parameter key: The defaults key prefix.
  public func bind(key: String) {
    guard self.key != key else { return }
    self.key = key
    let stored = defaults.dictionary(forKey: positionsKey(key)) as? [String: [Int]] ?? [:]
    saved = stored.compactMapValues { pair in
      pair.count == 2 ? snapCanvasPosition(x: Int64(pair[0]), y: Int64(pair[1])) : nil
    }
    activeBoard = defaults.string(forKey: boardKey(key)) ?? mainCanvasId()
  }

  /// Reads the sessions; a reload keeps the list on screen until it lands.
  /// - Parameter viewerID: The signed-in user.
  public func load(viewerID: String?) async {
    if sessions.value == nil {
      sessions = .loading
    } else {
      isRefreshing = true
    }
    defer { if isRefreshing { isRefreshing = false } }
    do {
      let loaded = try await core.canvasSessions(viewerId: viewerID)
      if sessions.value != loaded {
        sessions = .loaded(loaded)
        relayout(projects: projects, viewerID: viewerID)
      }
      if refreshError != nil { refreshError = nil }
    } catch {
      if sessions.value == nil {
        sessions = .failed(coreError(error))
      } else {
        refreshError = coreError(error)
      }
    }
  }

  /// Shows `board`, remembered for the next visit.
  public func select(board: String) {
    guard activeBoard != board else { return }
    activeBoard = board
    if let key { defaults.set(board, forKey: boardKey(key)) }
  }

  /// Places every listed card on its board and saves each spot, grid slots included, so
  /// nothing moves on a reload. Run after the sessions, projects or viewer change.
  /// - Parameters:
  ///   - projects: The caller's projects.
  ///   - viewerID: The signed-in user.
  public func relayout(projects: [ProjectSummary], viewerID: String?) {
    self.projects = projects
    self.viewerID = viewerID
    let boards = projects.map { projectCanvasId(project: $0) }
    if boards != projectBoards { projectBoards = boards }
    guard let listed = sessions.value else { return }
    let next = canvasPositions(
      sessions: listed, projects: projects, saved: saved, viewerId: viewerID)
    if next != positions { positions = next }
    let nextBoards = Dictionary(
      listed.map { ($0.id, canvasIdFor(session: $0, projects: projects, viewerId: viewerID)) },
      uniquingKeysWith: { first, _ in first })
    if nextBoards != boardOf { boardOf = nextBoards }
    let merged = saved.merging(next) { _, new in new }
    guard merged != saved else { return }
    saved = pruned(merged, live: Set(next.keys))
    persist()
  }

  /// Drops `sessionID`'s card with its top-left corner at `(left, top)`, snapped to the grid.
  public func move(_ sessionID: String, left: Int64, top: Int64) {
    let position = snapCanvasPosition(x: left, y: top)
    guard saved[sessionID] != position else { return }
    saved[sessionID] = position
    persist()
    if positions[sessionID] != nil { positions[sessionID] = position }
  }

  /// Lays the active board's cards out afresh.
  public func resetLayout() {
    guard let listed = sessions.value else { return }
    saved = resetCanvasPositions(
      sessions: listed, projects: projects, saved: saved, viewerId: viewerID,
      canvasId: activeBoard)
    persist()
    relayout(projects: projects, viewerID: viewerID)
  }

  private func pruned(_ positions: [String: CanvasPosition], live: Set<String>)
    -> [String: CanvasPosition]
  {
    guard positions.count > Self.maxSavedPositions else { return positions }
    var kept = positions.filter { live.contains($0.key) }
    for (id, position) in positions where kept.count < Self.maxSavedPositions {
      kept[id] = position
    }
    return kept
  }

  private func persist() {
    guard let key else { return }
    defaults.set(
      saved.mapValues { [Int($0.x), Int($0.y)] } as [String: [Int]], forKey: positionsKey(key))
  }

  private func positionsKey(_ key: String) -> String { "\(key).positions" }
  private func boardKey(_ key: String) -> String { "\(key).board" }
}
