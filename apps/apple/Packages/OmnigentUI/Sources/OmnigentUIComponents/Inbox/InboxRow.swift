import SwiftUI

struct InboxRow: View {
  let item: InboxItem
  let now: Date?
  let actions: InboxActions
  let isSelected: Bool
  let select: () -> Void
  @Binding var isExpanded: Bool
  @Binding var reply: String
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var commandReturnSends = ComposerPreferences.commandReturnSends

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Button {
        select()
        withAnimation(reduceMotion ? nil : Theme.Motion.disclosure) { isExpanded.toggle() }
      } label: {
        summary
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("inbox-toggle-\(item.id)")
      if isExpanded { detail }
    }
    .padding(.vertical, Theme.Spacing.medium)
    .hoverHighlight()
    .commandReturnPreference($commandReturnSends)
    .countsRenders("inbox row")
    .listRowBackground(Rectangle().fill(ThemeColor.hover.opacity(isSelected ? 1 : 0)))
    .contextMenu { rowActions }
    #if os(iOS)
      .swipeActions(edge: .leading, allowsFullSwipe: false) {
        if item.approvesDirectly, let card = item.decision, let respond = actions.respond {
          // The row's primary action, as the card's Approve button; not a "needs you" signal.
          Button("Approve", systemImage: "checkmark") { respond(card, .approve) }
          .tint(Theme.accent)
          .accessibilityIdentifier("inbox-swipe-approve-\(item.id)")
        }
        if let open = actions.open {
          Button("Open", systemImage: "arrow.up.forward.app") { open(item) }
          .accessibilityIdentifier("inbox-swipe-open-\(item.id)")
        }
      }
      .swipeActions(edge: .trailing) {
        if let markRead = actions.markRead, item.isUnread {
          Button("Mark read", systemImage: "envelope.open") { markRead(item) }
          .accessibilityIdentifier("inbox-swipe-read-\(item.id)")
        }
      }
    #endif
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("inbox-\(item.id)")
  }

  private var summary: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      InboxKindTile(item: item)
      summaryText
    }
  }

  private var summaryText: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      HStack {
        Text(kindLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(item.isUnresolved ? Theme.brandAccent : Theme.secondary)
        if item.isPinned {
          Label("Pinned", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary)
        }
        if item.isUnread {
          Label("Unread", systemImage: "circle.fill").font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(age(at: now ?? context.date)).font(.caption).foregroundStyle(.secondary)
        }
      }
      Text(headline).font(Theme.Typography.label)
        .fixedSize(horizontal: false, vertical: true)
      Text([item.sessionTitle, item.agentName].filter { !$0.isEmpty }.joined(separator: " · "))
        .font(.callout).foregroundStyle(.secondary)
      if !item.executionContext.isEmpty {
        Text(item.executionContext).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var kindLabel: String {
    if item.isUnresolved { return "Needs you" }
    if !item.isUnread { return "Read" }
    switch item.kind {
    case .unread: return item.isError ? "Error" : "Done"
    case .approval, .question, .comment: return item.kind.title
    }
  }

  /// The preview, else the request's own title, so a row never has a blank headline.
  private var headline: String {
    let preview = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !preview.isEmpty { return preview }
    if let title = item.decision?.title, !title.isEmpty { return title }
    return item.kind.title
  }

  /// The selected binary approval answers Command-Return (E does the same from the list).
  private var ownsApproveShortcut: Bool {
    isSelected && item.approvesDirectly
  }

  private func age(at now: Date) -> String {
    if item.isUnresolved, let waiting = item.waitingSince {
      return "Waiting \(RelativeTime.short(waiting, now: now))"
    }
    return "Last activity \(RelativeTime.short(item.date, now: now))"
  }

  @ViewBuilder private var detail: some View {
    if let decision = item.decision {
      // Resolve in place: one line with Approve and Reject, Review for the whole card.
      DecisionCardView(
        card: decision, phase: item.phase, isReadOnly: item.isReadOnly, style: .compact,
        context: [item.agentName, item.sessionTitle].filter { !$0.isEmpty }
          .joined(separator: " \u{00B7} "),
        respond: actions.respond.map { respond in { respond(decision, $0) } }
      )
      .decisionApproveShortcut(ownsApproveShortcut ? decision.id : nil)
      .environment(\.decisionIDPrefix, "inbox-")
    } else if item.isUnresolved {
      Text("Open the session to review this request. Details are not available yet.")
        .font(.callout).foregroundStyle(.secondary)
    } else if let comment = item.comment {
      commentDetail(comment)
    } else {
      replyDetail
    }
    HStack { rowActions }.buttonStyle(.borderless).tint(.secondary)
  }

  private func commentDetail(_ comment: InboxComment) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      Text(
        "\(Text(comment.author).foregroundStyle(.primary)) commented on \(Text(comment.path).font(Theme.Typography.code))"
      )
      .font(.callout).foregroundStyle(.secondary)
      if let anchor = comment.anchor {
        Text(anchor.trimmingCharacters(in: .whitespacesAndNewlines))
          .font(Theme.Typography.code).foregroundStyle(.secondary).lineLimit(1)
      }
      Text(comment.body).font(Theme.Typography.label).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityIdentifier("inbox-comment-\(item.id)")
  }

  @ViewBuilder private var replyDetail: some View {
    switch item.reply {
    case .sent:
      Label("Reply sent. The agent\u{2019}s answer will show up here.", systemImage: "checkmark")
        .font(.callout).foregroundStyle(.secondary)
        .accessibilityIdentifier("inbox-reply-sent-\(item.id)")
        .onAppear { reply = "" }
    case .idle, .sending, .failed:
      if let fullText = item.fullText { FullReplyButton(text: fullText, itemID: item.id) }
      if item.canReply, let send = actions.reply {
        replyField(send)
        if case .failed(let message) = item.reply {
          Label(message, systemImage: "exclamationmark.triangle").font(.callout)
            .foregroundStyle(.red)
            .accessibilityIdentifier("inbox-reply-error-\(item.id)")
        }
      }
    }
  }

  private func replyField(_ send: @escaping @MainActor (InboxItem, String) -> Void) -> some View {
    let sending = item.reply == .sending
    return HStack(alignment: .bottom) {
      TextField("Reply to \(item.sessionTitle)", text: $reply, axis: .vertical)
        .lineLimit(1...6)
        .textFieldStyle(.roundedBorder)
        .disabled(sending)
        .onSubmit { if !commandReturnSends { submit(send) } }
        .onKeyPress(.return, phases: .down) { press in returnKey(press, send) }
        .onChange(of: reply) {
          if case .failed = item.reply { actions.editReply?(item) }
        }
        .accessibilityIdentifier("inbox-reply-\(item.id)")
      Button {
        submit(send)
      } label: {
        if sending { ProgressView().controlSize(.small) } else { Text("Send") }
      }
      .buttonStyle(.borderedProminent)
      .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
      .accessibilityIdentifier("inbox-send-\(item.id)")
    }
  }

  /// The send shortcut setting, as the composer: Command-Return always sends; with the setting
  /// on, a plain Return starts a new line instead.
  private func returnKey(_ press: KeyPress, _ send: @MainActor (InboxItem, String) -> Void)
    -> KeyPress.Result
  {
    if press.modifiers == .command {
      submit(send)
      return .handled
    }
    guard commandReturnSends, press.modifiers.isEmpty else { return .ignored }
    reply += "\n"
    return .handled
  }

  private func submit(_ send: @MainActor (InboxItem, String) -> Void) {
    guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.reply != .sending
    else { return }
    send(item, reply)
  }

  @ViewBuilder private var rowActions: some View {
    if let open = actions.open {
      Button(item.comment == nil ? "Open session" : "Open file") { open(item) }
        .disabled(item.reply == .sending)
        .accessibilityIdentifier("inbox-open-\(item.id)")
    }
    if let markRead = actions.markRead, item.isUnread {
      Button("Mark as read") { markRead(item) }
        .accessibilityIdentifier("inbox-mark-read-\(item.id)")
    }
  }
}
