import SwiftUI

extension EnvironmentValues {
  /// How ``MarkdownView`` renders agent output; rich everywhere except where a transcript row
  /// opts in with ``SwiftUICore/View/agentOutputRendering()``.
  @Entry var markdownOutputRendering = OutputRendering.rich
}

extension View {
  /// Renders the ``MarkdownView``s below with the transcript's Output rendering setting. Only
  /// agent output opts in; plans, decisions and other rich content stay rich.
  func agentOutputRendering() -> some View { modifier(AgentOutputRendering()) }
}

private struct AgentOutputRendering: ViewModifier {
  @Environment(\.transcriptAppearance) private var appearance

  func body(content: Content) -> some View {
    content.environment(\.markdownOutputRendering, appearance.outputRendering)
  }
}

/// Agent output in the configured rendering: Plain source, Styled terminal markdown, or the
/// chat's rich markdown. Streaming text ends with a block cursor.
struct CLIOutputText: View {
  let text: String
  let isStreaming: Bool
  @Environment(\.transcriptAppearance) private var appearance
  @Environment(\.cliPalette) private var palette

  var body: some View {
    switch appearance.outputRendering {
    case .plain: CLISourceText(text: text, isStreaming: isStreaming)
    case .styled: CLIStyledMarkdown(text: text, isStreaming: isStreaming)
    case .rich:
      VStack(alignment: .leading, spacing: 0) {
        MarkdownView(text, isStreaming: isStreaming).foregroundStyle(palette.body.color)
        if isStreaming {
          Text(CLICursor.attributed(palette)).cliFont().accessibilityHidden(true)
        }
      }
    }
  }
}

/// A user message in CLI style: a full-width band with a dim `›` prompt and the text as typed.
struct CLIUserBand: View, Equatable {
  let row: Row
  let decoration: MessageDecoration
  @Environment(\.conversationActions) private var actions
  @Environment(\.cliPalette) private var palette
  @FocusState private var actionsFocused: Bool
  @RowDisclosure private var disclosure

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.decoration == rhs.decoration
  }

  /// A message from another session starts collapsed to its sender and first line, as in chat.
  private var isCollapsedOrigin: Bool {
    row.originSessionId != nil
      && !(disclosure.choice(SessionOrigin.disclosureKey(row.id)) ?? false)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      if let origin = row.originSessionId {
        if isCollapsedOrigin {
          CollapsedSessionMessage(sessionID: origin, preview: SessionOrigin.preview(row.text)) {
            disclosure.choose(true, for: SessionOrigin.disclosureKey(row.id))
          }
        } else {
          SessionOriginHeader(sessionID: origin) {
            disclosure.choose(false, for: SessionOrigin.disclosureKey(row.id))
          }
        }
      }
      if !row.text.isEmpty, !isCollapsedOrigin {
        CLIUserText(
          text: UserPrompt.source(row),
          tintsCommand: row.originSessionId == nil && row.attachments.isEmpty
            && QuestionReplyMarkdown.text(row.questionReplies) == nil)
      }
      AttachmentStrip(attachments: row.attachments)
      if let activity = row.activity {
        UnsupportedContentView(activity: activity, rowID: row.id)
      }
      if row.interrupted { CLIInterruptedLine(rowID: row.id) }
    }
    .cliMarker(Text(verbatim: "\u{203A}").foregroundStyle(palette.prompt.color))
    .overlay(alignment: .topTrailing) {
      CLIActionCluster {
        MessageActionRow(
          row: row, actions: actions, timestamp: decoration.timestamp, focus: $actionsFocused)
      }
      .offset(y: -CLIMetrics.bandPadding)
    }
    .transcriptColumn()
    .padding(.vertical, CLIMetrics.bandPadding)
    .background(palette.band.color)
    .messageActionsHost(
      row: row, actions: actions, pinned: false, showsOnTouch: decoration.showsActions,
      focus: $actionsFocused
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(speaker)
    .accessibilityIdentifier("message-\(row.id)")
  }

  /// Who VoiceOver says sent the message.
  private var speaker: String {
    if row.originSessionId != nil { return "Another session said" }
    return decoration.showsAvatar ? "\(row.author ?? "Someone") said" : "You said"
  }
}

/// An assistant message in CLI style: a `•` bullet in the gutter, then the output.
struct CLIAssistantBlock: View, Equatable {
  let row: Row
  let decoration: MessageDecoration
  @Environment(\.conversationActions) private var actions
  @Environment(\.cliPalette) private var palette
  @FocusState private var actionsFocused: Bool
  private(set) var size = CLIFontSize()

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.row == rhs.row && lhs.decoration == rhs.decoration
  }

  var body: some View {
    VStack(alignment: .leading, spacing: size.line) {
      if row.text.isEmpty, row.isStreaming {
        Text(CLICursor.attributed(palette))
          .cliFont()
          .accessibilityLabel("Preparing a reply")
      } else {
        CLIOutputText(text: row.text, isStreaming: row.isStreaming)
          .accessibilityIdentifier("message-text-\(row.id)")
      }
      AttachmentStrip(attachments: row.attachments)
      if let activity = row.activity { UnsupportedContentView(activity: activity, rowID: row.id) }
      if row.interrupted { CLIInterruptedLine(rowID: row.id) }
      #if !os(macOS)
        // Touch shows the latest answer's actions under it, as chat does; the turn's footer
        // line already gives the time.
        if !row.isStreaming {
          MessageActionRow(row: row, actions: actions, focus: $actionsFocused)
        }
      #endif
    }
    .cliMarker(Text(verbatim: "\u{2022}").foregroundStyle(palette.bullet.color))
    #if os(macOS)
      .overlay(alignment: .topTrailing) {
        if !row.isStreaming {
          CLIActionCluster {
            MessageActionRow(
              row: row, actions: actions, timestamp: decoration.timestamp, focus: $actionsFocused)
          }
        }
      }
    #endif
    .transcriptColumn()
    .messageActionsHost(
      row: row, actions: actions, pinned: false, showsOnTouch: decoration.showsActions,
      focus: $actionsFocused
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message-\(row.id)")
  }
}

/// "Interrupted", as a dim terminal line.
struct CLIInterruptedLine: View {
  let rowID: String
  @Environment(\.cliPalette) private var palette

  var body: some View {
    Text(verbatim: "\u{23BF} Interrupted")
      .foregroundStyle(palette.dim.color)
      .cliFont()
      .accessibilityLabel("Interrupted")
      .accessibilityIdentifier("message-interrupted-\(rowID)")
  }
}
