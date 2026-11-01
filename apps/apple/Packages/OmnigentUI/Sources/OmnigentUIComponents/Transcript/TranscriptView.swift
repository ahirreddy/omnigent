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
    let entries = Self.entries(for: state.rows)
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.row) {
          historyHeader
          if let superseded = state.section("superseded"), let target = superseded.sessionId,
            target != state.header.id
          {
            SupersededBanner(section: superseded, target: target)
          }
          if entries.isEmpty {
            EmptyTranscriptView(state: state)
          }
          ForEach(entries) { entry in
            TranscriptItemView(item: entry.item, showsAuthor: entry.showsAuthor)
              .equatable()
              .id(entry.id)
          }
          ChildSessionsStrip(sections: state.sections, currentSessionID: state.header.id)
          if state.header.status == .running, !(state.rows.last?.isStreaming ?? false) {
            HStack(spacing: 8) {
              TypingIndicator()
              Text("Working").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .accessibilityIdentifier("transcript-working")
          }
          if let failure = state.header.failureMessage, !hasErrorRow(matching: failure) {
            FailureBanner(message: failure)
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
        ProgressView("Loading earlier messages").controlSize(.small)
        Spacer()
      }
      .accessibilityIdentifier("history-loading")
    } else if state.hasMoreHistory, let loadOlder = actions.loadOlder {
      HStack {
        Spacer()
        Button("Load Earlier Messages", systemImage: "clock.arrow.circlepath", action: loadOlder)
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

  struct Entry: Identifiable, Hashable {
    let item: TranscriptItem
    let showsAuthor: Bool
    var id: String { item.id }
  }

  /// Items plus whether each assistant message starts a new speaker run.
  static func entries(for rows: [Row]) -> [Entry] {
    var previousSpeaker: String?
    return TranscriptLayout.items(for: rows).map { item in
      switch item {
      case .message(let row):
        let speaker = row.role == .user ? "user:\(row.author ?? "")" : "agent:\(row.agent ?? "")"
        defer { previousSpeaker = speaker }
        return Entry(item: item, showsAuthor: speaker != previousSpeaker)
      case .tools, .activity:
        return Entry(item: item, showsAuthor: false)
      }
    }
  }
}

private struct TranscriptItemView: View, Equatable {
  let item: TranscriptItem
  let showsAuthor: Bool

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item && lhs.showsAuthor == rhs.showsAuthor
  }

  var body: some View {
    switch item {
    case .message(let row): MessageRowView(row: row, showsAuthor: showsAuthor)
    case .tools(_, let entries): ToolGroupView(entries: entries)
    case .activity(let row): ActivityRowView(row: row)
    }
  }
}

private struct EmptyTranscriptView: View {
  let state: ConversationViewState

  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "bubble.left.and.text.bubble.right")
        .font(.largeTitle)
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(title).font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
    .accessibilityElement(children: .combine)
  }

  private var title: String {
    state.hasMoreHistory ? "No messages on this page" : "No messages yet"
  }

  private var detail: String {
    if !state.lifecycleRows.isEmpty { return "Lifecycle details are in the inspector." }
    if state.hasMoreHistory { return "Load earlier messages to continue." }
    return "Send a message to start the conversation."
  }
}

private struct SupersededBanner: View {
  let section: EventSection
  let target: String
  @Environment(\.conversationActions) private var actions

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "arrow.turn.down.right")
        .foregroundStyle(Theme.accent)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(section.title).font(.callout.weight(.semibold))
        Text(section.summary).font(.callout).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if let open = actions.openSession {
        Button("Open") { open(target) }
          .accessibilityIdentifier("session-open-successor")
      }
    }
    .padding(12)
    .cardSurface(cornerRadius: Theme.Radius.medium, tint: Theme.accent)
  }
}

/// Links to child (subagent) sessions the stream reported.
struct ChildSessionsStrip: View {
  let sections: [EventSection]
  let currentSessionID: String
  @Environment(\.conversationActions) private var actions

  private var children: [EventSection] {
    sections.filter { $0.id.hasPrefix("child-") && $0.sessionId != nil }
  }

  var body: some View {
    if !children.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Subagent sessions")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        FlowLayout(spacing: 6) {
          ForEach(children) { child in
            ChildSessionLink(section: child, open: actions.openSession)
          }
        }
      }
      .accessibilityElement(children: .contain)
    }
  }
}

struct ChildSessionLink: View {
  let section: EventSection
  let open: ((String) -> Void)?

  var body: some View {
    Button {
      if let id = section.sessionId { open?(id) }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
          .foregroundStyle(Theme.accent)
          .accessibilityHidden(true)
        Text(section.title).font(.callout).lineLimit(1)
        Text(section.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Image(systemName: "arrow.up.forward")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .cardSurface(cornerRadius: Theme.Radius.medium)
    }
    .buttonStyle(.plain)
    .disabled(open == nil)
    .accessibilityLabel("Open subagent session \(section.title), \(section.summary)")
    .accessibilityIdentifier("open-\(section.id)")
  }
}

private struct FailureBanner: View {
  let message: String

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 4) {
        Text("The last turn failed").font(.callout.weight(.semibold))
        Text(message).font(.callout).textSelection(.enabled)
        Text(
          "Check the server or provider connection before trying again. Your conversation is kept."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.attention)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .cardSurface(cornerRadius: Theme.Radius.medium, tint: Theme.attention)
    .accessibilityIdentifier("turn-failure")
  }
}

/// A session-level error with optional dismiss and retry.
struct ErrorBanner: View {
  let message: String
  var dismiss: (@MainActor () -> Void)?
  var retry: (@MainActor () -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.failure)
        .accessibilityHidden(true)
      Text(message)
        .font(.callout)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      CopyButton(text: message, label: "Copy error")
      if let retry { Button("Retry", action: retry) }
      if let dismiss {
        Button("Dismiss", action: dismiss).buttonStyle(.borderless)
      }
    }
    .padding(12)
    .cardSurface(
      cornerRadius: Theme.Radius.medium, tint: Theme.failure, stroke: Theme.failure.opacity(0.3)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Error: \(message)")
    .accessibilityIdentifier("session-error")
  }
}
