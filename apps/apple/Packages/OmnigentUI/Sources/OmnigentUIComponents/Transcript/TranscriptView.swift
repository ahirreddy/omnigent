public import SwiftUI

/// The scrolling conversation: messages, grouped tool calls, activities, banners and the live
/// indicator. Rows are lazy and keyed by their stable ids, so thousands of rows scroll smoothly
/// and only visible markdown is parsed.
///
/// It follows the newest row until the user scrolls up; from then on incoming output never moves
/// the reading position and "Jump to latest" offers the way back (``TranscriptFollow``).
public struct TranscriptView: View {
  private let state: ConversationViewState
  private let liveRows: LiveTranscriptRows?
  private let actions: ConversationActions
  private let scrollToLatestRequest: Int

  @State private var scroll = TranscriptScrollState()
  /// The one part of the follow rules the body shows.
  @State private var pill = TranscriptFollow.Pill()
  @State private var layout = TranscriptLayoutMemo()
  @State private var environmentRelay = TranscriptEnvironmentRelay()
  @State private var position = TranscriptReadingPosition()
  @State private var pacer = TranscriptRowsPacer()
  @State private var current: TranscriptCurrentState
  @State private var hasUserMessages = false
  @State private var rail = TurnRailModel()
  @Environment(\.transcriptAppearance) private var appearance
  @Environment(\.transcriptFocus) private var focus
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let bottomID = "transcript-bottom"
  static let topID = "transcript-top"
  /// How close to the top, in points, reading starts loading older history.
  private static let olderHistoryReach: CGFloat = 400

  /// Creates the transcript.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - actions: Host actions.
  ///   - scrollToLatestRequest: Increment to scroll to the newest row (for example from a menu
  ///     command).
  public init(
    state: ConversationViewState, actions: ConversationActions = ConversationActions(),
    scrollToLatestRequest: Int = 0
  ) {
    self.init(
      state: state, liveRows: nil, actions: actions, scrollToLatestRequest: scrollToLatestRequest)
  }

  /// Creates the transcript.
  /// - Parameters:
  ///   - state: The conversation.
  ///   - liveRows: Reads the rows inside the row list, so a row change re-renders only the list;
  ///     `nil` uses `state.rows`.
  ///   - actions: Host actions.
  ///   - scrollToLatestRequest: Increment to scroll to the newest row.
  init(
    state: ConversationViewState, liveRows: LiveTranscriptRows?, actions: ConversationActions,
    scrollToLatestRequest: Int
  ) {
    self.state = state
    self.liveRows = liveRows
    self.actions = actions
    self.scrollToLatestRequest = scrollToLatestRequest
    _current = State(initialValue: TranscriptCurrentState(state))
  }

  /// The follow rules; writing them publishes only a change of the pill.
  private var follow: TranscriptFollow {
    get { scroll.follow }
    nonmutating set {
      scroll.follow = newValue
      if pill != newValue.pill { pill = newValue.pill }
    }
  }

  /// The rows as the list last showed them, for scroll actions outside a body.
  private var shown: ConversationViewState { current.state }

