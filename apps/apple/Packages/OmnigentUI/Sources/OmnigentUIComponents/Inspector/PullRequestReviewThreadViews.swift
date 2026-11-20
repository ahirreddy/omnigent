public import SwiftUI

/// The review conversations on one line of the diff, or a file's that no line holds, with the
/// new conversation being written there.
public struct PullRequestReviewThreadsView: View {
  private let threads: [PullRequestReviewThreadState]
  private let newThread: PullRequestNewThreadState?
  private let localComments: [PullRequestLocalCommentState]
  private let actions: PullRequestReviewActions
  private let localActions: PullRequestLocalCommentActions

  /// Creates the view.
  /// - Parameters:
  ///   - threads: The conversations.
  ///   - newThread: The one being written here.
  ///   - localComments: Local comments for the agent here.
  ///   - actions: What they can do.
  ///   - localActions: What the local comments can do.
  public init(
    threads: [PullRequestReviewThreadState], newThread: PullRequestNewThreadState? = nil,
    localComments: [PullRequestLocalCommentState] = [], actions: PullRequestReviewActions,
    localActions: PullRequestLocalCommentActions = PullRequestLocalCommentActions()
  ) {
    self.threads = threads
    self.newThread = newThread
    self.localComments = localComments
    self.actions = actions
    self.localActions = localActions
  }

  /// The view.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if let newThread {
        PullRequestNewThreadCard(state: newThread, actions: actions)
      }
      if !localComments.isEmpty {
        PullRequestLocalCommentsView(comments: localComments, actions: localActions)
      }
      ForEach(threads) { thread in
        PullRequestReviewThreadCard(thread: thread, actions: actions)
      }
    }
  }
}

/// One conversation: a header that folds it, its comments, older ones on request, and a reply.
struct PullRequestReviewThreadCard: View {
  let thread: PullRequestReviewThreadState
  let actions: PullRequestReviewActions

  /// Folded or open as the person chose; until then, by the conversation's state.
  private enum Fold { case automatic, open, folded }

  @State private var fold = Fold.automatic
  @Environment(\.openURL) private var openURL

  /// A resolved conversation starts folded unless a reply is being written.
  private var isExpanded: Bool {
    switch fold {
    case .automatic: !thread.resolved || !thread.reply.isEmpty
    case .open: true
    case .folded: false
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      if isExpanded {
        Divider()
        if let context = thread.originalContext, !context.isEmpty {
          DisclosureGroup("Original code context") {
            Text(context)
              .font(.caption.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.caption)
          .padding(Theme.Spacing.small)
          Divider()
        }
        ForEach(thread.comments) { comment in
          commentRow(comment)
          Divider()
        }
        footer
      }
    }
    .cardSurface(cornerRadius: Theme.Radius.small)
    .accessibilityIdentifier("pr-review-thread-\(thread.id)")
  }

  private var header: some View {
    Button {
      fold = isExpanded ? .folded : .open
    } label: {
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.semibold))
          .accessibilityHidden(true)
        Image(systemName: "text.bubble").accessibilityHidden(true)
        Text(thread.lineLabel).lineLimit(1)
        Spacer(minLength: 0)
        if thread.outdated {
          Label("Outdated", systemImage: "clock.arrow.circlepath").foregroundStyle(.secondary)
        }
        if thread.resolved {
          Label("Resolved", systemImage: "checkmark.circle").foregroundStyle(ThemeColor.success)
        }
        Text("\(thread.comments.count)\(thread.hasOlderComments ? "+" : "")")
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .font(.callout)
      .padding(Theme.Spacing.small)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }

