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
/// assistant prose without a bubble or name. Copy, Fork chat from here (assistant), Copy link and
/// the timestamp appear on hover or keyboard focus on Mac (always on the last answer while idle),
/// under answers on touch, and always in the context menu and as VoiceOver actions.
struct MessageRowView: View, Equatable {
  let row: Row
  let decoration: MessageDecoration

  @Environment(\.layoutWidth) private var layoutWidth
  @Environment(\.conversationActions) private var actions
  @FocusState private var actionsFocused: Bool

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
    // On touch, answers keep their row as in ChatGPT; a user message's is a long press away.
    .messageActionsHost(
      row: row, actions: actions, pinned: decoration.showsActions,
      showsOnTouch: row.role != .user, focus: $actionsFocused)
  }

  private var userMessage: some View {
    VStack(alignment: .trailing, spacing: Theme.Spacing.extraSmall) {
      HStack(alignment: .top, spacing: Theme.Spacing.small) {
        Spacer(
          minLength: layoutWidth == .compact ? Theme.Spacing.extraLarge : Theme.Spacing.section)
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          if !row.text.isEmpty {
            MarkdownView(row.text, isStreaming: false)
              .environment(\.markdownFillsWidth, false)
              .fixedSize(horizontal: false, vertical: true)
          }
          AttachmentStrip(attachments: row.attachments)
          if let activity = row.activity {
            UnsupportedContentView(activity: activity, rowID: row.id)
          }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
        .background(
          Theme.userBubble,
          in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
            .strokeBorder(ThemeColor.border, lineWidth: 0.5)
        }
        .frame(maxWidth: Theme.userMessageWidth, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        if decoration.showsAvatar, let author = row.author {
          AuthorAvatar(name: author)
        }
      }
      if row.interrupted { InterruptedLabel(rowID: row.id) }
      MessageActionRow(
        row: row, actions: actions, timestamp: decoration.timestamp, focus: $actionsFocused)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(decoration.showsAvatar ? "\(row.author ?? "Someone") said" : "You said")
    .accessibilityIdentifier("message-\(row.id)")
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if row.text.isEmpty, row.isStreaming {
        HStack(spacing: Theme.Spacing.small) {
          TypingIndicator()
          Text("Preparing a reply").font(.callout).foregroundStyle(.secondary)
        }
      } else {
        MarkdownView(row.text, isStreaming: row.isStreaming)
          .agentOutputRendering()
          .accessibilityIdentifier("message-text-\(row.id)")
      }
      AttachmentStrip(attachments: row.attachments)
      if let activity = row.activity { UnsupportedContentView(activity: activity, rowID: row.id) }
      if row.interrupted { InterruptedLabel(rowID: row.id) }
      if row.isStreaming, !row.text.isEmpty {
        HStack(spacing: Theme.Spacing.small) {
          LiveIndicator()
          Text("Responding").font(Theme.Typography.section).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }
      if !row.isStreaming {
        MessageActionRow(
          row: row, actions: actions, timestamp: decoration.timestamp, focus: $actionsFocused)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-\(row.id)")
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
    Label("Interrupted", systemImage: "stop.circle")
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityIdentifier("message-interrupted-\(rowID)")
  }
}

/// Attachment chips. Nothing is fetched; Open asks the host explicitly.
struct AttachmentStrip: View {
  let attachments: [Attachment]
  @Environment(\.conversationActions) private var actions

  var body: some View {
    if !attachments.isEmpty {
      FlowLayout(spacing: Theme.Spacing.small) {
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
      HStack(spacing: Theme.Spacing.small) {
        Image(systemName: symbol)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 0) {
          Text(attachment.title).font(.callout).lineLimit(1)
          Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
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
        .padding(.top, Theme.Spacing.small)
    } label: {
      Label(activity.title, systemImage: "questionmark.square.dashed")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .padding(Theme.Spacing.medium)
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
      let size = subview.sizeThatFits(
        ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
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
      let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
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
