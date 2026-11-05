import OmnigentPlatform
import SwiftUI

extension EnvironmentValues {
  /// Whether ``MessageActionRow``s below render their controls. Set by
  /// ``View/messageActionsHost(row:actions:pinned:showsOnTouch:focus:)``; a row outside a host
  /// shows them.
  @Entry var messageActionsRevealed = true
}

/// One action on a message, shared by the action row, the context menu and VoiceOver.
struct MessageActionItem: Identifiable {
  /// Which action.
  enum Kind: String {
    case copy, fork, link, reply, askSideChat
  }

  let kind: Kind
  /// The button and VoiceOver title.
  let title: String
  /// The context-menu title.
  let menuTitle: String
  let systemImage: String
  /// The row button's accessibility identifier.
  let identifier: String
  let perform: @MainActor () -> Void

  var id: Kind { kind }

  /// Copy (when the message has text), Fork chat from here (a settled assistant message with a
  /// response, when the host can fork) and Copy link (when the host has links), in row order.
  static func items(
    for row: Row, actions: ConversationActions, copy: CopyAction = CopyAction(presenter: nil)
  ) -> [Self] {
    var items: [Self] = []
    if !row.text.isEmpty {
      let text = row.text
      items.append(
        Self(
          kind: .copy, title: "Copy", menuTitle: "Copy", systemImage: "doc.on.doc",
          identifier: "message-copy-\(row.id)", perform: { Pasteboard.copy(text) }))
    }
    if let fork = actions.forkFrom, isForkPoint(row) {
      items.append(
        Self(
          kind: .fork, title: "Fork chat from here", menuTitle: "Fork Chat from Here\u{2026}",
          systemImage: "arrow.triangle.branch", identifier: "message-fork-\(row.id)",
          perform: { fork(row) }))
    }
    if let url = actions.messageURL?(row) {
      items.append(
        Self(
          kind: .link, title: "Copy link", menuTitle: "Copy Link", systemImage: "link",
          identifier: "message-link-\(row.id)",
          perform: { copy(url.absoluteString, confirmation: "Link copied") }))
    }
    return items
  }

  /// Reply and Ask in side chat with the whole message quoted: touch has no selection popup,
  /// so the message's context menu offers them (the web's selection popup actions).
  static func quoteItems(for row: Row, actions: ConversationActions) -> [Self] {
    let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !row.isStreaming else { return [] }
    var items: [Self] = []
    if let reply = actions.replyWithSelection {
      items.append(
        Self(
          kind: .reply, title: "Reply", menuTitle: "Reply", systemImage: "arrowshape.turn.up.left",
          identifier: "message-reply-\(row.id)", perform: { reply(text) }))
    }
    if let ask = actions.askInSideChat {
      items.append(
        Self(
          kind: .askSideChat, title: "Ask in side chat", menuTitle: "Ask in Side Chat",
          systemImage: "bubble.left.and.bubble.right",
          identifier: "message-side-chat-\(row.id)", perform: { ask(text) }))
    }
    return items
  }

  /// A conversation can be forked after a settled assistant message that belongs to a response.
  static func isForkPoint(_ row: Row) -> Bool {
    row.role == .assistant && !row.isStreaming && !row.isEphemeral && row.responseId != nil
  }
}

/// A message's action buttons (Copy, Fork chat from here, Copy link) and its timestamp. While a
/// ``View/messageActionsHost(row:actions:pinned:showsOnTouch:focus:)`` hides them, it renders no
/// controls. With `overlaysGap` on Mac it takes no space at all: the controls hang into the gap
/// below the message at its trailing edge, so a hidden row leaves no blank lane and revealing it
/// moves nothing. An answer with a "Worked for" footer overlays the row on that line instead.
struct MessageActionRow: View {
  let row: Row
  let actions: ConversationActions
  var timestamp: Date?
  /// The host's focus, so moving focus from the message into a button keeps the row shown.
  var focus: FocusState<Bool>.Binding
  /// Hang the controls into the transcript's row gap below the message (Mac chat style); off,
  /// the row sizes to its controls (the CLI's floating cluster, touch).
  var overlaysGap = false

  @Environment(\.messageActionsRevealed) private var revealed
  @Environment(\.copyWithConfirmation) private var copy

  /// How far the controls rise into the message's spacing above the row (4 pt under a bubble,
  /// 8 under an answer), so they start at the message's edge and fit the 24 pt row gap.
  private var gapLift: CGFloat {
    row.role == .user ? Theme.Spacing.extraSmall : Theme.Spacing.small
  }

