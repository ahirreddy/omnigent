import SwiftUI

/// The row's kind at a glance, as the web's tiles: a raised hand for requests, the author's
/// initials for comments, and a check or an alert for finished sessions.
struct InboxKindTile: View {
  let item: InboxItem

  var body: some View {
    if let comment = item.comment {
      AuthorAvatar(name: comment.author, size: 32)
    } else {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(tone)
        .frame(width: 32, height: 32)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .accessibilityHidden(true)
    }
  }

  private var symbol: String {
    switch item.kind {
    case .approval, .question: "hand.raised"
    case .comment: "text.bubble"
    case .unread: item.isError ? "exclamationmark.circle" : "checkmark.circle"
    }
  }

  private var tone: ThemeColor {
    switch item.kind {
    case .approval, .question: Theme.warning
    case .comment, .unread: item.isError ? Theme.failure : Theme.secondary
    }
  }
}

/// Opens the agent's whole reply when the row's preview is cut from it, rendered as the chat
/// renders it.
struct FullReplyButton: View {
  let text: String
  let itemID: String
  @State private var isPresented = false

  var body: some View {
    Button("Show full reply") { isPresented = true }
      .buttonStyle(.borderless)
      .font(.callout)
      .accessibilityIdentifier("inbox-full-reply-\(itemID)")
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        ScrollView {
          MarkdownView(text)
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560)
        .frame(maxHeight: 480)
        .accessibilityIdentifier("inbox-full-reply-text-\(itemID)")
      }
  }
}
