import SwiftUI

/// The web's per-turn fold: "Worked for 2m" (or "Worked"), closed in settled history; the live
/// turn reads "Working…" and stays open. The content sits behind a hairline guide.
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
    if isLive { return "Working\u{2026}" }
    if let duration { return "Worked for \(TurnLayout.duration(duration))" }
    return "Worked"
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

/// The working indicator: Otto bobbing with a rotating label, or the blocked-state text.
struct WorkingIndicator: View {
  let isBlocked: Bool
  @State private var labelIndex = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let labels = [
    "Working\u{2026}", "Cooking\u{2026}", "Crunching\u{2026}", "Thinking\u{2026}",
  ]

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      OttoView(isWorking: !isBlocked).frame(width: 22, height: 22)
      Text(isBlocked ? "Waiting for your response to the request below." : Self.labels[labelIndex])
        .font(.callout)
        .foregroundStyle(.secondary)
        .contentTransition(.opacity)
    }
    .task(id: isBlocked || reduceMotion) {
      guard !isBlocked, !reduceMotion else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(5))
        } catch {
          // Cancelled: the indicator went away.
          return
        }
        withAnimation(reduceMotion ? nil : Theme.Motion.feedback) {
          labelIndex = (labelIndex + 1) % Self.labels.count
        }
      }
    }
    .accessibilityElement(children: .combine)
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

/// Pending decisions inline at the pending point of the transcript (they also stay docked above
/// the composer). Drafts are shared with the dock.
struct InlineDecisions: View {
  let state: ConversationViewState
  let actions: ConversationActions
  @Environment(DecisionDrafts.self) private var sharedDrafts: DecisionDrafts?
  @State private var localDrafts = DecisionDrafts()

  private var drafts: DecisionDrafts { sharedDrafts ?? localDrafts }

  var body: some View {
    ForEach(state.decisions.filter { !$0.answered }) { card in
      DecisionCardView(
        card: card, phase: state.phase(of: card), isReadOnly: state.header.readOnly,
        respond: actions.respond.map { respond in { respond(card, $0) } },
        validate: actions.validateForm.map { validate in { validate(card, $0) } },
        draft: drafts.binding(card.id)
      )
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
