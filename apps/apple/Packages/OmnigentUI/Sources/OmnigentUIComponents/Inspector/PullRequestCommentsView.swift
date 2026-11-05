import SwiftUI

/// The Comments tab: the PR's conversation comments in order, and a field that posts one.
struct PullRequestCommentsView: View {
  let state: PullRequestDetailViewState
  let extras: PullRequestPanelExtras
  let open: (@MainActor (URL) -> Void)?

  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
          if state.commentsPartial {
            Text("Some comments are unavailable.").font(.callout).foregroundStyle(.secondary)
          }
          if state.comments.isEmpty, !state.commentsPartial {
            Text("No comments yet.").font(.callout).foregroundStyle(.secondary)
          }
          ForEach(state.comments) { comment in
            PullRequestCommentCard(comment: comment, providerName: state.providerName, open: open)
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
