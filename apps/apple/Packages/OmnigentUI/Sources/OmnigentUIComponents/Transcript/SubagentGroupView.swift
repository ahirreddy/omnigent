import SwiftUI

/// The parent's live sub-agent group: one row (`2 agents · 1 running · 1 ready`) that expands to
/// each child's goal, latest activity and mirrored requests. A blocked child's requests are
/// answered right here with compact cards; finished children fold to "2 done" while others are
/// active. Opening a child goes through ``ConversationActions/openChild`` (else `openSession`).
struct SubagentGroupView: View {
  let state: ConversationViewState
  let actions: ConversationActions
  @State private var expansion = Expansion.automatic
  @State private var showsDone = false
  @Environment(DecisionDrafts.self) private var sharedDrafts: DecisionDrafts?
  @State private var localDrafts = DecisionDrafts()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var drafts: DecisionDrafts { sharedDrafts ?? localDrafts }

  /// Until the user toggles it, the group opens while a child needs them.
  private enum Expansion {
    case automatic
    case collapsed
    case expanded
  }

  var body: some View {
    if let group = SubagentGroup(state: state) {
      let isExpanded =
        switch expansion {
        case .automatic: group.startsExpanded
        case .collapsed: false
        case .expanded: true
        }
      VStack(alignment: .leading, spacing: 0) {
        header(group, isExpanded: isExpanded)
        if isExpanded {
          ForEach(group.active) { child in
            Divider().padding(.leading, Theme.Spacing.medium)
            row(child)
          }
          doneSection(group)
        }
      }
      .cardSurface(cornerRadius: Theme.Radius.large)
      .environment(\.decisionIDPrefix, "subagent-")
      .accessibilityElement(children: .contain)
      .accessibilityLabel(group.headline)
      .accessibilityIdentifier("subagent-group")
    }
  }

  private var open: (@MainActor (String) -> Void)? { actions.openChild ?? actions.openSession }

  private func header(_ group: SubagentGroup, isExpanded: Bool) -> some View {
    Button {
      withAnimation(reduceMotion ? nil : Theme.Motion.disclosure) {
        expansion = isExpanded ? .collapsed : .expanded
      }
    } label: {
      HStack(spacing: Theme.Spacing.small) {
        HStack(spacing: -Theme.Spacing.extraSmall) {
          ForEach(group.children.prefix(4)) { child in
            SubagentStatusGlyph(status: child.status, isCompact: true)
          }
        }
        .accessibilityHidden(true)
        headline(group)
          .font(Theme.Typography.label)
          .lineLimit(2)
        Spacer(minLength: Theme.Spacing.small)
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 0 : -90))
          .accessibilityHidden(true)
      }
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small)
      .frame(minHeight: Theme.Control.target)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(group.headline)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    .accessibilityHint("Shows each subagent's goal, activity and requests")
    .accessibilityIdentifier("subagent-group-toggle")
  }

  /// The headline with "needs you" in pink, the one place pink appears in the group.
  private func headline(_ group: SubagentGroup) -> Text {
    var text = Text(group.total)
    for (status, count) in group.counts {
      let part = Text(status.count(count))
        .foregroundStyle(status == .needsYou ? Theme.brandAccent : Theme.secondary)
      text = Text("\(text) \u{00B7} \(part)")
    }
    return text
  }

  private func row(_ child: SubagentChild) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      SubagentChildRow(child: child, open: open)
      ForEach(child.decisions) { card in
        DecisionCardView(
          card: card, phase: state.phase(of: card), isReadOnly: state.header.readOnly,
          style: .compact, context: child.title,
          respond: actions.respond.map { respond in { respond(card, $0) } },
          validate: actions.validateForm.map { validate in { validate(card, $0) } },
          draft: drafts.binding(card.id)
        )
        .reportsInlineDecision(card.id, showsApprove: DecisionSummary(card).answersInline)
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
  }

  @ViewBuilder private func doneSection(_ group: SubagentGroup) -> some View {
    let done = group.done
    if !done.isEmpty {
      // With nothing else active there is nothing to fold behind.
      if group.active.isEmpty || showsDone {
        ForEach(done) { child in
          Divider().padding(.leading, Theme.Spacing.medium)
          row(child)
        }
      }
      if !group.active.isEmpty {
        Divider().padding(.leading, Theme.Spacing.medium)
        Button(showsDone ? "Hide \(done.count) done" : "\(done.count) done") {
          withAnimation(reduceMotion ? nil : Theme.Motion.disclosure) { showsDone.toggle() }
        }
        .buttonStyle(.borderless)
        .tint(.secondary)
        .font(.callout)
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .accessibilityIdentifier("subagent-group-done")
      }
    }
  }
}

