public import SwiftUI

/// The scrolling conversation: messages, grouped tool calls, activities, banners and the live
/// indicator. Rows are lazy and keyed by their stable ids, so thousands of rows scroll smoothly
/// and only visible markdown is parsed.
///
/// It follows the newest row until the user scrolls up, then offers a Latest button.
public struct TranscriptView: View {
  private let state: ConversationViewState
  private let actions: ConversationActions
  private let scrollToLatestRequest: Int

  @State private var followsLatest = true
  @State private var isUserScrolling = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.layoutWidth) private var layoutWidth

  private static let bottomID = "transcript-bottom"

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
    let segments = Self.segments(for: state)
    let lastAnswerID = state.header.status == .running ? nil : Self.lastAnswerID(state.rows)
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.row) {
          historyHeader
          if let todos = state.section("todos"), !todos.details.isEmpty {
            PlanCard(section: todos)
          }
          if let superseded = state.section("superseded"), let target = superseded.sessionId,
            target != state.header.id
          {
            SupersededBanner(section: superseded, target: target)
          }
          if segments.isEmpty {
            EmptyTranscriptView(state: state)
          }
          ForEach(segments) { segment in
            TurnSegmentView(
              segment: segment, decorations: decorations(for: segment, lastAnswerID: lastAnswerID),
              duration: duration(for: segment)
            )
            .equatable()
            .id(segment.id)
          }
          InlineDecisions(state: state, actions: actions)
          ChildSessionsStrip(sections: state.sections, currentSessionID: state.header.id)
          if state.header.status == .running, !(state.rows.last?.isStreaming ?? false) {
            WorkingIndicator(isBlocked: !state.pendingDecisions.isEmpty)
          }
          if let failure = state.header.failureMessage, !hasErrorRow(matching: failure) {
            FailureBanner(message: failure, resume: actions.resume)
          }
          if let error = state.errorMessage {
            ErrorBanner(message: error, dismiss: actions.dismissError, retry: actions.retry)
          }
          Color.clear.frame(height: 1).id(Self.bottomID)
        }
        .padding(.horizontal, layoutWidth == .compact ? 14 : Theme.Spacing.gutter)
        .padding(.vertical, 16)
        .frame(maxWidth: Theme.transcriptWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      .environment(\.conversationActions, actions)
      .environment(
        \.openURL,
        OpenURLAction { url in
          if let open = actions.openURL {
            open(url)
            return .handled
          }
          return .systemAction
        }
      )
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .scrollDismissesKeyboard(.interactively)
      .onScrollPhaseChange { _, phase in
        isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
      }
      .onScrollGeometryChange(for: Bool.self) { geometry in
        geometry.visibleRect.maxY >= geometry.contentSize.height - 80
      } action: { _, isNearBottom in
        if isUserScrolling || isNearBottom { followsLatest = isNearBottom }
      }
      .onChange(of: state.revision) { _, _ in
        if followsLatest { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
      }
      .onChange(of: scrollToLatestRequest) { _, _ in jumpToLatest(proxy) }
      .task(id: state.header.id) {
        // Lazy rows size themselves after the first layout; anchor once they have.
        await Task.yield()
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
      }
      .overlay(alignment: .bottom) {
        if !followsLatest {
          Button {
            jumpToLatest(proxy)
          } label: {
            Label("Latest", systemImage: "arrow.down")
              .font(.callout.weight(.medium))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
          }
          .buttonStyle(.plain)
          .glassEffect(.regular.interactive(), in: Capsule())
          .padding(.bottom, 12)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
          .accessibilityLabel("Jump to latest message")
          .accessibilityIdentifier("jump-to-latest")
        }
      }
    }
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
    } else if state.hasMoreHistory, let loadOlder = actions.loadOlder {
      HStack {
        Spacer()
        Button("Load earlier messages", systemImage: "clock.arrow.circlepath", action: loadOlder)
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

  private func jumpToLatest(_ proxy: ScrollViewProxy) {
    followsLatest = true
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
      proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }
  }

  /// The transcript after turn folding.
  static func segments(for state: ConversationViewState) -> [TurnSegment] {
    TurnLayout.segments(
      TranscriptLayout.items(for: state.rows), isRunning: state.header.status == .running)
  }

  /// The last settled assistant answer, whose actions stay visible while idle.
  static func lastAnswerID(_ rows: [Row]) -> String? {
    rows.last { $0.role == .assistant && !$0.isStreaming && !$0.text.isEmpty }?.id
  }

  private func decorations(for segment: TurnSegment, lastAnswerID: String?) -> [String:
    MessageDecoration]
  {
    var result: [String: MessageDecoration] = [:]
    let items: [TranscriptItem] =
      switch segment {
      case .item(let item): [item]
      case .worked(_, _, let items, _): items
      }
    for item in items {
      guard case .message(let row) = item else { continue }
      let isOther =
        state.isShared && row.role == .user && row.author != nil
        && row.author != state.viewerName
      result[row.id] = MessageDecoration(
        timestamp: state.timestamps[row.id], showsActions: row.id == lastAnswerID,
        showsAvatar: isOther)
    }
    return result
  }

  private func duration(for segment: TurnSegment) -> TimeInterval? {
    guard case .worked(_, let responseID, _, _) = segment, let responseID else { return nil }
    return state.turnDurations[responseID]
  }
}

/// One folded segment: a plain item, or a Worked fold.
private struct TurnSegmentView: View, Equatable {
  let segment: TurnSegment
  let decorations: [String: MessageDecoration]
  let duration: TimeInterval?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.segment == rhs.segment && lhs.decorations == rhs.decorations && lhs.duration == rhs.duration
  }

  var body: some View {
    switch segment {
    case .item(let item):
      TranscriptItemView(item: item, decorations: decorations)
    case .worked(_, _, let items, let isLive):
      WorkedFold(items: items, isLive: isLive, duration: duration, decorations: decorations)
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
