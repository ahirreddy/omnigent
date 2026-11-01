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

/// How a message row is decorated: its timestamp, whether its actions stay visible, and the
/// shared-session author avatar.
nonisolated struct MessageDecoration: Hashable, Sendable {
  var timestamp: Date?
  var showsActions = false
  var showsAvatar = false
}

/// A user or assistant message, as on the web: user messages in a neutral bubble on the right,
/// assistant prose without a bubble or name. Copy, Fork from here (assistant), Copy link and the
/// timestamp appear on hover (always on the last answer while idle) and in the context menu.
struct MessageRowView: View, Equatable {
  let row: Row
  let decoration: MessageDecoration

  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.conversationActions) private var actions
  @State private var isHovered = false

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.decoration == rhs.decoration
  }

  var body: some View {
    Group {
      switch row.role {
      case .user: userMessage
      case .assistant, .tool: assistantMessage
      }
    }
    .onHover { isHovered = $0 }
    .contextMenu { MessageContextMenu(row: row, actions: actions) }
  }

  private var showsActions: Bool {
    #if os(macOS)
      decoration.showsActions || isHovered
    #else
      true
    #endif
  }

  private var userMessage: some View {
    VStack(alignment: .trailing, spacing: 4) {
      HStack(alignment: .top, spacing: 8) {
        Spacer(minLength: layoutWidth == .compact ? 32 : 120)
        VStack(alignment: .leading, spacing: 8) {
          if !row.text.isEmpty {
            MarkdownView(row.text, isStreaming: false)
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
          in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
            .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .frame(maxWidth: 640, alignment: .trailing)
        if decoration.showsAvatar, let author = row.author {
          AuthorAvatar(name: author)
        }
      }
      if row.interrupted { InterruptedLabel(rowID: row.id) }
      MessageActions(row: row, timestamp: decoration.timestamp, actions: actions)
        .opacity(showsActions ? 1 : 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(decoration.showsAvatar ? "\(row.author ?? "Someone") said" : "You said")
    .accessibilityIdentifier("message-\(row.id)")
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 6) {
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
      if row.interrupted { InterruptedLabel(rowID: row.id) }
      if !row.isStreaming {
        MessageActions(row: row, timestamp: decoration.timestamp, actions: actions)
          .opacity(showsActions ? 1 : 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-\(row.id)")
  }
}

/// Copy, Fork from here (assistant), Copy link, then the timestamp.
private struct MessageActions: View {
  let row: Row
  let timestamp: Date?
  let actions: ConversationActions

  var body: some View {
    HStack(spacing: 10) {
      CopyButton(text: row.text, label: "Copy", identifier: "message-copy-\(row.id)")
      if row.role == .assistant, let fork = actions.forkFrom {
        Button("Fork from here", systemImage: "arrow.triangle.branch") { fork(row) }
          .labelStyle(.iconOnly)
          .help("Fork from here")
          .accessibilityIdentifier("message-fork-\(row.id)")
      }
      if let url = actions.messageURL?(row) {
        Button("Copy link", systemImage: "link") { Pasteboard.copy(url.absoluteString) }
          .labelStyle(.iconOnly)
          .help("Copy link")
          .accessibilityIdentifier("message-link-\(row.id)")
      }
      if let timestamp {
        Text(MessageTimestamp.format(timestamp, now: Date()))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .font(.caption)
  }
}

/// The web's message timestamps: `h:mm AM` today, `Mon D, h:mm` otherwise, plus the year when it
/// differs.
nonisolated enum MessageTimestamp {
  static func format(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) {
      return date.formatted(date: .omitted, time: .shortened)
    }
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    let time = date.formatted(date: .omitted, time: .shortened)
    let year = sameYear ? "" : ", \(calendar.component(.year, from: date))"
    return "\(day), \(time)\(year)"
  }
}

/// Initials in a hashed color, for shared sessions.
struct AuthorAvatar: View {
  let name: String

  var body: some View {
    let initials = name.split(whereSeparator: { " ._@".contains($0) }).prefix(2)
      .compactMap(\.first).map(String.init).joined().uppercased()
    Text(initials.isEmpty ? "?" : initials)
      .font(.system(size: 10, weight: .bold, design: .rounded))
      .foregroundStyle(.white)
      .frame(width: 24, height: 24)
      .background(color, in: Circle())
      .help(name)
      .accessibilityLabel(name)
  }

  private var color: Color {
    let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
    let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return palette[hash % palette.count]
  }
}

private struct InterruptedLabel: View {
  let rowID: String

  var body: some View {
    Label("Interrupted", systemImage: "xmark")
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("message-interrupted-\(rowID)")
  }
}

private struct MessageContextMenu: View {
  let row: Row
  let actions: ConversationActions

  var body: some View {
    Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(row.text) }
      .disabled(row.text.isEmpty)
    if row.role == .assistant, !row.isStreaming, let fork = actions.forkFrom {
      Button("Fork from Here\u{2026}", systemImage: "arrow.triangle.branch") { fork(row) }
    }
    if let url = actions.messageURL?(row) {
      Button("Copy Link", systemImage: "link") { Pasteboard.copy(url.absoluteString) }
    }
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
  let open: (@MainActor (Attachment) -> Void)?

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