  /// The transcript.
  public var body: some View {
    let actions = environmentRelay.publish(self.actions)
    ScrollViewReader { proxy in
      ScrollView {
        TranscriptRowsContent(
          state: state, liveRows: liveRows, pacer: pacer, actions: actions, layout: layout,
          current: current, events: rowEvents(proxy), header: historyHeader)
      }
      .safeAreaBar(edge: .top, spacing: 0) {
        // The plan stays pinned above the thread, collapsed, as the web's tracker.
        if !appearance.isCLI, let todos = state.section("todos"), !todos.details.isEmpty {
          PlanCard(section: todos)
            .transcriptColumn()
            .padding(.top, Theme.Spacing.small)
        }
      }
      .environment(\.conversationActions, actions)
      .environment(\.openURL, environmentRelay.openURL)
      .environment(\.transcriptScrollState, scroll)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .scrollDismissesKeyboard(.interactively)
      .onScrollPhaseChange { _, phase in
        let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        if follow.scrollPhaseChanged(isUserScrolling: scrolling) {
          proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
      }
      .onScrollGeometryChange(for: TranscriptViewport.self) { geometry in
        TranscriptViewport(geometry)
      } action: { old, new in
        scroll.probe("transcript viewport", "\(old) -> \(new)")
        if old.isNearBottom != new.isNearBottom {
          follow.geometryChanged(isNearBottom: new.isNearBottom)
        }
        // A rotation or resize lays the rows out again: a reader at the bottom stays there, one
        // reading earlier keeps what was at the middle of the screen on screen.
        if new.keepsBottom(after: old) {
          scroll.cancelRestore()
          proxy.scrollTo(Self.bottomID, anchor: .bottom)
        } else if old.width > 0, old.width != new.width {
          scroll.restoreReading(from: old.width, to: new.width)
        }
      }
      // The one scroll path while following: new output and late-sizing rows both grow the
      // content. A revision only updates the follow state.
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentSize.height
      } action: { previous, current in
        scroll.probe("transcript content height", "\(previous) -> \(current), \(follow)")
        if current > previous, follow.layoutGrew(), scroll.follows(current, from: previous) {
          proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
      }
      // The dock growing after layout (the composer replacing the loading notice, a request,
      // the keyboard) would cover the newest rows of a following reader.
      .onScrollGeometryChange(for: CGFloat.self) {
        $0.contentInsets.bottom
      } action: { old, new in
        scroll.probe("transcript dock inset", "\(old) -> \(new)")
        if new > old, follow.layoutGrew() { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
      }
      .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
        scroll.probe("transcript visible rows", "\(ids.count): \(ids.prefix(3)) ...")
        position.visible = Set(ids)
        updateActiveTurn()
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.visibleRect.minY - geometry.contentInsets.top < Self.olderHistoryReach
      } action: { _, isNearTop in
        scroll.probe("transcript near top", "\(isNearTop), \(follow)")
        // Only a reader moving up asks for more, not a short transcript that fits.
        if isNearTop, follow.isUserScrolling || !follow.follows { loadOlder() }
      }
      .onChange(of: state.isLoadingHistory) { _, isLoading in
        if !isLoading { olderHistoryEnded(proxy) }
      }
      .onChange(of: scrollToLatestRequest) { _, _ in jumpToLatest(proxy) }
      .modifier(messageFocus(proxy))
      .task(id: state.header.id) {
        follow.reset()
        position.reset()
        // Lazy rows size themselves after the first layout; anchor once they have.
        await Task.yield()
        await frameLatestTurn(proxy)
      }
      .modifier(
        TranscriptNavigatorOverlay(
          isShown: hasUserMessages,
          previous: { step(.previous, proxy) }, next: { step(.next, proxy) })
      )
      .modifier(
        JumpToTopReveal(
          hasMoreHistory: state.hasMoreHistory && actions.loadOlder != nil,
          isLoading: state.isLoadingHistory, jump: { jumpToTop(proxy) })
      )
      .transcriptSelectionPopup(reply: actions.replyWithSelection, ask: actions.askInSideChat)
      // After the scroll observers above: the rail is a scroll view of its own, and with two in
      // reach they watch whichever SwiftUI finds first.
      .modifier(turnRail(proxy))
      .overlay(alignment: .bottom) {
        if pill.isShown {
          JumpToLatestPill(pill: pill) { jumpToLatest(proxy) }
            .padding(.bottom, Theme.Spacing.medium)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
    }
    .background { if appearance.isCLI { CLICanvas() } }
    .cliPalette()
    .accessibilityIdentifier("transcript-\(state.header.id)")
    .countsRenders("transcript")
  }

  /// The row list's changes, acted on here.
  private func rowEvents(_ proxy: ScrollViewProxy) -> TranscriptRowEvents {
    // Rows reporting the reading anchor restore it through this body's proxy.
    scroll.scrollToRow = { proxy.scrollTo($0, anchor: $1) }
    return TranscriptRowEvents(
      revisionChanged: { _ = follow.contentChanged() },
      firstRowChanged: { holdReadingPosition(proxy) },
      ownMessageChanged: { previous, latest in
        // The reader's own new message takes them to the latest, wherever they were reading.
        if latest != nil, previous != nil, latest != previous { jumpToLatest(proxy) }
      },
      hasUserMessagesChanged: { hasUser in
        if hasUserMessages != hasUser { hasUserMessages = hasUser }
      },
      turnsChanged: { turns in
        rail.setTurns(turns)
        updateActiveTurn()
      })
  }

  @ViewBuilder private var historyHeader: some View {
    if state.isLoadingHistory {
      HStack {
        Spacer()
        ProgressView("Loading earlier messages\u{2026}").controlSize(.small)
        Spacer()
      }
      .accessibilityIdentifier("history-loading")
    } else if state.hasMoreHistory, actions.loadOlder != nil {
      HStack {
        Spacer()
        Button("Load earlier messages", systemImage: "clock.arrow.circlepath") { loadOlder() }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("load-older-messages")
        Spacer()
      }
    }
  }

  /// Asks for the page above the loaded rows, remembering the top row to keep in place.
  private func loadOlder() {
    guard state.hasMoreHistory, !state.isLoadingHistory, let loadOlder = actions.loadOlder else {
      return
    }
    let order = layout.entries(for: shown).map(\.id)
    position.prependAnchor = order.first { position.visible.contains($0) }
    position.awaitsPage = true
    loadOlder()
  }

  /// Older rows landed above: put the row that was on top back at the top.
  private func holdReadingPosition(_ proxy: ScrollViewProxy) {
    guard position.awaitsPage else { return }
    position.awaitsPage = false
    if let anchor = position.prependAnchor, !position.seeksTop {
      proxy.scrollTo(anchor, anchor: .top)
    }
  }

  /// Jump to top pages in the rest of the history first, as the web does.
  private func jumpToTop(_ proxy: ScrollViewProxy) {
    follow.readEarlier()
    if state.hasMoreHistory, actions.loadOlder != nil {
      position.seeksTop = true
      loadOlder()
    } else {
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
        proxy.scrollTo(Self.topID, anchor: .top)
      }
    }
  }

  /// A read of older history ended. Jump to top keeps paging while pages add rows; a failed or
  /// empty page stops it where it is.
  private func olderHistoryEnded(_ proxy: ScrollViewProxy) {
    let added = !position.awaitsPage
    position.awaitsPage = false
    position.prependAnchor = nil
    guard position.seeksTop else { return }
    if added, state.hasMoreHistory, actions.loadOlder != nil {
      loadOlder()
    } else {
      position.seeksTop = false
      proxy.scrollTo(Self.topID, anchor: .top)
    }
  }

  /// Moves to the previous or next user message. With none above, older history loads; with
  /// none below, the newest row shows.
  private func step(_ direction: TranscriptNavigation.Direction, _ proxy: ScrollViewProxy) {
    let entries = layout.entries(for: shown)
    let target = TranscriptNavigation.target(
      direction, order: entries.map(\.id),
      userMessages: TranscriptNavigation.userMessages(entries), visible: position.visible)
    guard let target else {
      if direction == .previous { loadOlder() } else { jumpToLatest(proxy) }
      return
    }
    follow.readEarlier()
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
      proxy.scrollTo(target, anchor: .top)
    }
  }

  private func jumpToLatest(_ proxy: ScrollViewProxy) {
    follow.jumpToLatest()
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
      proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }
  }

