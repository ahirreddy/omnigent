import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Canvas page over ``CanvasStore``, offered when the server enables the `canvas` feature.
/// Cards take live status and titles from the session list between reloads. Where there is room
/// a card's session opens beside the board (the window's quick view, as project boards use).
struct CanvasAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  /// Starts a session, in the board's project when it is one.
  let newSession: (SessionProject?) -> Void
  /// The window's tabs, whose quick view shows a session beside the board; `nil` opens it.
  var tabs: SessionTabGroups?
  /// A session's chat for the quick view.
  var chat: (String) -> AnyView = { _ in AnyView(EmptyView()) }
  /// New project, from the "+" after the boards.
  var projectActions: SidebarActions?
  @Environment(\.horizontalSizeClass) private var sizeClass

  /// How often the sessions are read again while the page is open, as the web.
  static let refreshInterval: Duration = .seconds(30)
  var readsAgainEvery = Self.refreshInterval

  private var layoutKey: String {
    "omnigent.canvas.\(connection.connectedServer?.baseUrl ?? "").\(connection.connectedServer?.userId ?? "")"
  }

  /// What a relayout depends on besides the sessions.
  private var projectSignature: [String] {
    connection.sessionList.projects.map { "\($0.id ?? ""):\($0.name)" }
      + [connection.sessionList.viewerID ?? ""]
  }

  var body: some View {
    if connection.pages?.offered?.canvas != true {
      ContentUnavailableView(
        "Canvas is not enabled on this server", systemImage: "square.grid.2x2",
        description: Text("Ask the server's administrator to turn on the Canvas feature."))
    } else if let canvas = connection.canvas {
      CanvasView(
        state: state(canvas), actions: actions(canvas), quickView: chat,
        projectActions: projectActions
      )
      .onAppear { canvas.bind(key: layoutKey) }
      .onChange(of: canvas.requestedLink, initial: true) { _, request in
        guard let request else { return }
        canvas.requestedLink = nil
        follow(request, canvas: canvas)
      }
      .onDisappear { tabs?.quickViewSessionID = nil }
      .onChange(of: projectSignature, initial: true) {
        canvas.relayout(
          projects: connection.sessionList.projects, viewerID: connection.sessionList.viewerID)
      }
      .task(id: "\(layoutKey)#\(connection.health.reconnections)") {
        if connection.sessionList.projects.isEmpty { await connection.sessionList.loadProjects() }
        while !Task.isCancelled {
          await canvas.load(
            viewerID: connection.sessionList.viewerID,
            preview: CanvasMapping.preview(connection.sessionList))
          do {
            try await Task.sleep(for: readsAgainEvery)
          } catch {
            break  // Cancelled: the page closed.
          }
        }
      }
    }
  }

  /// A `/canvas` link: its board (Main when it names none), and its session beside the board
  /// where there is room, else opened.
  private func follow(_ request: CanvasLinkRequest, canvas: CanvasStore) {
    canvas.bind(key: layoutKey)
    canvas.select(board: request.board ?? CanvasMapping.mainBoardID)
    guard let sessionID = request.sessionID else { return }
    if let tabs, sizeClass != .compact {
      tabs.quickViewSessionID = sessionID
    } else {
      open(sessionID)
    }
  }

  private func state(_ canvas: CanvasStore) -> CanvasViewState {
    var state = CanvasMapping.state(canvas, list: connection.sessionList)
    state.quickViewID = tabs?.quickViewSessionID
    return state
  }

  func actions(_ canvas: CanvasStore) -> CanvasActions {
    let tabs = tabs
    var actions = CanvasActions { id in
      tabs?.quickViewSessionID = nil
      open(id)
    }
    if let tabs, sizeClass != .compact {
      actions.quickView = { tabs.quickViewSessionID = $0 }
    }
    actions.selectBoard = { canvas.select(board: $0) }
    actions.move = { id, left, top in canvas.move(id, left: Int64(left), top: Int64(top)) }
    actions.resetLayout = { canvas.resetLayout() }
    actions.newSession = {
      newSession(
        CanvasMapping.project(of: canvas.activeBoard, canvas: canvas, list: connection.sessionList))
    }
    actions.retry = {
      Task {
        await canvas.load(
          viewerID: connection.sessionList.viewerID,
          preview: CanvasMapping.preview(connection.sessionList))
      }
    }
    return actions
  }
}

