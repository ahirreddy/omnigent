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
  /// How long the turn this answer settles worked ("Worked for 3s"), as the CLI's footer.
  var workedFor: TimeInterval?
}

/// A user or assistant message, as on the web: user messages in a neutral bubble on the right,
/// assistant prose without a bubble or name. Copy, Fork chat from here (assistant), Copy link and
/// the timestamp appear on hover or keyboard focus on Mac (always on the last answer while idle),
/// under the last answer on touch, and always in the context menu and as VoiceOver actions.
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
    // On touch only the latest answer keeps its row; the rest are a long press away, so no
    // copy button outlives its scrolled-away message.
    .messageActionsHost(
      row: row, actions: actions, pinned: decoration.showsActions,
      showsOnTouch: decoration.showsActions, focus: $actionsFocused)
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
        row: row, actions: actions, timestamp: decoration.timestamp, focus: $actionsFocused,
        overlaysGap: true)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(decoration.showsAvatar ? "\(row.author ?? "Someone") said" : "You said")
    .accessibilityIdentifier("message-\(row.id)")
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if row.text.isEmpty, row.isStreaming {
        TurnStatusRow {
          TypingIndicator()
        } label: {
          Text("Preparing a reply")
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
        TurnStatusRow {
          LiveIndicator()
        } label: {
          Text("Responding")
        }
      }
      if !row.isStreaming {
        if let workedFor = decoration.workedFor {
          // The actions share the footer's line, at its trailing edge, so they add no height.
          WorkedForLabel(duration: workedFor, finished: decoration.timestamp)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
              MessageActionRow(
                row: row, actions: actions, timestamp: decoration.timestamp,
                focus: $actionsFocused)
            }
        } else {
          MessageActionRow(
            row: row, actions: actions, timestamp: decoration.timestamp, focus: $actionsFocused,
            overlaysGap: true)
        }
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

/// Initials in a hashed color, for shared sessions and viewers. The initials are 11 pt bold, the
/// iOS minimum; every color keeps white text above 5:1.
struct AuthorAvatar: View {
  let name: String
  /// Initials to show instead of ones derived from `name`.
  var initials: String?
  var size: CGFloat = 24
  /// A viewer who has gone idle: grey instead of their color.
  var isIdle = false

  /// Darker than the system colors, which hold white text at 2.2:1 to 4.1:1.
  static let palette: [UInt32] = [
    0x2563C9, 0x7C3AED, 0xB8236A, 0xA8470F, 0x0F766E, 0x4F46E5, 0x2E7D32,
  ]
  static let idle: UInt32 = 0x5F6368

  var body: some View {
    Text(
      initials.map { $0.isEmpty ? "?" : String($0.prefix(2)).uppercased() } ?? Self.initials(name)
    )
    .font(.system(size: 11, weight: .bold, design: .rounded))
    .minimumScaleFactor(0.8)
    .lineLimit(1)
    .foregroundStyle(.white)
    .frame(width: size, height: size)
    .background(Color(hex: isIdle ? Self.idle : Self.color(for: name)), in: Circle())
    .help(name)
    .accessibilityLabel(isIdle ? "\(name), idle" : name)
  }

  /// Up to two initials, or "?".
  static func initials(_ text: String) -> String {
    let letters = text.split(whereSeparator: { " ._@".contains($0) }).prefix(2)
      .compactMap(\.first).map(String.init).joined().uppercased()
    return letters.isEmpty ? "?" : letters
  }

  /// A stable color for a name.
  static func color(for name: String) -> UInt32 {
    let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return palette[hash % palette.count]
  }
}

private struct InterruptedLabel: View {
  let rowID: String

  var body: some View {
    TurnStatusRow {
      Image(systemName: "stop.circle").accessibilityHidden(true)
    } label: {
      Text("Interrupted")
    }
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

/// A content part this client cannot render: one quiet line in the message's flow, with its
/// safe display text behind a disclosure when there is any.
struct UnsupportedContentView: View {
  let activity: Activity
  let rowID: String
  @State private var isExpanded = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Button {
        withAnimation(reduceMotion ? nil : Theme.Motion.disclosure) { isExpanded.toggle() }
      } label: {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Image(systemName: "eye.slash").accessibilityHidden(true)
          Text(Self.title(activity.title))
          if hasDetails {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .accessibilityHidden(true)
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!hasDetails)
      .accessibilityValue(hasDetails ? (isExpanded ? "Expanded" : "Collapsed") : "")
      .accessibilityIdentifier("unsupported-content-\(rowID)")
      if isExpanded {
        DetailSectionsView(sections: activity.details, rowID: rowID)
      }
    }
  }

  private var hasDetails: Bool { !activity.details.isEmpty }

  /// The core's generic title ("Message content") says nothing; say what happened instead.
  static func title(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed.caseInsensitiveCompare("Message content") == .orderedSame {
      return "Content this app can\u{2019}t show"
    }
    return "\(trimmed) \u{00B7} not shown in this app"
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
