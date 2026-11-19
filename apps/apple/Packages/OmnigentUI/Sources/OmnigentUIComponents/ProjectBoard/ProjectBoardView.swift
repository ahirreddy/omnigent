public import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#endif

/// A project's board (the web's project home): its sessions as cards in five status lanes, Draft,
/// Needs attention, Working, Unread and Done. Lanes follow live status; dragging a card between
/// Unread and Done marks it read or unread, and any other drop snaps back. The header names the
/// project with its settings and menu, filters the cards and floats New session's composer over
/// the lanes. A card opens its session; its quick view opens the session beside the lanes. On a
/// phone one lane shows at a time, and New session opens the full composer.
public struct ProjectBoardView<Composer: View, QuickView: View>: View {
  private let state: ProjectBoardViewState
  private let actions: ProjectBoardActions
  private let projectActions: SidebarActions
  private let composer: () -> Composer
  private let quickView: (String) -> QuickView

  @State private var dragging: String?
  @State private var targeted: ProjectBoardLane?
  @State private var pagerLane: ProjectBoardLane?
  @FocusState private var focusedCard: String?
  @State private var prompts = ProjectBoardPrompts()
  @Environment(\.horizontalSizeClass) private var sizeClass

  /// Creates the page.
  /// - Parameters:
  ///   - state: The project, its lanes and what is open.
  ///   - actions: What the board does.
  ///   - projectActions: The sidebar's project actions: settings, rename and delete.
  ///   - composer: New session's composer, filed in the project, floated over the lanes.
  ///   - quickView: A session's chat, beside the lanes.
  public init(
    state: ProjectBoardViewState, actions: ProjectBoardActions, projectActions: SidebarActions,
    @ViewBuilder composer: @escaping () -> Composer,
    @ViewBuilder quickView: @escaping (String) -> QuickView
  ) {
    self.state = state
    self.actions = actions
    self.projectActions = projectActions
    self.composer = composer
    self.quickView = quickView
  }

