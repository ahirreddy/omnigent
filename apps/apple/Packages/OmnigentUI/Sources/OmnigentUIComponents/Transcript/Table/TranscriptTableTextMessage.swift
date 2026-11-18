#if os(macOS) || os(iOS)
  import SwiftUI

  /// A settled chat message a text cell draws in AppKit (``TranscriptTableTextCell``): an answer
  /// or a user's prompt as TextKit text runs, with the blocks only SwiftUI draws (math, a
  /// diagram, an image, a wide table) hosted between them, and the parts beside the text that
  /// SwiftUI draws (attachments, mentions, a long prompt's toggle, content this app can't show,
  /// the Interrupted line) hosted where the message row stacks them, and a shared session
  /// author's avatar beside their prompt. iPhone and iPad text rows
  /// (``TranscriptCollectionTextView``) draw those that are one text run.
  struct TranscriptTableTextMessage {
    enum Role {
      case user
      case answer
    }

    let role: Role
    let row: Row
    let decoration: MessageDecoration
    /// The markdown shown: the answer's text, or the prompt's without its mentions.
    let markdown: String
    let split: MessageTextSplit
    /// What the message stacks, top to bottom, as its row's stacks do: the parts beside the
    /// text that SwiftUI draws, and the text's pieces.
    let entries: [Entry]

    /// One thing the message stacks.
    enum Entry {
      /// A part beside the text that SwiftUI draws, hosted.
      case accessory(TranscriptTableAccessory)
      /// A piece of the text: a run of text blocks, or a block SwiftUI draws.
      case piece(MessageTextPiece)
      /// A prompt's body that shows nothing (its text was only upload markers): it takes no
      /// height, and its stack still spaces it.
      case empty
    }

    /// Whether a prompt over ``UserPrompt/collapseThreshold`` characters shows whole.
    enum PromptFold {
      case collapsed
      case expanded
    }

    /// A long prompt's fold; `nil` for any other message.
    var promptFold: PromptFold?
    /// A message from another session's fold: it starts collapsed to its sender and first line.
    var originFold: PromptFold?
    /// What shows under a prompt's bubble, at the column's trailing edge: its Interrupted line.
    var belowBubble: TranscriptTableAccessory?
    /// The author whose initials show beside a shared session's prompt.
    var avatar: String?

    /// Who said it, as VoiceOver hears the message: "You said", or a shared session author's
    /// name; `nil` for an answer.
    var speaker: String? {
      guard role == .user else { return nil }
      return decoration.showsAvatar ? "\(row.author ?? "Someone") said" : "You said"
    }

    /// The width the message's text and parts lay out at: the column's for an answer, the
    /// bubble's inside for a prompt, beside its avatar if it has one.
    func textWidth(_ metrics: TranscriptTableTextMetrics, layoutWidth: LayoutWidth) -> CGFloat {
      switch role {
      case .answer: metrics.columnWidth
      case .user: metrics.promptWidth(layoutWidth, besideAvatar: avatar != nil)
      }
    }

    /// The message row `row` shows, when a text cell can draw all of it at `ramp`.
    /// - Parameters:
    ///   - row: The row.
    ///   - ramp: The reading ramp the text splits at.
    ///   - expandsPrompt: A long prompt shows whole; it starts collapsed.
    ///   - expandsOrigin: A message from another session shows whole; it starts collapsed.
    /// - Returns: The message, or `nil` for a row that stays SwiftUI's.
    static func make(
      _ row: TranscriptTableRow, ramp: TypeRamp, expandsPrompt: Bool = false,
      expandsOrigin: Bool = false
    ) -> Self? {
      guard case .segment(let entry) = row.content,
        case .item(.message(let message)) =
          entry.segment
      else { return nil }
      guard !message.isStreaming else { return nil }
      let decoration = entry.decorations[message.id] ?? MessageDecoration()
      let attachments: [Entry] =
        message.attachments.isEmpty ? [] : [.accessory(.attachments(message.attachments))]
      // Content this app can't show follows the text and attachments, in a bubble or not.
      let unsupported: [Entry] = message.activity.map { [.accessory(.unsupported($0))] } ?? []
      var made: Self
      switch message.role {
      case .assistant:
        guard !message.text.isEmpty else { return nil }
        let text = Self.pieces(of: message.text, ramp: ramp)
        let interrupted: [Entry] = message.interrupted ? [.accessory(.interrupted)] : []
        made = Self(
          role: .answer, row: message, decoration: decoration, markdown: message.text,
          split: MessageTextSplits.shared.split(message.text, ramp: ramp),
          entries: (text.isEmpty ? [.empty] : text) + attachments + unsupported + interrupted)
      case .user:
        // Attachments lead the bubble, then the body, then content this app can't show.
        let body = promptBody(message, ramp: ramp, expands: expandsPrompt)
        made = Self(
          role: .user, row: message, decoration: decoration, markdown: body.markdown,
          split: MessageTextSplits.shared.split(body.markdown, ramp: ramp),
          entries: attachments + body.entries + unsupported, promptFold: body.fold)
        made = made.fromSession(message.originSessionId, expands: expandsOrigin, ramp: ramp)
        if message.interrupted { made.belowBubble = .interrupted }
        // A shared session shows another author's initials beside their prompt.
        if decoration.showsAvatar { made.avatar = message.author }
      case .tool:
        return nil
      }
      // A message that shows nothing at all stays SwiftUI's.
      guard made.entries.contains(where: { if case .empty = $0 { false } else { true } }) else {
        return nil
      }
      return made
    }

    /// A user's prompt's body: the markdown it shows, what it stacks and a long prompt's fold.
    private struct PromptBody {
      var markdown: String
      var entries: [Entry]
      var fold: PromptFold?
    }

    /// A user's prompt's body as ``UserPromptBody`` stacks it: its mentions' chips, its text
    /// and a long prompt's toggle. A prompt of attachments alone has no body.
    private static func promptBody(_ message: Row, ramp: TypeRamp, expands: Bool) -> PromptBody {
      let prompt = UserPrompt.parse(message.text)
      var markdown = prompt.text
      var fold: PromptFold?
      var toggle: [Entry] = []
      // A long prompt shows its start and "Show full prompt" until the reader expands it.
      if let collapsed = UserPrompt.collapsed(prompt.text) {
        fold = expands ? .expanded : .collapsed
        if !expands { markdown = collapsed + "\u{2026}" }
        let title = expands ? UserPrompt.collapseTitle : UserPrompt.expandTitle(prompt.text)
        toggle = [.accessory(.promptToggle(title: title, collapses: expands))]
      }
      let mentions: [Entry] =
        prompt.mentions.isEmpty ? [] : [.accessory(.mentions(prompt.mentions))]
      var body = mentions + pieces(of: markdown, ramp: ramp) + toggle
      if body.isEmpty, !message.text.isEmpty { body = [.empty] }
      return PromptBody(markdown: markdown, entries: body, fold: fold)
    }

    /// The prompt as a message another session sent, when `origin` names it: its sender over it,
    /// or, collapsed (as it starts), its sender and first line in place of its text.
    private func fromSession(_ origin: String?, expands: Bool, ramp: TypeRamp) -> Self {
      guard let origin else { return self }
      guard !expands else {
        return Self(
          role: role, row: row, decoration: decoration, markdown: markdown, split: split,
          entries: [.accessory(.origin(sessionID: origin))] + entries, promptFold: promptFold,
          originFold: .expanded)
      }
      let preview = SessionOrigin.preview(row.text)
      return Self(
        role: role, row: row, decoration: decoration, markdown: "",
        split: MessageTextSplits.shared.split("", ramp: ramp),
        entries: [.accessory(.collapsedOrigin(sessionID: origin, preview: preview))],
        originFold: .collapsed)
    }

    /// The pieces `markdown` splits into at `ramp`.
    private static func pieces(of markdown: String, ramp: TypeRamp) -> [Entry] {
      guard !markdown.isEmpty else { return [] }
      return MessageTextSplits.shared.split(markdown, ramp: ramp).pieces.map(Entry.piece)
    }

    /// The hosted parts beside the text, top to bottom: the entries', then what shows under a
    /// prompt's bubble.
    var accessories: [TranscriptTableAccessory] {
      let stacked = entries.compactMap { entry -> TranscriptTableAccessory? in
        if case .accessory(let accessory) = entry { return accessory }
        return nil
      }
      return stacked + (belowBubble.map { [$0] } ?? [])
    }

    /// The gap above each entry, as the row's stacks space them: a small gap between any two,
    /// and a piece of text its own gap after another piece.
    var gaps: [CGFloat] {
      var gaps: [CGFloat] = []
      var afterPiece = false
      for entry in entries {
        switch entry {
        case .piece(let piece):
          gaps.append(piece.gapAbove + (gaps.isEmpty || afterPiece ? 0 : Theme.Spacing.small))
          afterPiece = true
        case .accessory, .empty:
          gaps.append(gaps.isEmpty ? 0 : Theme.Spacing.small)
          afterPiece = false
        }
      }
      return gaps
    }

    /// One run of text blocks, the gap above it and the inline math its paragraphs typeset.
    struct Run {
      var id: Int
      var gapAbove: CGFloat
      var blocks: [MarkdownBlock]
      var inlineMath: [String]
    }

    /// The text runs, top to bottom.
    var runs: [Run] {
      split.pieces.compactMap { piece in
        guard case .text(let blocks) = piece.content else { return nil }
        return Run(
          id: piece.id, gapAbove: piece.gapAbove, blocks: blocks, inlineMath: piece.inlineMath)
      }
    }
  }

  /// Where a text cell puts a message at a table width: the chat column, as
  /// ``TranscriptColumn`` places it, and the widths the text lays out at.
  struct TranscriptTableTextMetrics: Equatable {
    /// The column's leading edge and width in the cell.
    var columnX: CGFloat
    var columnWidth: CGFloat

    /// The column in a cell `width` wide. A column narrower than its limit snaps down to a
    /// multiple of `snap` (0 for none), so a width dragged a point at a time lays text out only
    /// now and then; one with room for `ceiling` takes exactly that.
    init(
      width: CGFloat, layoutWidth: LayoutWidth, maxWidth: CGFloat, snap: CGFloat = 0,
      ceiling: CGFloat = .infinity
    ) {
      let gutter = layoutWidth == .compact ? Theme.Spacing.compactGutter : Theme.Spacing.gutter
      let limit = layoutWidth == .compact ? CGFloat.infinity : maxWidth
      var columnWidth = max(0, min(limit, width - 2 * gutter))
      if columnWidth >= ceiling {
        columnWidth = ceiling
      } else if snap > 0, columnWidth < limit {
        columnWidth = (columnWidth / snap).rounded(.down) * snap
      }
      self.columnWidth = columnWidth
      columnX = ((width - columnWidth - 2 * gutter) / 2).rounded(.down) + gutter
    }

    /// The space a bubble keeps on its leading side, as the stack's spacer does.
    static func bubbleLead(_ layoutWidth: LayoutWidth) -> CGFloat {
      (layoutWidth == .compact ? Theme.Spacing.extraLarge : Theme.Spacing.section)
        + Theme.Spacing.small
    }

    #if os(macOS)
      /// The space a shared session's avatar takes at the bubble's trailing side, with the
      /// stack's spacing before it.
      static let avatarLane = TranscriptTableAvatarView.size + Theme.Spacing.small
    #else
      /// The same for ``AuthorAvatar``, 24 points wide.
      static let avatarLane: CGFloat = 24 + Theme.Spacing.small
    #endif

    /// The width a user's prompt may lay out at inside its bubble, beside an avatar or not.
    func promptWidth(_ layoutWidth: LayoutWidth, besideAvatar: Bool = false) -> CGFloat {
      let lane = besideAvatar ? Self.avatarLane : 0
      let bubble = min(Theme.userMessageWidth, columnWidth - Self.bubbleLead(layoutWidth) - lane)
      return max(0, bubble - 2 * Theme.Spacing.large)
    }
  }
#endif