  var body: some View {
    #if os(macOS)
      if overlaysGap {
        Color.clear
          .frame(height: 0)
          .overlay(alignment: .topTrailing) {
            if revealed {
              controls
                .contentShape(Rectangle())
                .offset(y: -gapLift)
                .transition(.opacity)
            }
          }
      } else {
        sizedBody
      }
    #else
      sizedBody
    #endif
  }

  @ViewBuilder private var sizedBody: some View {
    if revealed {
      controls.transition(.opacity)
    } else {
      #if os(macOS)
        // Hover reveals the cluster in place; touch has nothing to reveal, so it keeps no gap.
        Color.clear
          .frame(width: Theme.Control.target, height: Theme.Control.target)
          .accessibilityHidden(true)
      #endif
    }
  }

  private var controls: some View {
    HStack(spacing: Theme.Spacing.medium) {
      ForEach(MessageActionItem.items(for: row, actions: actions, copy: copy)) { item in
        if item.kind == .copy {
          CopyButton(text: row.text, label: item.title, identifier: item.identifier)
            .focused(focus)
        } else {
          Button(item.title, systemImage: item.systemImage, action: item.perform)
            .labelStyle(.iconOnly)
            .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
            .contentShape(Rectangle())
            .hoverHighlight()
            .focused(focus)
            .help(item.title)
            .accessibilityIdentifier(item.identifier)
        }
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

/// Hosts a message's actions: reveals the ``MessageActionRow``s inside on hover or keyboard
/// focus (on touch, as `showsOnTouch` says), and always offers them in the context menu and as
/// VoiceOver actions.
private struct MessageActionsHost: ViewModifier {
  let row: Row
  let actions: ConversationActions
  let pinned: Bool
  let showsOnTouch: Bool
  var focus: FocusState<Bool>.Binding

  @State private var isHovered = false
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.copyWithConfirmation) private var copy

  private var revealed: Bool {
    #if os(macOS)
      pinned || isHovered || focus.wrappedValue || voiceOverEnabled
    #else
      showsOnTouch || voiceOverEnabled
    #endif
  }

  func body(content: Content) -> some View {
    content
      #if os(macOS)
        // Keyboard navigation can land on the message itself, which reveals its row.
        .focusable(interactions: .activate)
        .focused(focus)
      #endif
      .onHover { isHovered = $0 }
      .environment(\.messageActionsRevealed, revealed)
      .animation(reduceMotion ? nil : Theme.Motion.feedback, value: revealed)
      .contextMenu { MessageContextMenu(row: row, actions: actions) }
      .accessibilityActions {
        ForEach(MessageActionItem.items(for: row, actions: actions, copy: copy)) { item in
          Button(item.title, action: item.perform)
        }
        #if !os(macOS)
          ForEach(MessageActionItem.quoteItems(for: row, actions: actions)) { item in
            Button(item.title, action: item.perform)
          }
        #endif
      }
  }
}

extension View {
  /// Makes this view a message's action host; see ``MessageActionRow``.
  /// - Parameters:
  ///   - row: The message.
  ///   - actions: The conversation's actions.
  ///   - pinned: Keep the row shown on Mac (the last settled answer).
  ///   - showsOnTouch: Show the row on touch devices; otherwise it is a long press away.
  ///   - focus: Focus shared with the row's ``MessageActionRow/focus``.
  /// - Returns: The host.
  func messageActionsHost(
    row: Row, actions: ConversationActions, pinned: Bool, showsOnTouch: Bool,
    focus: FocusState<Bool>.Binding
  ) -> some View {
    modifier(
      MessageActionsHost(
        row: row, actions: actions, pinned: pinned, showsOnTouch: showsOnTouch, focus: focus))
  }
}

/// The message's context menu: its actions, then Share and Copy Message ID.
struct MessageContextMenu: View {
  let row: Row
  let actions: ConversationActions
  @Environment(\.copyWithConfirmation) private var copy

  var body: some View {
    #if !os(macOS)
      // The Mac quotes a selection from its popup; touch quotes the whole message here.
      let quotes = MessageActionItem.quoteItems(for: row, actions: actions)
      if !quotes.isEmpty {
        ForEach(quotes) { item in
          Button(item.menuTitle, systemImage: item.systemImage, action: item.perform)
        }
        Divider()
      }
    #endif
    ForEach(MessageActionItem.items(for: row, actions: actions, copy: copy)) { item in
      Button(item.menuTitle, systemImage: item.systemImage, action: item.perform)
    }
    ShareLink(item: row.text) { Label("Share", systemImage: "square.and.arrow.up") }
      .disabled(row.text.isEmpty)
    Divider()
    ConfirmedCopyButton(
      title: "Copy Message ID", systemImage: "number", text: row.id,
      confirmation: "Message ID copied")
  }
}
