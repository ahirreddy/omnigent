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
  /// The rest of the list is loading behind the sidebar's rows on screen; once the full list is
  /// known, reloads are silent, as the web's.
  public private(set) var isRefreshing = false
  /// The list on screen is the sidebar's rows, until the first full read lands; their grid
  /// spots aren't saved before then.
  public private(set) var isPreview = false
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
  /// The board, and the session beside it, a `/canvas` link asks the page to show.
  public var requestedLink: CanvasLinkRequest?

  private let core: ClientCore
  private let defaults: UserDefaults
  @ObservationIgnored private var key: String?
  @ObservationIgnored private var projects: [ProjectSummary] = []
  @ObservationIgnored private var viewerID: String?

  init(core: ClientCore, defaults: UserDefaults = .standard) {
    self.core = core
    self.defaults = defaults
  }

  /// Loads the spots and board saved for `key` (one server and user).
  /// - Parameter key: The defaults key prefix.
  public func bind(key: String) {
    guard self.key != key else { return }
    self.key = key
    positions = [:]
    let stored = defaults.dictionary(forKey: positionsKey(key)) as? [String: [Int]] ?? [:]
    saved = stored.compactMapValues { pair in
      pair.count == 2 ? snapCanvasPosition(x: Int64(pair[0]), y: Int64(pair[1])) : nil
    }
    activeBoard = defaults.string(forKey: boardKey(key)) ?? mainCanvasId()
  }

  /// Reads the sessions, keeping the list on screen until the read lands. The first read paints
  /// `preview` (the sidebar's rows) at once and says it is loading the rest, as the web's.
  /// - Parameters:
  ///   - viewerID: The signed-in user.
  ///   - preview: Canvas sessions already listed elsewhere, newest first.
  public func load(viewerID: String?, preview: [SessionSummary] = []) async {
    if sessions.value == nil {
      if preview.isEmpty {
        sessions = .loading
      } else {
        sessions = .loaded(preview)
        isPreview = true
        relayout(projects: projects, viewerID: viewerID)
      }
    }
    if isPreview { isRefreshing = true }
    defer { if isRefreshing { isRefreshing = false } }
    do {
      let loaded = try await core.canvasSessions(viewerId: viewerID)
      let wasPreview = isPreview
      if wasPreview { isPreview = false }
      if sessions.value != loaded || wasPreview {
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

  /// Places every listed card on its board and, once the full list is known, saves each spot,
  /// grid slots included, so nothing moves on a reload; spots of sessions no longer listed
  /// (deleted, or gone from the canvas) go, as the web's. Cards on screen keep their spots as
  /// more of the list arrives. Run after the sessions, projects or viewer change.
  /// - Parameters:
  ///   - projects: The caller's projects.
  ///   - viewerID: The signed-in user.
  public func relayout(projects: [ProjectSummary], viewerID: String?) {
    self.projects = projects
    self.viewerID = viewerID
    let boards = projects.map { projectCanvasId(project: $0) }
    if boards != projectBoards { projectBoards = boards }
    guard let listed = sessions.value else { return }
    let shown = saved.merging(positions) { _, onScreen in onScreen }
    let next = canvasPositions(
      sessions: listed, projects: projects, saved: shown, viewerId: viewerID)
    if next != positions { positions = next }
    let nextBoards = Dictionary(
      listed.map { ($0.id, canvasIdFor(session: $0, projects: projects, viewerId: viewerID)) },
      uniquingKeysWith: { first, _ in first })
    if nextBoards != boardOf { boardOf = nextBoards }
    guard !isPreview, next != saved else { return }
    saved = next
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
    positions = positions.filter { boardOf[$0.key] != activeBoard }
    relayout(projects: projects, viewerID: viewerID)
  }

  private func persist() {
    guard let key else { return }
    defaults.set(
      saved.mapValues { [Int($0.x), Int($0.y)] } as [String: [Int]], forKey: positionsKey(key))
  }

  private func positionsKey(_ key: String) -> String { "\(key).positions" }
  private func boardKey(_ key: String) -> String { "\(key).board" }
}

/// What a `/canvas?canvas=<board>` or `/canvas/c/<session>` link opens on the Canvas page.
public struct CanvasLinkRequest: Equatable, Sendable {
  /// The board; `nil` is Main.
  public var board: String?
  /// The session shown beside the board.
  public var sessionID: String?

  /// Creates a request.
  public init(board: String?, sessionID: String?) {
    self.board = board
    self.sessionID = sessionID
  }
}