/// One child: status, title, goal and latest activity. The whole row opens its transcript.
struct SubagentChildRow: View {
  let child: SubagentChild
  let open: (@MainActor (String) -> Void)?

  var body: some View {
    Button {
      open?(child.id)
    } label: {
      HStack(alignment: .top, spacing: Theme.Spacing.small) {
        SubagentStatusGlyph(status: child.status, isCompact: false)
          .padding(.top, 1)
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(child.title)
              .font(.callout.weight(.semibold))
              .lineLimit(1)
            if let agent = child.agent, agent != child.title {
              Text(agent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.small)
            statusLine
          }
          if let goal = child.goal {
            Text(goal)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          }
          if let error = child.error, child.status == .failed {
            Text(error).font(.caption).foregroundStyle(Theme.failure).lineLimit(2)
          } else if let activity = child.activity {
            Text(activity)
              .font(.caption)
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
        if open != nil {
          Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 3)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(open == nil)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityText)
    .accessibilityHint(open == nil ? "" : "Opens the subagent's transcript")
    .accessibilityIdentifier("open-\(child.sectionID)")
  }

  @ViewBuilder private var statusLine: some View {
    let tint: ThemeColor = child.status == .needsYou ? Theme.brandAccent : Theme.secondary
    if child.status == .running, let started = child.startedAt {
      TimelineView(.periodic(from: .now, by: 30)) { context in
        Text("\(child.status.title) \u{00B7} \(RelativeTime.short(started, now: context.date))")
          .font(.caption).foregroundStyle(tint)
      }
    } else {
      Text(child.status.title).font(.caption.weight(.medium)).foregroundStyle(tint)
    }
  }

  private var accessibilityText: String {
    [child.title, child.status.title, child.goal, child.activity].compactMap(\.self)
      .joined(separator: ", ")
  }
}

/// A child's status mark: a spinner while running, pink while it needs the user.
struct SubagentStatusGlyph: View {
  let status: SubagentStatus
  let isCompact: Bool

  var body: some View {
    Group {
      if status == .running {
        ProgressView().controlSize(.mini)
      } else {
        Image(systemName: symbol)
          .font(isCompact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
          .foregroundStyle(tint)
      }
    }
    .frame(width: isCompact ? 14 : 18, height: isCompact ? 14 : 18)
    .background {
      if isCompact { Circle().fill(.background) }
    }
    .accessibilityHidden(true)
  }

  private var symbol: String {
    switch status {
    case .needsYou: "hand.raised.fill"
    case .running: "circle.dotted"
    case .starting: "circle.dotted"
    case .failed: "exclamationmark.triangle.fill"
    case .ready: "checkmark.circle.fill"
    }
  }

  private var tint: ThemeColor {
    switch status {
    case .needsYou: Theme.brandAccent
    case .running, .starting: Theme.secondary
    case .failed: Theme.failure
    case .ready: Theme.success
    }
  }
}

/// Shown at the top of a child's transcript: the obvious route back to its parent.
struct ParentSessionBanner: View {
  let parentID: String
  let open: (@MainActor (String) -> Void)?

  var body: some View {
    if let open {
      Button {
        open(parentID)
      } label: {
        Label("Back to the parent session", systemImage: "chevron.backward")
          .font(Theme.Typography.label)
          .padding(.horizontal, Theme.Spacing.medium)
          .padding(.vertical, Theme.Spacing.small)
          .frame(minHeight: Theme.Control.target)
          .cardSurface(cornerRadius: Theme.Radius.large)
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .help("This is a subagent. Go back to the session that started it.")
      .accessibilityHint("This session is a subagent")
      .accessibilityIdentifier("session-open-parent")
    }
  }
}