  /// A phone shows one lane at a time.
  private var isPaged: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  /// The page.
  public var body: some View {
    VStack(spacing: 0) {
      if !isPaged {
        ProjectBoardHeader(
          state: state, actions: actions, projectActions: projectActions,
          rename: beginRename, confirmDelete: { prompts.deletingProject = state.project })
      }
      content
    }
    .themeCanvas()
    .navigationTitle(state.project.name)
    #if os(iOS)
      .toolbar { if isPaged { phoneToolbar } }
    #endif
    .modifier(
      SessionDialogs(
        renaming: $prompts.renaming, renameText: $prompts.renameText,
        confirmingDelete: $prompts.deleting, confirmingBulkDelete: $prompts.deletingMany,
        confirmingLeave: $prompts.leaving, confirmingStop: $prompts.stopping, rowInfo: rowInfo,
        actions: actions.sessions, deletedMany: {})
    )
    .modifier(
      ProjectDialogs(
        prompt: $prompts.project, name: $prompts.projectName,
        confirmingDelete: $prompts.deletingProject, actions: projectActions)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("project-board")
  }

  @ViewBuilder private var content: some View {
    switch state.phase {
    case .loading:
      ProgressView("Loading sessions\u{2026}")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("project-board-loading")
    case .failed(let message):
      ContentUnavailableView {
        Label("Couldn\u{2019}t Load Sessions", systemImage: "exclamationmark.triangle")
      } description: {
        Text("Couldn\u{2019}t load this project\u{2019}s sessions.\n\(message)")
      } actions: {
        if let retry = actions.retry {
          Button("Try Again", action: retry)
            .accessibilityIdentifier("project-board-retry")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      if isPaged {
        pagedLanes
      } else {
        HStack(spacing: 0) {
          lanesWithComposer
          if let id = state.quickViewID, let close = actions.quickView {
            ProjectBoardQuickView(
              title: state.card(id)?.session.title ?? "Session", open: { actions.open(id) },
              close: { close(nil) }, content: { quickView(id) })
          }
        }
      }
    }
  }

  // MARK: Lanes

  private var lanesWithComposer: some View {
    VStack(spacing: 0) {
      lanes
      loadMore
    }
    .overlay(alignment: .bottom) {
      if state.isComposerShown {
        // A floating panel, so the chips under the composer don't sit on the cards.
        composer()
          .padding(Theme.Spacing.small)
          .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: Theme.Radius.composer + 8, style: .continuous)
          )
          .frame(maxWidth: NewSessionPage.composerWidth)
          .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
          .padding(.horizontal, Theme.Spacing.large)
          .padding(.bottom, Theme.Spacing.extraLarge)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          #if os(macOS)
            .onExitCommand { actions.toggleComposer?() }
          #endif
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("project-board-composer")
      }
    }
    .animation(Theme.Motion.disclosure, value: state.isComposerShown)
  }

  /// The lanes side by side, each between a minimum and the web's maximum width, scrolling
  /// sideways when the window is too narrow for all five.
  private var lanes: some View {
    GeometryReader { geometry in
      let width = ProjectBoardLayout.laneWidth(for: geometry.size.width)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: ProjectBoardLayout.laneSpacing) {
          ForEach(state.columns) { column in
            lane(column).frame(width: width)
          }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.large)
        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
      }
      .scrollIndicators(.automatic)
    }
    #if os(macOS)
      .focusSection()
      .onContinuousHover { _ in
        // Hover with no button held: a drag ended, dropped on a lane or not.
        if dragging != nil, NSEvent.pressedMouseButtons == 0 { dragging = nil }
      }
    #endif
    .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
      guard let direction = ProjectBoardFocus.Direction(press.key),
        let next = ProjectBoardFocus.next(from: focusedCard, direction, in: state.columns)
      else { return .ignored }
      focusedCard = next
      return .handled
    }
    .onKeyPress(.return) {
      guard let focusedCard else { return .ignored }
      actions.open(focusedCard)
      return .handled
    }
    .onKeyPress(.space) {
      guard let focusedCard, let quickView = actions.quickView else { return .ignored }
      quickView(state.quickViewID == focusedCard ? nil : focusedCard)
      return .handled
    }
  }

  private func lane(_ column: ProjectBoardColumn) -> some View {
    let dragged = dragging.flatMap { state.card($0) }
    let accepts = dragged.map { $0.lane != column.lane && actions.accepts($0.lane, column.lane) }
    return ProjectBoardLaneView(
      column: column, emptyLabel: state.emptyLabel, accepts: accepts ?? false,
      isTargeted: targeted == column.lane,
      bottomClearance: state.isComposerShown ? ProjectBoardLayout.composerClearance : 0
    ) { card in
      cardView(card)
    }
    .onDrop(
      of: [.text],
      delegate: ProjectBoardLaneDrop(
        lane: column.lane, state: state, actions: actions, dragging: $dragging,
        targeted: $targeted))
  }

  private var pagedLanes: some View {
    ProjectBoardLanePager(
      columns: state.columns,
      lane: Binding(get: { pagerLane ?? state.openingLane }, set: { pagerLane = $0 })
    ) { column in
      ProjectBoardLaneView(
        column: column, emptyLabel: state.emptyLabel, accepts: false, isTargeted: false,
        bottomClearance: 0, showsHeader: false
      ) { card in
        cardView(card)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) { loadMore }
  }

  @ViewBuilder private var loadMore: some View {
    if state.hasMore, let loadMore = actions.loadMore {
      Button(state.isLoadingMore ? "Loading\u{2026}" : "Load More Sessions", action: loadMore)
        .disabled(state.isLoadingMore)
        .padding(.bottom, Theme.Spacing.large)
        .accessibilityIdentifier("project-board-load-more")
    }
  }

  // MARK: Cards

  private func cardView(_ card: ProjectBoardCard) -> some View {
    // Phones have no room beside the lanes; their cards open the whole session.
    let quickView = isPaged ? nil : actions.quickView.map { show in { show(card.id) } }
    return ProjectBoardCardCell(
      card: card, state: state, actions: actions, menu: menu(for: card), quickView: quickView,
      isFocusable: !isPaged, dragging: $dragging, focusedCard: $focusedCard)
  }

  /// A card's menu: the sidebar row's actions that change the board, with read and unread for
  /// every unread session it stands for.
  private func menu(for card: ProjectBoardCard) -> SessionRowMenu {
    var sessions = actions.sessions
    sessions.setPinned = nil
    sessions.share = nil
    sessions.createAutomation = nil
    sessions.addNestedAgent = nil
    sessions.openInSplit = nil
    if let setUnread = actions.setUnread {
      sessions.setUnread = { _, unread in setUnread(card, unread) }
    }
    return SessionRowMenu(
      session: card.session, isUnread: card.isUnread, isShared: card.info.isShared,
      pinLimitReached: false, projects: state.projects, actions: sessions,
      rename: {
        prompts.renameText = card.session.title
        prompts.renaming = card.session
      },
      confirmDelete: { prompts.deleting = card.session },
      confirmLeave: { prompts.leaving = card.session },
      confirmStop: { prompts.stopping = card.session }, project: state.project)
  }

  private var rowInfo: [String: SessionRowInfo] {
    Dictionary(
      state.columns.flatMap(\.cards).map { ($0.id, $0.info) },
      uniquingKeysWith: { first, _ in first })
  }

  private func beginRename() {
    prompts.projectName = state.project.name
    prompts.project = .rename(state.project)
  }

  #if os(iOS)
    @ToolbarContentBuilder private var phoneToolbar: some ToolbarContent {
      ToolbarItemGroup(placement: .primaryAction) {
        if let toggle = actions.toggleComposer {
          Button("New Session", systemImage: "plus.bubble", action: toggle)
            .accessibilityIdentifier("project-board-new-session")
        }
        ProjectBoardProjectMenu(
          project: state.project, projectActions: projectActions, rename: beginRename,
          confirmDelete: { prompts.deletingProject = state.project }, includesSettings: true)
      }
    }
  #endif
}

/// The prompts a board's cards and header ask: rename, delete, leave and stop a session, and
/// rename and delete the project.
struct ProjectBoardPrompts {
  var renaming: SessionSummary?
  var renameText = ""
  var deleting: SessionSummary?
  var deletingMany: [SessionSummary] = []
  var leaving: SessionSummary?
  var stopping: SessionSummary?
  var project: ProjectPrompt?
  var projectName = ""
  var deletingProject: SessionProject?
}
