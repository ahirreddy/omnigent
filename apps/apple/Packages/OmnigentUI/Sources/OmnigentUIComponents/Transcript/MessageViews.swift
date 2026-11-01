import OmnigentPlatform
import SwiftUI

extension EnvironmentValues {
  /// Conversation actions for the rows below; rows read them here so their own values stay
  /// comparable and unchanged rows skip re-rendering.
  @Entry var conversationActions = ConversationActions()
  /// The width class the components lay out for. Set by ``AdaptiveWidthReader`` or the host.
  @Entry var layoutWidth: LayoutWidth = .regular
}

/// The layout width class. On iOS it follows the horizontal size class; on macOS, the
/// container width (narrow windows and the compact gallery previews use `.compact`).
nonisolated public enum LayoutWidth: Hashable, Sendable {
  /// iPhone, Duo folded, slide-over and narrow Mac windows.
  case compact
  /// iPad, Duo unfolded and Mac.
  case regular
}

/// A user or assistant message.
struct MessageRowView: View, Equatable {
  let row: Row
  let showsAuthor: Bool

  @Environment(\.layoutWidth) private var layoutWidth

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.showsAuthor == rhs.showsAuthor
  }

  var body: some View {
    switch row.role {
    case .user: userMessage
    case .assistant, .tool: assistantMessage
    }
  }

  private var userMessage: some View {
    HStack {
      Spacer(minLength: layoutWidth == .compact ? 32 : 120)
      VStack(alignment: .trailing, spacing: 6) {
        if showsAuthor, let author = row.author, !author.isEmpty {
          Text(author).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
          if !row.text.isEmpty {
            Text(verbatim: row.text)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          AttachmentStrip(attachments: row.attachments)
          if let activity = row.activity {
            UnsupportedContentView(activity: activity, rowID: row.id)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          Theme.userBubble,
          in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
        if row.interrupted { StoppedLabel(rowID: row.id) }
      }
    }
    .contextMenu { MessageContextMenu(row: row) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("You said")
    .accessibilityIdentifier("message-\(row.id)")
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsAuthor {
        HStack(spacing: 6) {
          Text(row.agent ?? row.author ?? "Agent")
            .font(.subheadline.weight(.semibold))
          if row.isStreaming { LiveIndicator() }
        }
        .accessibilityElement(children: .combine)
      }
      if row.text.isEmpty, row.isStreaming {
        HStack(spacing: 8) {
          TypingIndicator()
          Text("Preparing a reply").font(.callout).foregroundStyle(.secondary)
        }
      } else {
        MarkdownView(row.text, isStreaming: row.isStreaming)
          .accessibilityIdentifier("message-text-\(row.id)")
      }
      AttachmentStrip(attachments: row.attachments)
      if let activity = row.activity { UnsupportedContentView(activity: activity, rowID: row.id) }
      if row.isStreaming, !showsAuthor, !row.text.isEmpty {
        HStack(spacing: 6) {
          LiveIndicator()
          Text("Replying").font(.caption).foregroundStyle(.secondary)
        }
      }
      if row.interrupted { StoppedLabel(rowID: row.id) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contextMenu { MessageContextMenu(row: row) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-\(row.id)")
  }
}

private struct StoppedLabel: View {
  let rowID: String

  var body: some View {
    Label("Stopped", systemImage: "stop.circle")
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("message-stopped-\(rowID)")
  }
}

private struct MessageContextMenu: View {
  let row: Row

  var body: some View {
    Button("Copy Text", systemImage: "doc.on.doc") { Pasteboard.copy(row.text) }
      .disabled(row.text.isEmpty)
    ShareLink(item: row.text) { Label("Share", systemImage: "square.and.arrow.up") }
      .disabled(row.text.isEmpty)
    Divider()
    Button("Copy Message ID", systemImage: "number") { Pasteboard.copy(row.id) }
  }
}

/// Attachment chips. Nothing is fetched; Open asks the host explicitly.
struct AttachmentStrip: View {
  let attachments: [Attachment]
  @Environment(\.conversationActions) private var actions

  var body: some View {
    if !attachments.isEmpty {
      FlowLayout(spacing: 6) {
        ForEach(attachments) { attachment in
          AttachmentChip(attachment: attachment, open: actions.openAttachment)
        }
      }
    }
  }
}

private struct AttachmentChip: View {
  let attachment: Attachment
  let open: ((Attachment) -> Void)?

  var body: some View {
    Button {
      open?(attachment)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text(attachment.title).font(.callout).lineLimit(1)
          Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .cardSurface(cornerRadius: Theme.Radius.medium)
    }
    .buttonStyle(.plain)
    .disabled(open == nil || (attachment.reference == nil && !attachment.isEmbedded))
    .help(attachment.reference ?? attachment.title)
    .contextMenu {
      if let reference = attachment.reference {
        Button("Copy Reference", systemImage: "doc.on.doc") { Pasteboard.copy(reference) }
      }
    }
    .accessibilityLabel("\(attachment.kind.rawValue.capitalized) attachment, \(attachment.title)")
    .accessibilityHint(open == nil ? "" : "Opens a preview")
    .accessibilityIdentifier("attachment-\(attachment.id)")
  }

  private var subtitle: String {
    if attachment.isEmbedded { return "Embedded, not kept" }
    return attachment.mimeType ?? attachment.kind.rawValue.capitalized
  }

  private var symbol: String {
    switch attachment.kind {
    case .image: "photo"
    case .file: "doc"
    case .audio: "waveform"
    case .video: "film"
    }
  }
}

/// A content part this client cannot render, shown through its safe display text.
struct UnsupportedContentView: View {
  let activity: Activity
  let rowID: String
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      DetailSectionsView(sections: activity.details, rowID: rowID)
        .padding(.top, 6)
    } label: {
      Label(activity.title, systemImage: "questionmark.square.dashed")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background {
      RoundedRectangle(cornerRadius: Theme.Radius.medium)
        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .foregroundStyle(.tertiary)
    }
  }
}

/// A simple wrapping layout for chips.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var cursorX: CGFloat = 0
    var cursorY: CGFloat = 0
    var lineHeight: CGFloat = 0
    var maxX: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if cursorX > 0, cursorX + size.width > width {
        cursorX = 0
        cursorY += lineHeight + spacing
        lineHeight = 0
      }
      cursorX += size.width + spacing
      maxX = max(maxX, cursorX - spacing)
      lineHeight = max(lineHeight, size.height)
    }
    return CGSize(width: maxX, height: cursorY + lineHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var cursorX = bounds.minX
    var cursorY = bounds.minY
    var lineHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if cursorX > bounds.minX, cursorX + size.width > bounds.maxX {
        cursorX = bounds.minX
        cursorY += lineHeight + spacing
        lineHeight = 0
      }
      subview.place(at: CGPoint(x: cursorX, y: cursorY), proposal: ProposedViewSize(size))
      cursorX += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
  }
}
