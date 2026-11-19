import SwiftUI

/// The Comments tab: the PR's conversation comments with its commits and force pushes in one
/// chronological feed, as the web's `PullRequestCommentsTab`, and a field that posts a comment.
struct PullRequestCommentsView: View {
  let state: PullRequestDetailViewState
  let extras: PullRequestPanelExtras
  let open: (@MainActor (URL) -> Void)?

  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
          notes
          ForEach(state.feed) { entry in
            switch entry {
            case .comment(let comment):
              PullRequestCommentCard(
                comment: comment, providerName: state.providerName, open: open)
            case .event(let event):
              PullRequestTimelineRowView(
                event: event, providerName: state.providerName, open: open)
            }
          }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .defaultScrollAnchor(.bottom)
      if state.canComment, let post = extras.actions.comment {
        Divider()
        composer(post)
      }
    }
  }

  @ViewBuilder private var notes: some View {
    if state.commentsPartial {
      Text("Some comments are unavailable.").font(.callout).foregroundStyle(.secondary)
    }
    if state.timelinePartial {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Text("Some commit and push history is unavailable.")
        if let url = URL(string: state.url) {
          Button("View on \(state.providerName)") { open?(url) }
            #if os(macOS)
              .buttonStyle(.link)
            #else
              .buttonStyle(.borderless)
            #endif
        }
      }
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    if state.comments.isEmpty, state.timeline.isEmpty, !state.commentsPartial,
      !state.timelinePartial
    {
      Text("No comments yet.").font(.callout).foregroundStyle(.secondary)
    }
  }

  private func composer(
    _ post: @escaping @MainActor (String, @escaping @MainActor (Bool) -> Void) -> Void
  ) -> some View {
    HStack(alignment: .bottom, spacing: Theme.Spacing.small) {
      TextField("Leave a comment", text: $draft, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...6)
        .accessibilityIdentifier("pr-comment")
      Button("Comment") {
        let body = draft
        post(body) { posted in
          if posted, draft == body { draft = "" }
        }
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(extras.isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(Theme.Spacing.small)
  }
}

/// One comment: author, when, the Markdown body, and a link to it on the provider.
private struct PullRequestCommentCard: View {
  let comment: PullRequestCommentRow
  let providerName: String
  let open: (@MainActor (URL) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      HStack(spacing: Theme.Spacing.small) {
        Text(comment.author).font(.callout.weight(.semibold))
        if let date = comment.date {
          Text(Theme.relativeDate(date, now: .now))
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(date.formatted(date: .abbreviated, time: .shortened))
        }
        Spacer(minLength: 0)
        if let url = comment.url {
          Button {
            open?(url)
          } label: {
            Image(systemName: "arrow.up.right.square")
              .accessibilityLabel("Open on \(providerName)")
          }
          .buttonStyle(.borderless)
          .help("Open on \(providerName)")
        }
      }
      MarkdownView(comment.body).textSelection(.enabled)
    }
    .padding(Theme.Spacing.small)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      ThemeColor.hover, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
  }
}

/// A commit or force push: "ann committed abc1234", or "ann force-pushed from abc1234 to
/// def5678", with the commit's message beneath, as the web's `PullRequestTimelineRow`.
struct PullRequestTimelineRowView: View {
  let event: PullRequestTimelineRow
  let providerName: String
  let open: (@MainActor (URL) -> Void)?

  private var forcePush: Bool {
    if case .forcePush = event.kind { return true }
    return false
  }

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.small) {
      Image(systemName: forcePush ? "arrow.triangle.branch" : "smallcircle.filled.circle")
        .frame(width: 16)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.extraSmall) {
          Text(event.author).foregroundStyle(.primary).fontWeight(.medium)
          Text(forcePush ? "force-pushed" : "committed")
          if case .forcePush(let previous?) = event.kind {
            Text("from")
            Text(Self.short(previous)).monospaced().help(previous)
          }
          if forcePush { Text(event.sha == nil ? "the branch" : "to") }
          commit
          Spacer(minLength: Theme.Spacing.small)
          if let date = event.date {
            Text(Theme.relativeDate(date, now: .now))
              .help(date.formatted(date: .abbreviated, time: .shortened))
          }
        }
        if let message = event.message {
          Text(message).lineLimit(1).truncationMode(.tail).help(message)
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, Theme.Spacing.small)
    .padding(.vertical, Theme.Spacing.extraSmall)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var commit: some View {
    if let url = event.url {
      Button(event.sha.map(Self.short) ?? "View event") { open?(url) }
        #if os(macOS)
          .buttonStyle(.link)
        #else
          .buttonStyle(.borderless)
        #endif
        .monospaced()
        .help("Open on \(providerName)")
    } else if let sha = event.sha {
      Text(Self.short(sha)).monospaced().help(sha)
    }
  }

  /// The first seven characters, as the provider abbreviates a commit.
  static func short(_ sha: String) -> String { String(sha.prefix(7)) }
}