  /// The transcript after turn folding.
  static func segments(for state: ConversationViewState) -> [TurnSegment] {
    TurnLayout.segments(
      TranscriptLayout.items(for: state.rows), isRunning: state.header.status == .running)
  }

  /// The viewer's newest message; it changes when they send one (older history loads earlier
  /// rows and leaves it alone).
  static func ownMessageID(_ state: ConversationViewState) -> String? {
    state.rows.last {
      $0.role == .user && ($0.author == nil || $0.author == state.viewerName)
    }?.id
  }

  /// The last settled assistant answer, whose actions stay visible while idle.
  static func lastAnswerID(_ rows: [Row]) -> String? {
    rows.last { $0.role == .assistant && !$0.isStreaming && !$0.text.isEmpty }?.id
  }
}

extension TranscriptView {
  /// The turn rail at the leading edge: a tick scrolls to its turn and flashes it.
  private func turnRail(_ proxy: ScrollViewProxy) -> TurnRailOverlay {
    TurnRailOverlay(
      model: rail,
      jump: { id in
        follow.readEarlier()
        focus?.flash(id)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
          proxy.scrollTo(id, anchor: .top)
        }
      },
      preview: { TurnRailModel.responsePreview(after: $0, in: layout.entries(for: shown)) },
      loadOlder: loadOlder)
  }

  /// Marks the turn owning the middle of the screen on the rail (only while it shows).
  private func updateActiveTurn() {
    let turns = rail.turns
    guard turns.count >= 2 else { return }
    let order =
      appearance.isCLI ? layout.blocks(for: shown).map(\.id) : layout.entries(for: shown).map(\.id)
    rail.setActive(
      TurnRailModel.activeTurn(
        order: order, turns: Set(turns.map(\.id)), visible: position.visible))
  }

  /// Scrolls to the message a `?message=` link points at; a page still landing must not put
  /// the old top row back.
  private func messageFocus(_ proxy: ScrollViewProxy) -> TranscriptMessageFocus {
    TranscriptMessageFocus(
      state: state, pages: actions.loadOlder != nil,
      locate: {
        TranscriptFocus.entryID(forMessage: $0, in: layout.entries(for: state).map(\.segment))
      }, loadOlder: loadOlder,
      show: { target in
        position.prependAnchor = nil
        follow.readEarlier()
        proxy.scrollTo(target, anchor: .center)
      })
  }

  /// Opening a session frames its latest user message at the top, as the web does, so a long
  /// answer reads from its start. When the turn fits, the transcript keeps following.
  private func frameLatestTurn(_ proxy: ScrollViewProxy) async {
    let entries = layout.entries(for: shown)
    let userMessages = TranscriptNavigation.userMessages(entries)
    guard !appearance.isCLI, let latest = entries.last(where: { userMessages.contains($0.id) })
    else {
      proxy.scrollTo(Self.bottomID, anchor: .bottom)
      return
    }
    follow.readEarlier()
    proxy.scrollTo(latest.id, anchor: .top)
    await Task.yield()
    if follow.isNearBottom { follow.jumpToLatest() }
  }
}

struct TranscriptItemView: View {
  let item: TranscriptItem
  let decorations: [String: MessageDecoration]

  var body: some View {
    switch item {
    case .message(let row):
      MessageRowView(row: row, decoration: decorations[row.id] ?? MessageDecoration())
    case .tools(_, let entries): ToolGroupView(entries: entries)
    case .activity(let row): ActivityRowView(row: row)
    }
  }
}
