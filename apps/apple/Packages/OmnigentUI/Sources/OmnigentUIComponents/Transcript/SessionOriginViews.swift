import SwiftUI

/// A message another session sent with `sys_session_message`, as the web shows it by default:
/// collapsed to "From @sender" and its first line until the reader opens it.
nonisolated enum SessionOrigin {
  /// Where the reader's open or closed choice for message `rowID` is kept.
  static func disclosureKey(_ rowID: String) -> String { "origin-\(rowID)" }

  /// The first non-blank line of `text`, which a collapsed message shows.
  static func preview(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map(String.init) ?? ""
  }

  /// The sender's name as the line shows it: its title, "Untitled session" for a blank one.
  static func name(_ title: String?) -> String? {
    guard let title else { return nil }
    return title.isEmpty ? "Untitled session" : title
  }
}

/// "From @sender" over a message another session sent (the web's `SessionMessageOriginLine`).
/// The sender opens its session; one this app can't name reads "another session".
struct SessionOriginLine: View {
  let sessionID: String
  @Environment(\.conversationActions) private var actions

  var body: some View {
    HStack(spacing: Theme.Spacing.tiny) {
      Image(systemName: "arrow.turn.down.right")
        .font(.caption2)
        .accessibilityHidden(true)
      Text("From")
      if let name = SessionOrigin.name(actions.sessionTitle?(sessionID)) {
        if let open = actions.openSession {
          Button("@\(name)") { open(sessionID) }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.link)
            .lineLimit(1)
            .help("Open \(name)")
            .accessibilityIdentifier("message-origin-open-\(sessionID)")
        } else {
          Text("@\(name)").lineLimit(1)
        }
      } else {
        Text("another session")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("message-origin")
  }
}

/// The line over an open message from another session: its sender, and the button that
/// collapses it again.
struct SessionOriginHeader: View {
  let sessionID: String
  let collapse: @MainActor () -> Void

  var body: some View {
    HStack(spacing: Theme.Spacing.medium) {
      SessionOriginLine(sessionID: sessionID)
      Button(action: collapse) {
        Image(systemName: "chevron.up")
          .font(.caption.weight(.semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Collapse message")
      .accessibilityIdentifier("collapse-session-message")
    }
  }
}

/// A collapsed message from another session (the web's `CollapsedSessionMessage`): its sender
/// and first line, opening on a click.
struct CollapsedSessionMessage: View {
  let sessionID: String
  let preview: String
  let expand: @MainActor () -> Void

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      SessionOriginLine(sessionID: sessionID)
      Button(action: expand) {
        HStack(spacing: Theme.Spacing.tiny) {
          Text(preview)
            .lineLimit(1)
            .truncationMode(.tail)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Show message")
      .accessibilityValue(preview)
      .accessibilityIdentifier("expand-session-message")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("collapsed-session-message")
  }
}

extension MessageRowView {
  /// A message from another session starts collapsed to its sender and first line.
  var isCollapsedOrigin: Bool {
    row.originSessionId != nil
      && !(disclosure.choice(SessionOrigin.disclosureKey(row.id)) ?? false)
  }

  /// The user bubble's content: a message from another session collapsed, else its sender, its
  /// attachments, its text and the content this app can't show.
  @ViewBuilder var userBubbleContent: some View {
    if let origin = row.originSessionId, isCollapsedOrigin {
      CollapsedSessionMessage(sessionID: origin, preview: SessionOrigin.preview(row.text)) {
        disclosure.choose(true, for: SessionOrigin.disclosureKey(row.id))
      }
    } else {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        if let origin = row.originSessionId {
          SessionOriginHeader(sessionID: origin) {
            disclosure.choose(false, for: SessionOrigin.disclosureKey(row.id))
          }
        }
        // Attachments lead the message, as on the web.
        AttachmentStrip(attachments: row.attachments)
        if let reply = QuestionReplyMarkdown.text(row.questionReplies) {
          QuestionReplyBody(source: reply)
        } else if !row.text.isEmpty {
          UserPromptBody(
            text: row.text, showsDesignRequest: row.originSessionId == nil,
            tintsCommand: row.originSessionId == nil && row.attachments.isEmpty)
        }
        if let activity = row.activity {
          UnsupportedContentView(activity: activity, rowID: row.id)
        }
      }
    }
  }

  /// Who VoiceOver says sent the message.
  var speaker: String {
    if row.originSessionId != nil { return "Another session said" }
    return decoration.showsAvatar ? "\(row.author ?? "Someone") said" : "You said"
  }
}
