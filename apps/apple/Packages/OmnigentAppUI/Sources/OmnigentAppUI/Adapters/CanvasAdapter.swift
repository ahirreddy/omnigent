import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Canvas page over ``CanvasStore``, offered when the server enables the `canvas` feature.
/// Cards take live status and titles from the session list between reloads.
struct CanvasAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  let newSession: () -> Void

  /// How often the sessions are read again while the page is open, as the web.
  static let refreshInterval: Duration = .seconds(30)

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
        state: CanvasMapping.state(canvas, list: connection.sessionList),
        actions: actions(canvas)
      )
      .onAppear { canvas.bind(key: layoutKey) }
      .onChange(of: projectSignature, initial: true) {
        canvas.relayout(
          projects: connection.sessionList.projects, viewerID: connection.sessionList.viewerID)
      }
      .task(id: layoutKey) {
        if connection.sessionList.projects.isEmpty { await connection.sessionList.loadProjects() }
        while !Task.isCancelled {
          await canvas.load(viewerID: connection.sessionList.viewerID)
          do {
            try await Task.sleep(for: Self.refreshInterval)
          } catch {
            return  // Cancelled: the page closed.
          }
        }
      }
    }
  }

  func actions(_ canvas: CanvasStore) -> CanvasActions {
    var actions = CanvasActions { open($0) }
    actions.selectBoard = { canvas.select(board: $0) }
    actions.move = { id, left, top in canvas.move(id, left: Int64(left), top: Int64(top)) }
    actions.resetLayout = { canvas.resetLayout() }
    actions.newSession = { newSession() }
    actions.retry = {
      Task { await canvas.load(viewerID: connection.sessionList.viewerID) }
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

  static func card(
    _ session: OmnigentCoreFFI.SessionSummary, position: CanvasPosition, list: SessionListStore
  )
    -> CanvasCard
  {
    let workspace = session.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
    return CanvasCard(
      id: session.id, title: session.title, state: cardState(session, list: list),
      workspace: workspace.isEmpty ? "No working directory" : workspace,
      branch: session.configuration?.gitBranch, left: Int(position.x), top: Int(position.y))
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
