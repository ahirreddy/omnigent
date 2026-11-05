import OmnigentPlatform
public import SwiftUI

/// The scrolling conversation: messages, grouped tool calls, activities, banners and the live
/// indicator. Rows are lazy and keyed by their stable ids, so thousands of rows scroll smoothly
/// and only visible markdown is parsed.
///
/// It follows the newest row until the user scrolls up; from then on incoming output never moves
/// the reading position and "Jump to latest" offers the way back (``TranscriptFollow``).
public struct TranscriptView: View {
  private let state: ConversationViewState
  private let actions: ConversationActions
  private let scrollToLatestRequest: Int

  @State private var follow = TranscriptFollow()
  @State private var layout = TranscriptLayoutMemo()
  @State private var environmentRelay = TranscriptEnvironmentRelay()
  @State private var position = TranscriptReadingPosition()
  @Environment(\.transcriptAppearance) private var appearance
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let bottomID = "transcript-bottom"
  private static let topID = "transcript-top"
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
    self.state = state
    self.actions = actions
    self.scrollToLatestRequest = scrollToLatestRequest
  }

  /// The transcript.
  public var body: some View {
    #if DEBUG
      // swiftlint:disable:next redundant_discardable_let
      let _ = FrameMonitor.count("transcript")
    #endif
    let actions = environmentRelay.publish(self.actions)
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(
          alignment: .leading, spacing: appearance.isCLI ? CLIMetrics.blockGap : Theme.Spacing.row
        ) {
          Color.clear.frame(height: 1).id(Self.topID)
          if appearance.isCLI {
            CLITranscriptRows(
              state: state, actions: actions, blocks: layout.blocks(for: state),
              header: historyHeader)
          } else {
            historyHeader
            if let superseded = state.section("superseded"), let target = superseded.sessionId,
              target != state.header.id
            {
              SupersededBanner(section: superseded, target: target)
            }
            let entries = layout.entries(for: state)
            if entries.isEmpty {
              EmptyTranscriptView(state: state)
            }
            ForEach(entries) { entry in
              TurnSegmentView(entry: entry)
                .equatable()
                .id(entry.id)
            }
            InlineDecisions(state: state, actions: actions)
            SubagentGroupView(state: state, actions: actions)
            if let startup = state.section("startup") {
              StartupLine(section: startup)
            }
            if state.header.status == .running, !(state.rows.last?.isStreaming ?? false) {
              WorkingIndicator(
                isBlocked: !state.pendingDecisions.isEmpty, startedAt: TurnElapsed.start(in: state))
            }
            if let failure = state.header.failureMessage, !hasErrorRow(matching: failure) {
              FailureBanner(message: failure, resume: actions.resume)
            }
            if let error = state.errorMessage {
              ErrorBanner(message: error, dismiss: actions.dismissError, retry: actions.retry)
            }
          }
          Color.clear.frame(height: 1).id(Self.bottomID)
        }
        .scrollTargetLayout()
        .padding(.vertical, Theme.Spacing.extraLarge)
        // CLI rows set their own column, so user bands reach the edges.
        .transcriptStackColumn()
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
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .scrollDismissesKeyboard(.interactively)
      .onScrollPhaseChange { _, phase in
        let scrolling = phase == .tracking || phase == .interacting || phase == .decelerating
        if follow.scrollPhaseChanged(isUserScrolling: scrolling) {
          proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        // The composer and dock inset the bottom; rows under them are not being read.
        geometry.visibleRect.maxY - geometry.contentInsets.bottom
          >= geometry.contentSize.height - 80
      } action: { _, isNearBottom in
        follow.geometryChanged(isNearBottom: isNearBottom)
      }
      // The one scroll path while following: new output and late-sizing rows both grow the
      // content. A revision only updates the follow state.
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentSize.height
      } action: { previous, current in
        if current > previous, follow.layoutGrew() {
          proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
      }
      .onChange(of: state.revision) { _, _ in
        _ = follow.contentChanged()
      }
      .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
        position.visible = Set(ids)
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.visibleRect.minY - geometry.contentInsets.top < Self.olderHistoryReach
      } action: { _, isNearTop in
        // Only a reader moving up asks for more, not a short transcript that fits.
        if isNearTop, follow.isUserScrolling || !follow.follows { loadOlder() }
      }
      .onChange(of: state.rows.first?.id) { _, _ in holdReadingPosition(proxy) }
      .onChange(of: state.isLoadingHistory) { _, isLoading in
        if !isLoading { olderHistoryEnded(proxy) }
      }
      .onChange(of: Self.ownMessageID(state)) { previous, current in
        // The reader's own new message takes them to the latest, wherever they were reading.
        if current != nil, previous != nil, current != previous { jumpToLatest(proxy) }
      }
      .onChange(of: scrollToLatestRequest) { _, _ in jumpToLatest(proxy) }
      .task(id: state.header.id) {
        follow.reset()
        position.reset()
        // Lazy rows size themselves after the first layout; anchor once they have.
        await Task.yield()
        await frameLatestTurn(proxy)
      }
      .overlay(alignment: .bottomTrailing) {
        if state.rows.contains(where: { $0.role == .user }) {
          TranscriptNavigator(previous: { step(.previous, proxy) }, next: { step(.next, proxy) })
            .padding(Theme.Spacing.medium)
        }
      }
      .modifier(
        JumpToTopReveal(
          hasMoreHistory: state.hasMoreHistory && actions.loadOlder != nil,
          isLoading: state.isLoadingHistory, jump: { jumpToTop(proxy) })
      )
      .transcriptSelectionPopup(reply: actions.replyWithSelection, ask: actions.askInSideChat)
      .overlay(alignment: .bottom) {
        if follow.showsJumpToLatest {
          JumpToLatestPill(title: follow.jumpTitle, hasUnseenOutput: follow.hasUnseenOutput) {
            jumpToLatest(proxy)
          }
          .padding(.bottom, Theme.Spacing.medium)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
    }
    .background { if appearance.isCLI { CLICanvas() } }
    .cliPalette()
    .accessibilityIdentifier("transcript-\(state.header.id)")
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

  private func hasErrorRow(matching failure: String) -> Bool {
    state.rows.suffix(20).contains {
      $0.activity?.isFailure == true && $0.activity?.summary == failure
    }
  }

  /// Asks for the page above the loaded rows, remembering the top row to keep in place.
  private func loadOlder() {
    guard state.hasMoreHistory, !state.isLoadingHistory, let loadOlder = actions.loadOlder else {
      return
    }
    let order = layout.entries(for: state).map(\.id)
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
    let entries = layout.entries(for: state)
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
  /// Opening a session frames its latest user message at the top, as the web does, so a long
  /// answer reads from its start. When the turn fits, the transcript keeps following.
  private func frameLatestTurn(_ proxy: ScrollViewProxy) async {
    let entries = layout.entries(for: state)
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

/// "Jump to latest", with a dot when output arrived while the user was reading.
private struct JumpToLatestPill: View {
  let title: String
  let hasUnseenOutput: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: Theme.Spacing.small) {
        if hasUnseenOutput {
          Circle().fill(Theme.running).frame(width: 6, height: 6).accessibilityHidden(true)
        }
        Label(title, systemImage: "arrow.down")
      }
      .font(Theme.Typography.label)
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
      .frame(minHeight: Theme.Control.target)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassSurface(in: Capsule(), isInteractive: true)
    .glassTransition()
    .accessibilityLabel("Jump to latest message")
    .accessibilityValue(hasUnseenOutput ? "New output" : "")
    .accessibilityIdentifier("jump-to-latest")
  }
}

/// One folded segment: a plain item, or a Worked fold.
private struct TurnSegmentView: View, Equatable {
  let entry: SegmentEntry

  var body: some View {
    switch entry.segment {
    case .item(let item):
      TranscriptItemView(item: item, decorations: entry.decorations)
    case .worked(_, _, let items, let isLive):
      WorkedFold(
        items: items, isLive: isLive, duration: entry.duration, decorations: entry.decorations)
    }
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