  private func commentRow(_ comment: PullRequestReviewCommentRow) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      HStack(spacing: Theme.Spacing.small) {
        Text(comment.author).font(.caption.weight(.semibold))
        if let date = comment.date {
          Text(Theme.relativeDate(date, now: .now))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(date.formatted(date: .abbreviated, time: .shortened))
        }
        Spacer(minLength: 0)
        if let url = comment.url {
          Button {
            openURL(url)
          } label: {
            Image(systemName: "arrow.up.right.square").accessibilityLabel("Open review comment")
          }
          .buttonStyle(.borderless)
          .help("Open review comment")
        }
      }
      if comment.hidden {
        Text("Comment hidden on GitHub.").font(.callout).foregroundStyle(.secondary)
      } else {
        let parts = Array(PullRequestReviewBodyPart.split(comment.body).enumerated())
        ForEach(parts, id: \.offset) { item in
          switch item.element {
          case .markdown(let text): MarkdownView(text).textSelection(.enabled)
          case .suggestion(let replacement):
            PullRequestSuggestionView(source: thread.suggestionSource, replacement: replacement)
          }
        }
      }
    }
    .padding(Theme.Spacing.small)
  }

  @ViewBuilder private var footer: some View {
    if let warning = thread.warning {
      Text(warning).font(.callout).foregroundStyle(.secondary).padding(Theme.Spacing.small)
    }
    if thread.hasOlderComments, let loadOlder = actions.loadOlder {
      Button("Load more replies") { loadOlder(thread.id) }
        .buttonStyle(.borderless)
        .padding(Theme.Spacing.small)
    }
    if thread.canReply, let reply = actions.reply {
      PullRequestCommentField(
        prompt: "Write a reply\u{2026}", text: thread.reply, isBusy: actions.isBusy,
        problem: nil,
        destination: .provider(account: actions.account, providerName: actions.providerName),
        setText: { actions.setReply?(thread.id, $0) }, post: { reply(thread.id) },
        postTitle: "Reply")
    } else if !thread.reply.isEmpty {
      Text("Your reply draft is saved. Replying is unavailable with the current permissions.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(Theme.Spacing.small)
    }
  }
}

/// A new conversation on the lines chosen in the diff.
struct PullRequestNewThreadCard: View {
  let state: PullRequestNewThreadState
  let actions: PullRequestReviewActions

  /// Posting is possible where the comment goes now.
  private var canPost: Bool {
    !state.isStale && (state.toAgent ? state.offersAgent : state.offersProvider)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Theme.Spacing.small) {
        Label("Comment on \(state.lineLabel.lowercased())", systemImage: "plus.bubble")
          .font(.callout)
        Spacer(minLength: 0)
        if let setToAgent = actions.setNewToAgent, state.offersAgent {
          Picker(
            "Comment destination",
            selection: Binding(get: { state.toAgent }, set: { setToAgent($0) })
          ) {
            Text("GitHub").tag(false)
              .help("Post a review comment on the GitHub pull request.")
            Text("Agent").tag(true)
              .help("Leave a comment for your agent in this session.")
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .disabled(actions.isBusy || !state.offersProvider)
          .accessibilityIdentifier("pr-comment-destination")
        }
      }
      .padding(Theme.Spacing.small)
      if state.isStale {
        note(
          "The pull request changed. Your draft is saved; select its lines again before posting.")
      } else if !canPost {
        note("Your draft is saved. Commenting is currently unavailable.")
      }
      Divider()
      PullRequestCommentField(
        prompt: state.toAgent ? "Leave a comment for your agent" : "Leave a comment",
        text: state.body, isBusy: actions.isBusy, problem: state.problem,
        destination: state.toAgent
          ? .agent : .newThread(account: actions.account, providerName: actions.providerName),
        setText: { actions.setNewBody?($0) }, post: canPost ? actions.postNew : nil,
        postTitle: "Comment", cancel: actions.cancelNew)
    }
    // The conversation being written is edged in the focus color.
    .cardSurface(cornerRadius: Theme.Radius.small, stroke: ThemeColor.focus)
    .accessibilityIdentifier("pr-new-review-thread")
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.Spacing.small)
      .padding(.bottom, Theme.Spacing.small)
  }
}
