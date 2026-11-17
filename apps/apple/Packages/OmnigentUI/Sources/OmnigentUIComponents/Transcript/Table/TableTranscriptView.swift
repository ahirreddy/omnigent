#if os(macOS)
  import AppKit
  import Observation
  import SwiftUI

  /// The transcript as a table (`omnigent:transcript-list table`): an `NSTableView` whose rows
  /// are reused cells hosting the stack's row views, with heights measured once per row, content
  /// version and width (``TranscriptTableController``). It keeps the stack's follow rules,
  /// paging, Jump to latest, linked messages, the turn rail and the selection popup.
  struct TableTranscriptView: View {
    let state: ConversationViewState
    let liveRows: LiveTranscriptRows?
    let actions: ConversationActions
    let scrollToLatestRequest: Int

    @State private var controller = TranscriptTableController()
    @State private var layout = TranscriptLayoutMemo()
    @State private var environmentRelay = TranscriptEnvironmentRelay()
    @State private var pacer = TranscriptRowsPacer()
    @State private var pill = TranscriptTablePill()
    @State private var rail = TurnRailModel()
    @State private var keys = TranscriptTableKeys()
    @Environment(\.transcriptAppearance) private var appearance
    @Environment(\.transcriptFocus) private var focus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      let actions = environmentRelay.publish(self.actions)
      wireController()
      return TranscriptTableRowsContent(
        state: state, liveRows: liveRows, pacer: pacer, layout: layout, controller: controller,
        actions: actions, rail: rail, keys: keys
      )
      .environment(\.conversationActions, actions)
      .environment(\.openURL, environmentRelay.openURL)
      .environment(\.transcriptDisclosures, controller.disclosures)
      .environment(\.transcriptTableViewport, controller.tableViewport)
      // The rows scroll under the bars around them, which the scroll view insets them by.
      .ignoresSafeArea(.container, edges: .vertical)
      .onGeometryChange(for: EdgeInsets.self) {
        $0.safeAreaInsets
      } action: { insets in
        controller.setInsets(insets)
      }
      .safeAreaBar(edge: .top, spacing: 0) {
        if !appearance.isCLI, let todos = state.section("todos"), !todos.details.isEmpty {
          PlanCard(section: todos)
            .transcriptColumn()
            .padding(.top, Theme.Spacing.small)
        }
      }
      .onChange(of: scrollToLatestRequest) { _, _ in controller.jumpToLatest(animated: true) }
      .onChange(of: TranscriptSends(state)) { previous, latest in
        if latest.hasNewSend(since: previous) { controller.jumpToLatest(animated: true) }
      }
      // The count too: a read that starts and ends between two renders never shows as loading.
      .onChange(of: HistoryRead(isLoading: state.isLoadingHistory, ended: state.historyReads)) {
        if !$1.isLoading { controller.olderHistoryEnded() }
      }
      .modifier(
        TranscriptMessageFocus(
          state: state, pages: actions.loadOlder != nil,
          locate: {
            TranscriptFocus.entryID(forMessage: $0, in: layout.entries(for: state).map(\.segment))
          },
          // The focus asks once per page, as it lands, with the latest state at hand.
          loadOlder: { actions.loadOlder?() },
          show: { controller.show($0, at: .center) })
      )
      .task(id: state.header.id) { pacer.release() }
      .overlay { TableMessageKeys(keys: keys, controller: controller) }
      .modifier(
        JumpToTopReveal(
          hasMoreHistory: state.hasMoreHistory && actions.loadOlder != nil,
          isLoading: state.isLoadingHistory, jump: { controller.jumpToTop() },
          feed: controller.scrollFeed)
      )
      .transcriptSelectionPopup(
        reply: actions.replyWithSelection, ask: actions.askInSideChat, feed: controller.scrollFeed
      )
      .modifier(
        TurnRailOverlay(
          model: rail,
          jump: { [controller, focus] id in
            focus?.flash(id)
            controller.show(id, at: .top, animated: true)
          },
          preview: { TurnRailModel.responsePreview(after: $0, in: layout.entries(for: state)) },
          loadOlder: { controller.requestOlder() })
      )
      .overlay(alignment: .bottom) {
        TableJumpPill(model: pill) { controller.jumpToLatest(animated: true) }
      }
      .background { if appearance.isCLI { CLICanvas() } }
      .cliPalette()
      .accessibilityIdentifier("transcript-\(state.header.id)")
      .countsRenders("transcript")
    }

    /// Hands the controller the callbacks that reach this view's state.
    private func wireController() {
      controller.animatesJumps = Theme.Motion.isEnabled && !reduceMotion
      controller.sourceTopRow = { [liveRows, state] in
        (liveRows?.read().rows ?? state.rows).first?.id
      }
      controller.holdRows = { [pacer] in pacer.hold() }
      controller.releaseRows = { [pacer] in pacer.release() }
      controller.showPill = { [pill] in if pill.pill != $0 { pill.pill = $0 } }
      controller.visibleRowsChanged = { [rail] order, visible in
        guard rail.turns.count >= 2 else { return }
        rail.setActive(order: order, visible: visible)
      }
    }
  }

  /// What the Jump to latest pill shows, read by the pill alone: a reader going past the end
  /// and back shows and hides it without the transcript, its rows and cells updating.
  @MainActor
  @Observable
  final class TranscriptTablePill {
    var pill = TranscriptFollow.Pill()
  }

  /// Whether the transcript has a second user message to move between, read by the message
  /// keys alone.
  @MainActor
  @Observable
  final class TranscriptTableKeys {
    var hasUserMessages = false
  }

  /// The previous and next message keys (``MessageNavigationKeys``) over the table.
  private struct TableMessageKeys: View {
    let keys: TranscriptTableKeys
    let controller: TranscriptTableController

    var body: some View {
      Color.clear
        .allowsHitTesting(false)
        .modifier(
          MessageNavigationKeys(
            isEnabled: keys.hasUserMessages, previous: { controller.step(.previous) },
            next: { controller.step(.next) }))
    }
  }

  private struct TableJumpPill: View {
    let model: TranscriptTablePill
    let jump: () -> Void

    var body: some View {
      if model.pill.isShown {
        JumpToLatestPill(pill: model.pill, action: jump)
          .padding(.bottom, Theme.Spacing.medium)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
      }
    }
  }

  /// The table's rows, read in this view's own body (paced, as the stack's are), so a row
  /// change updates the table and not the scroll view's modifiers and overlays.
  private struct TranscriptTableRowsContent: View {
    let state: ConversationViewState
    let liveRows: LiveTranscriptRows?
    let pacer: TranscriptRowsPacer
    let layout: TranscriptLayoutMemo
    let controller: TranscriptTableController
    let actions: ConversationActions
    let rail: TurnRailModel
    let keys: TranscriptTableKeys
    @Environment(\.transcriptAppearance) private var appearance

    var body: some View {
      let state = rowsState
      pacer.warmup.warm(state.rows)
      let isCLI = appearance.isCLI
      let rows = TranscriptTableRow.rows(
        for: state,
        layout: isCLI ? .cli(layout.blocks(for: state)) : .chat(layout.entries(for: state)),
        offersOlder: actions.loadOlder != nil)
      return TranscriptTableList(
        rows: rows, state: state, actions: actions, isCLI: isCLI, controller: controller
      )
      .background {
        TranscriptTableEnvironmentFeed(environment: controller.environment)
          .frame(width: 0, height: 0)
      }
      .onChange(of: layout.turns(for: state), initial: true) { _, turns in rail.setTurns(turns) }
      // Previous and next need a second message to move between.
      .onChange(of: state.rows.count { $0.role == .user } > 1, initial: true) { _, hasSeveral in
        if keys.hasUserMessages != hasSeveral { keys.hasUserMessages = hasSeveral }
      }
      .modifier(PacedWhileShown(pacer: pacer))
      .modifier(TableShownWatch(controller: controller))
      .countsRenders("rows")
    }

    /// The state with the live rows, when the transcript reads them itself.
    private var rowsState: ConversationViewState {
      guard let liveRows else { return state }
      var state = state
      let live = pacer.rows(from: liveRows)
      state.rows = live.rows
      state.revision = live.revision
      if pacer.isPreparing { state.isHydrating = true }
      return state
    }
  }

  /// Tells the controller when the tab hides and shows, without the row list reading it.
  private struct TableShownWatch: ViewModifier {
    let controller: TranscriptTableController
    @Environment(\.isTabContentHidden) private var isHidden

    func body(content: Content) -> some View {
      content.onChange(of: isHidden, initial: true) { _, isHidden in
        controller.setShown(!isHidden)
      }
    }
  }

  /// Hands the cells the transcript's environment when it changes. On its own, apart from the
  /// rows, so new rows do not hand every cell on screen the same environment again.
  private struct TranscriptTableEnvironmentFeed: NSViewRepresentable {
    let environment: TranscriptTableEnvironment

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
      // A hidden tab's cells keep the environment they were shown in: neither hiding nor
      // showing the tab again renders them. A new environment always would, as its closures
      // compare unequal.
      if context.environment.isTabContentHidden {
        context.coordinator.skippedWhileHidden = true
        return
      }
      if context.coordinator.skippedWhileHidden {
        context.coordinator.skippedWhileHidden = false
        return
      }
      environment.values = context.environment
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
      /// The tab hid since the cells last took the environment.
      var skippedWhileHidden = false
    }
  }

  /// The controller's scroll view in the SwiftUI tree; each update hands it the rows.
  private struct TranscriptTableList: NSViewRepresentable {
    let rows: [TranscriptTableRow]
    let state: ConversationViewState
    let actions: ConversationActions
    let isCLI: Bool
    let controller: TranscriptTableController

    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
      controller.update(
        rows: rows, state: state, actions: actions, isCLI: isCLI,
        environment: context.environment)
    }
  }
#endif
