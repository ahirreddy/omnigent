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
    .listRowBackground(Rectangle().fill(ThemeColor.hover.opacity(isSelected ? 1 : 0)))
    .contextMenu { rowActions }
    #if os(iOS)
      .swipeActions(edge: .leading, allowsFullSwipe: false) {
        if item.canApprove, let card = item.decision, card.permissions.plan == nil,
          let respond = actions.respond
        {
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
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      HStack {
        Text(item.isUnresolved ? "Needs you" : item.isUnread ? item.kind.title : "Read")
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

  /// The preview, else the request's own title, so a row never has a blank headline.
  private var headline: String {
    let preview = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
    if !preview.isEmpty { return preview }
    if let title = item.decision?.title, !title.isEmpty { return title }
    return item.kind.title
  }

  /// The selected binary approval answers Command-Return (E does the same from the list).
  private var ownsApproveShortcut: Bool {
    isSelected && item.canApprove && item.decision?.permissions.plan == nil
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
    } else if let send = actions.reply {
      HStack {
        TextField("Reply…", text: $reply)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("inbox-reply-\(item.id)")
        Button("Send") { send(item, reply) }
          .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("inbox-send-\(item.id)")
      }
    }
    HStack { rowActions }.buttonStyle(.borderless).tint(.secondary)
  }

  @ViewBuilder private var rowActions: some View {
    if let open = actions.open {
      Button("Open session") { open(item) }
        .accessibilityIdentifier("inbox-open-\(item.id)")
    }
    if let markRead = actions.markRead, item.isUnread {
      Button("Mark as read") { markRead(item) }
        .accessibilityIdentifier("inbox-mark-read-\(item.id)")
    }
  }
}
