#if os(macOS)
  import AppKit
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
    @State private var pill = TranscriptFollow.Pill()
    @State private var rail = TurnRailModel()
    @Environment(\.transcriptAppearance) private var appearance
    @Environment(\.transcriptFocus) private var focus

    var body: some View {
      let actions = environmentRelay.publish(self.actions)
      wireController()
      return TranscriptTableRowsContent(
        state: state, liveRows: liveRows, pacer: pacer, layout: layout, controller: controller,
        actions: actions, rail: rail
      )
      .environment(\.conversationActions, actions)
      .environment(\.openURL, environmentRelay.openURL)
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
      .onChange(of: scrollToLatestRequest) { _, _ in controller.jumpToLatest() }
      .onChange(of: TranscriptSends(state)) { previous, latest in
        if latest.hasNewSend(since: previous) { controller.jumpToLatest() }
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
      .transcriptSelectionPopup(reply: actions.replyWithSelection, ask: actions.askInSideChat)
      .modifier(
        TurnRailOverlay(
          model: rail,
          jump: { [controller, focus] id in
            focus?.flash(id)
            controller.show(id, at: .top)
          },
          preview: { TurnRailModel.responsePreview(after: $0, in: layout.entries(for: state)) },
          loadOlder: { controller.requestOlder() })
      )
      .overlay(alignment: .bottom) {
        if pill.isShown {
          JumpToLatestPill(pill: pill) { controller.jumpToLatest() }
            .padding(.bottom, Theme.Spacing.medium)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .background { if appearance.isCLI { CLICanvas() } }
      .cliPalette()
      .accessibilityIdentifier("transcript-\(state.header.id)")
      .countsRenders("transcript")
    }

    /// Hands the controller the callbacks that reach this view's state.
    private func wireController() {
      let pill = $pill
      controller.showPill = { if pill.wrappedValue != $0 { pill.wrappedValue = $0 } }
      controller.visibleRowsChanged = { [rail] order, visible in
        guard rail.turns.count >= 2 else { return }
        rail.setActive(order: order, visible: visible)
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
      .onChange(of: layout.turns(for: state), initial: true) { _, turns in rail.setTurns(turns) }
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

  /// The controller's scroll view in the SwiftUI tree; each update hands it the rows and the
  /// environment its cells render in.
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