/// Maps the canvas store and live session list to the page's view state.
enum CanvasMapping {
  static func state(_ canvas: CanvasStore, list: SessionListStore) -> CanvasViewState {
    let main = mainBoardID
    let boards =
      [CanvasBoard(id: main, name: "Main")]
      + zip(list.projects, canvas.projectBoards).map { project, id in
        CanvasBoard(id: id, name: project.name, icon: project.icon)
      }
    let active = boards.contains { $0.id == canvas.activeBoard } ? canvas.activeBoard : main
    let sessions = canvas.sessions.value ?? []
    let onBoard = sessions.filter { (canvas.boardOf[$0.id] ?? main) == active }
    let cards = onBoard.compactMap { session -> CanvasCard? in
      guard let position = canvas.positions[session.id] else { return nil }
      return card(list.session(session.id) ?? session, position: position, list: list)
    }
    var state = CanvasViewState(boards: boards, activeBoard: active, cards: cards)
    state.isLoading = canvas.sessions == .loading || canvas.sessions == .idle
    state.isRefreshing = canvas.isRefreshing
    if case .failed(let error) = canvas.sessions { state.loadError = error.message }
    state.refreshError = canvas.refreshError?.message
    if let project = boards.first(where: { $0.id == active && $0.id != main }) {
      state.emptyTitle = "No sessions in \(project.name)"
    } else if !list.projects.isEmpty {
      state.emptyTitle = "No sessions outside projects"
    }
    return state
  }

  /// Main's id, read once: the core's constant.
  static let mainBoardID = mainCanvasId()

  /// How many of the sidebar's rows a first visit paints before the full list, as the web's.
  static let previewLimit = 25

  /// The sidebar's canvas sessions, newest first: what a first visit paints at once.
  static func preview(_ list: SessionListStore) -> [OmnigentCoreFFI.SessionSummary] {
    let rows = list.sessionsByID.values.filter {
      isCanvasSession(session: $0, viewerId: list.viewerID)
    }
    let newest = rows.sorted { left, right in
      left.updatedAt != right.updatedAt ? left.updatedAt > right.updatedAt : left.id < right.id
    }
    return Array(newest.prefix(previewLimit))
  }

  /// The project a board shows; `nil` for Main.
  static func project(of board: String, canvas: CanvasStore, list: SessionListStore)
    -> SessionProject?
  {
    let pair = zip(list.projects, canvas.projectBoards).first { _, id in id == board }
    return pair.map { project, _ in ProjectBoardAdapter.folder(project) }
  }

  static func card(
    _ session: OmnigentCoreFFI.SessionSummary, position: CanvasPosition, list: SessionListStore
  )
    -> CanvasCard
  {
    let workspace = session.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
    var card = CanvasCard(
      id: session.id, title: session.title, state: cardState(session, list: list),
      workspace: workspace.isEmpty ? "No working directory" : workspace,
      branch: session.configuration?.gitBranch, left: Int(position.x), top: Int(position.y))
    card.requests = max(1, Int(session.pendingRequests))
    card.pullRequest = session.pullRequest.flatMap { pullRequest($0) }
    return card
  }

  /// The card's PR link, as the web's: "#212 Ship it", the title and stored state with its age
  /// as the tooltip; none without an https page.
  static func pullRequest(_ pullRequest: RowPullRequest, now: Date = .now) -> CanvasPullRequest? {
    guard let url = URL(string: pullRequest.url), url.scheme?.lowercased() == "https" else {
      return nil
    }
    let number = "\(pullRequest.numberPrefix)\(pullRequest.number)"
    let title = pullRequest.title ?? ""
    return CanvasPullRequest(
      text: title.isEmpty ? number : "\(number) \(title)", url: url,
      tooltip: CanvasPullRequest.tooltip(
        title: title.isEmpty ? number : title, SidebarAdapter.pullRequest(pullRequest), now: now),
      accessibilityLabel: "Open \(pullRequest.requestName ?? "pull request") \(number)")
  }

  static func cardState(_ session: OmnigentCoreFFI.SessionSummary, list: SessionListStore)
    -> CanvasCard.State
  {
    switch session.status {
    case .needsResponse: return .needsYou
    case .running: return .running
    case .idle: break
    }
    if session.failureMessage != nil { return .failed }
    return list.unreadIDs.contains(session.id) ? .unread : .idle
  }
}
