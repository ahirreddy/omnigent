import SwiftUI

/// The per-turn fold of tool work, titled by its size ("4 steps"): closed in settled history,
/// open while live. How long the turn worked shows once, under its answer ("Worked for 2m"), and
/// the live turn's time in the working indicator ("Working · 12s"), so the fold never repeats
/// either; its tooltip still names the duration. The content sits behind a hairline guide.
struct WorkedFold: View {
  let items: [TranscriptItem]
  let isLive: Bool
  let duration: TimeInterval?
  let decorations: [String: MessageDecoration]

  // `nil` follows the turn: open while live, closed once settled.
  // swiftlint:disable:next discouraged_optional_boolean
  @State private var expandedOverride: Bool?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var isExpanded: Bool { expandedOverride ?? isLive }

  private var title: String {
    Self.title(items: items)
  }

  /// "4 steps": each tool call and each other item is one.
  static func title(items: [TranscriptItem]) -> String {
    let count = items.reduce(0) { total, item in
      if case .tools(_, let entries) = item { return total + max(entries.count, 1) }
      return total + 1
    }
    return count == 1 ? "1 step" : "\(count) steps"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Button {
        withAnimation(reduceMotion ? nil : Theme.Motion.disclosure) {
          expandedOverride = !isExpanded
        }
      } label: {
        HStack(spacing: Theme.Spacing.extraSmall) {
          Text(title)
          Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, Theme.Spacing.extraSmall)
        .frame(minHeight: Theme.Control.target)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .hoverHighlight()
      .help(duration.map(TurnElapsed.worked) ?? "")
      .accessibilityLabel(title)
      .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("worked-fold-\(items.first?.id ?? "empty")")
      if isExpanded {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
          ForEach(items) { item in
            TranscriptItemView(item: item, decorations: decorations)
          }
        }
        .padding(.leading, Theme.Spacing.medium)
        .overlay(alignment: .leading) {
          Rectangle().fill(.separator).frame(width: 1)
        }
      }
    }
  }
}

/// The live turn's one working line: typing dots and "Working · 12s", or the blocked-state text.
/// Otto stays in empty states; a mascot is not a spinner.
struct WorkingIndicator: View {
  let isBlocked: Bool
  /// When the turn started; `nil` shows "Working" without a time.
  var startedAt: Date?

  var body: some View {
    Group {
      if isBlocked {
        TurnStatusRow {
          Image(systemName: "hand.raised.fill").foregroundStyle(Theme.attention)
            .accessibilityHidden(true)
        } label: {
          Text("Waiting for your response to the request below.")
        }
      } else {
        TurnStatusRow {
          TypingIndicator()
        } label: {
          ElapsedTimeline(start: startedAt) { now in
            Text(TurnElapsed.label(since: startedAt, now: now)).monospacedDigit()
          }
        }
      }
    }
    .frame(minHeight: Theme.Control.target)
    .accessibilityIdentifier("transcript-working")
  }
}

/// The plan card at the top of the transcript: "Plan (x/y)", collapsible, scrolling past 150pt.
struct PlanCard: View {
  let section: EventSection
  @State private var isExpanded = true

  var body: some View {
    let todos = SectionReading.todos(section)
    let done = todos.count { $0.state == .completed }
    DisclosureGroup(isExpanded: $isExpanded) {
      BoundedScrollView(maxHeight: 150) {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          ForEach(todos) { TodoRow(todo: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.small)
      }
    } label: {
      Label("Plan (\(done)/\(todos.count))", systemImage: "checklist")
        .font(Theme.Typography.label)
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .cardSurface(cornerRadius: Theme.Radius.large)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("plan-card")
  }
}

/// Pending decisions inline at the pending point of the transcript. While a card is on screen
/// it is the request's one answering surface and the dock only names it. Drafts are shared with
/// the dock.
struct InlineDecisions: View {
  let state: ConversationViewState
  let actions: ConversationActions
  @Environment(DecisionDrafts.self) private var sharedDrafts: DecisionDrafts?
  @State private var localDrafts = DecisionDrafts()

  private var drafts: DecisionDrafts { sharedDrafts ?? localDrafts }

  var body: some View {
    // A sub-agent's requests render in its group row instead.
    let grouped = SubagentGroup(state: state)?.decisionIDs ?? []
    ForEach(state.decisions.filter { !$0.answered && !grouped.contains($0.id) }) { card in
      DecisionCardView(
        card: card, phase: state.phase(of: card), isReadOnly: state.header.readOnly,
        respond: actions.respond.map { respond in { respond(card, $0) } },
        validate: actions.validateForm.map { validate in { validate(card, $0) } },
        draft: drafts.binding(card.id)
      )
      .reportsInlineDecision(card.id, showsApprove: true)
      .id("inline-\(card.id)")
    }
  }
}

/// Form drafts per decision card, shared by the inline cards and the dock.
@Observable
final class DecisionDrafts {
  var drafts: [String: FormDraft] = [:]

  func binding(_ id: String) -> Binding<FormDraft> {
    Binding(get: { self.drafts[id, default: FormDraft()] }, set: { self.drafts[id] = $0 })
  }
}
