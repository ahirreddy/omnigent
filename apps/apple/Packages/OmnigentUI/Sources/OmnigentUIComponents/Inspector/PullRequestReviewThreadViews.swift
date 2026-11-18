public import SwiftUI

/// The review conversations on one line of the diff, or a file's that no line holds, with the
/// new conversation being written there.
public struct PullRequestReviewThreadsView: View {
  private let threads: [PullRequestReviewThreadState]
  private let newThread: PullRequestNewThreadState?
  private let actions: PullRequestReviewActions

  /// Creates the view.
  /// - Parameters:
  ///   - threads: The conversations.
  ///   - newThread: The one being written here.
  ///   - actions: What they can do.
  public init(
    threads: [PullRequestReviewThreadState], newThread: PullRequestNewThreadState? = nil,
    actions: PullRequestReviewActions
  ) {
    self.threads = threads
    self.newThread = newThread
    self.actions = actions
  }

  /// The view.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      ForEach(threads) { thread in
        PullRequestReviewThreadCard(thread: thread, actions: actions)
      }
      if let newThread {
        PullRequestNewThreadCard(state: newThread, actions: actions)
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
    .background(
      ThemeColor.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        .strokeBorder(.separator)
    }
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
        if thread.outdated { Text("Outdated").foregroundStyle(.secondary) }
        if thread.resolved { Text("Resolved").foregroundStyle(.secondary) }
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
        MarkdownView(comment.body).textSelection(.enabled)
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
      PullRequestReviewField(
        prompt: "Reply", text: thread.reply, isBusy: actions.isBusy,
        problem: nil, setText: { actions.setReply?(thread.id, $0) },
        post: { reply(thread.id) }, postTitle: "Reply", cancel: nil)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Label("Comment on \(state.lineLabel.lowercased())", systemImage: "plus.bubble")
        .font(.callout)
        .padding(Theme.Spacing.small)
      Divider()
      PullRequestReviewField(
        prompt: "Leave a comment", text: state.body, isBusy: actions.isBusy,
        problem: state.problem, setText: { actions.setNewBody?($0) },
        post: actions.postNew, postTitle: "Comment", cancel: actions.cancelNew)
    }
    .background(
      ThemeColor.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        .strokeBorder(Color.accentColor.opacity(0.6))
    }
    .accessibilityIdentifier("pr-new-review-thread")
  }
}

/// The field a reply or a new conversation is written in.
private struct PullRequestReviewField: View {
  let prompt: String
  let text: String
  let isBusy: Bool
  let problem: String?
  let setText: @MainActor (String) -> Void
  let post: (@MainActor () -> Void)?
  let postTitle: String
  let cancel: (@MainActor () -> Void)?

  private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      TextField(prompt, text: Binding(get: { text }, set: { setText($0) }), axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...8)
        .disabled(isBusy)
      if let problem {
        Text(problem).font(.caption).foregroundStyle(Theme.failure)
      }
      HStack {
        Spacer(minLength: 0)
        if let cancel {
          Button("Cancel", action: cancel).disabled(isBusy)
        }
        if let post {
          Button(postTitle, action: post)
            .disabled(isBusy || blank || problem != nil)
        }
      }
    }
    .padding(Theme.Spacing.small)
  }
}
