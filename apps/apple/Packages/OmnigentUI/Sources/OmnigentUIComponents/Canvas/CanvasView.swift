public import SwiftUI

/// The Canvas (the web's `/canvas`): every top-level session as a card on a board, one board per
/// project plus Main. Cards can be dragged and snap to the grid; the board pans, zooms and fits
/// itself to its cards until the user zooms by hand. A card's session opens beside the board
/// where there is room, as the web's split; "+" after the tabs makes a project.
public struct CanvasView: View {
  private let state: CanvasViewState
  private let actions: CanvasActions
  private let quickView: ((String) -> AnyView)?
  private let projectActions: SidebarActions?
  @State private var projectPrompt: ProjectPrompt?
  @State private var projectName = ""
  @State private var deletingProject: SessionProject?
  /// A project made here, whose board is shown once it arrives.
  @State private var awaitedProject: String?

  /// Creates the page.
  /// - Parameters:
  ///   - state: The boards and cards.
  ///   - actions: What the page does.
  ///   - quickView: A session's chat, beside the board when `state.quickViewID` names one.
  ///   - projectActions: New project, from the "+" after the tabs; `nil` hides it.
  public init(
    state: CanvasViewState, actions: CanvasActions, quickView: ((String) -> AnyView)? = nil,
    projectActions: SidebarActions? = nil
  ) {
    self.state = state
    self.actions = actions
    self.quickView = quickView
    self.projectActions = projectActions
  }

  /// The page.
  public var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        header
        boardTabs
        if let error = state.refreshError {
          Label("Refresh failed: \(error)", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.gutter).padding(.bottom, Theme.Spacing.small)
            .accessibilityIdentifier("canvas-refresh-error")
        }
        Divider()
        content
      }
      if let id = state.quickViewID, let close = actions.quickView, let quickView {
        ProjectBoardQuickView(
          title: state.cards.first { $0.id == id }?.title ?? "Session",
          open: { actions.open?(id) }, close: { close(nil) }, content: { quickView(id) })
      }
    }
    .themeCanvas()
    .navigationTitle("Canvas")
    .modifier(
      CanvasProjectDialogs(
        isOn: projectActions?.createProject != nil,
        dialogs: ProjectDialogs(
          prompt: $projectPrompt, name: $projectName, confirmingDelete: $deletingProject,
          actions: dialogActions))
    )
    .onChange(of: state.boards) { _, boards in selectAwaitedProject(boards) }
  }

  /// A card opens its session beside the board when the page offers it, else in its place.
  private func select(_ id: String) {
    if let quickView = actions.quickView {
      quickView(id)
    } else {
      actions.open?(id)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
      Text("Canvas").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
      HStack(spacing: Theme.Spacing.small) {
        Text(state.cards.count == 1 ? "1 session" : "\(state.cards.count) sessions")
        if state.isRefreshing {
          ProgressView().controlSize(.mini).accessibilityLabel("Loading sessions")
        }
      }
      .font(.callout).foregroundStyle(.secondary)
      .accessibilityIdentifier("canvas-count")
    }
    .padding(.horizontal, Theme.Spacing.gutter).padding(.top, Theme.Spacing.small)
  }

  private var boardTabs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Theme.Spacing.extraSmall) {
        ForEach(state.boards) { board in
          let selected = board.id == state.activeBoard
          Button {
            actions.selectBoard?(board.id)
          } label: {
            HStack(spacing: Theme.Spacing.extraSmall) {
              if let icon = board.icon { Text(icon) }
              Text(board.name).lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.medium).padding(.vertical, Theme.Spacing.tiny)
            .frame(maxWidth: 200)
            .foregroundStyle(selected ? .primary : .secondary)
            .background(
              Theme.selection.opacity(selected ? 1 : 0),
              in: RoundedRectangle(cornerRadius: Theme.Radius.small)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
          }
          .buttonStyle(.plain)
          .help(board.name)
          .accessibilityAddTraits(selected ? .isSelected : [])
          .accessibilityIdentifier("canvas-board-\(board.id)")
        }
        if projectActions?.createProject != nil {
          Button("New project", systemImage: "plus") {
            projectName = ""
            projectPrompt = .create(moving: nil)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help("New project")
          .accessibilityIdentifier("canvas-new-project")
        }
      }
      .padding(.horizontal, Theme.Spacing.gutter).padding(.vertical, Theme.Spacing.small)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Canvases")
  }

  @ViewBuilder private var content: some View {
    if let error = state.loadError {
      ContentUnavailableView {
        Label("Canvas could not load", systemImage: "exclamationmark.triangle")
      } description: {
        Text(error)
      } actions: {
        if let retry = actions.retry { Button("Retry", action: retry) }
      }
      .accessibilityIdentifier("canvas-load-error")
    } else if state.isLoading {
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading Canvas")
    } else {
      CanvasBoardSurface(state: state, actions: actions, select: select)
    }
  }

  /// The project actions, noting a new project's name so its board shows once it arrives.
  private var dialogActions: SidebarActions {
    var actions = projectActions ?? SidebarActions(sessions: SessionListActions())
    if let create = actions.createProject {
      actions.createProject = { name, icon, session in
        awaitedProject = name
        create(name, icon, session)
      }
    }
    return actions
  }

  private func selectAwaitedProject(_ boards: [CanvasBoard]) {
    guard let name = awaitedProject, let board = boards.last(where: { $0.name == name }) else {
      return
    }
    awaitedProject = nil
    actions.selectBoard?(board.id)
  }
}

/// The project dialogs, only where the page can make projects, so a page without them has no
/// sheet waiting behind it.
private struct CanvasProjectDialogs: ViewModifier {
  let isOn: Bool
  let dialogs: ProjectDialogs

  func body(content: Content) -> some View {
    if isOn { content.modifier(dialogs) } else { content }
  }
}
