#if os(macOS) || os(iOS)
  import Observation
  import SwiftUI

  #if os(macOS)
    import AppKit
  #else
    import UIKit
  #endif

  #if os(macOS)
    /// The list's AppKit side.
    typealias TranscriptListController = TranscriptTableController
  #else
    /// The list's UIKit side.
    typealias TranscriptListController = TranscriptCollectionController
  #endif

  /// The transcript as a list of reused cells (`omnigent:transcript-list table`): an
  /// `NSTableView` on the Mac (``TranscriptTableController``), a `UICollectionView` on iPhone and
  /// iPad (``TranscriptCollectionController``). Cells host the stack's row views, with heights
  /// measured once per row, content version and width. It keeps the stack's follow rules,
  /// paging, Jump to latest, linked messages, the turn rail and the selection popup.
  struct TableTranscriptView: View {
    let state: ConversationViewState
    let liveRows: LiveTranscriptRows?
    let actions: ConversationActions
    let scrollToLatestRequest: Int

    @State private var controller = TranscriptListController()
    @State private var layout = TranscriptLayoutMemo()
    @State private var environmentRelay = TranscriptEnvironmentRelay()
    @State private var pacer = TranscriptRowsPacer()
    @State private var pill = TranscriptTablePill()
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
      // The rows scroll under the bars around them, which the scroll view insets them by; on
      // iPhone and iPad under the keyboard too.
      #if os(macOS)
        .ignoresSafeArea(.container, edges: .vertical)
      #else
        .ignoresSafeArea(edges: .vertical)
      #endif
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
        TableJumpPill(model: pill) { controller.jumpToLatest() }
      }
      .background { if appearance.isCLI { CLICanvas() } }
      .cliPalette()
      .accessibilityIdentifier("transcript-\(state.header.id)")
      .countsRenders("transcript")
    }

    /// Hands the controller the callbacks that reach this view's state.
    private func wireController() {
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
    let controller: TranscriptListController
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
      .background {
        TranscriptTableEnvironmentFeed(controller: controller).frame(width: 0, height: 0)
      }
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
    let controller: TranscriptListController
    @Environment(\.isTabContentHidden) private var isHidden

    func body(content: Content) -> some View {
      content.onChange(of: isHidden, initial: true) { _, isHidden in
        controller.setShown(!isHidden)
      }
    }
  }

  /// Hands the cells the transcript's environment when it changes. On its own, apart from the
  /// rows, so new rows do not hand every cell on screen the same environment again.
  private struct TranscriptTableEnvironmentFeed {
    let controller: TranscriptListController
  }

  /// The controller's scroll view in the SwiftUI tree; each update hands it the rows.
  private struct TranscriptTableList {
    let rows: [TranscriptTableRow]
    let state: ConversationViewState
    let actions: ConversationActions
    let isCLI: Bool
    let controller: TranscriptListController

    func update(in environment: EnvironmentValues) {
      controller.update(
        rows: rows, state: state, actions: actions, isCLI: isCLI, environment: environment)
    }
  }

  #if os(macOS)
    extension TranscriptTableEnvironmentFeed: NSViewRepresentable {
      func makeNSView(context: Context) -> NSView { NSView() }

      func updateNSView(_ view: NSView, context: Context) {
        controller.environment.values = context.environment
      }
    }

    extension TranscriptTableList: NSViewRepresentable {
      func makeNSView(context: Context) -> NSScrollView { controller.scrollView }

      func updateNSView(_ view: NSScrollView, context: Context) {
        update(in: context.environment)
      }
    }
  #else
    extension TranscriptTableEnvironmentFeed: UIViewRepresentable {
      func makeUIView(context: Context) -> UIView { UIView() }

      func updateUIView(_ view: UIView, context: Context) {
        controller.environmentChanged(context.environment)
      }
    }

    extension TranscriptTableList: UIViewRepresentable {
      func makeUIView(context: Context) -> UICollectionView { controller.collectionView }

      func updateUIView(_ view: UICollectionView, context: Context) {
        update(in: context.environment)
      }
    }
  #endif
#endif
