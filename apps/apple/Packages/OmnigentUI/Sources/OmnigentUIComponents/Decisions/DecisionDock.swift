public import SwiftUI

/// Pending and just-answered decision cards, docked above the composer so they can never be
/// scrolled out of view. Several cards page with a counter; form drafts are kept per card.
public struct DecisionDock: View {
  private let state: ConversationViewState
  private let actions: ConversationActions

  @State private var index = 0
  @Environment(DecisionDrafts.self) private var sharedDrafts: DecisionDrafts?
  @State private var localDrafts = DecisionDrafts()

  private var drafts: DecisionDrafts { sharedDrafts ?? localDrafts }
  @Environment(\.layoutWidth) private var layoutWidth

  /// Creates the dock.
  /// - Parameters:
  ///   - state: The conversation, for its cards and their phases.
  ///   - actions: Host actions (`respond`, `validateForm`, `openURL`).
  public init(state: ConversationViewState, actions: ConversationActions) {
    self.state = state
    self.actions = actions
  }

  private var cards: [DecisionCard] {
    // Unanswered first, so a pending card is always the one shown.
    state.decisions.filter { !$0.answered } + state.decisions.filter(\.answered)
  }

  private func headline(cards: [DecisionCard]) -> String {
    let pending = state.pendingDecisions.count
    if pending == cards.count { return "\(pending) requests need your response" }
    return "\(pending) of \(cards.count) requests need your response"
  }

  /// The dock; empty when there are no cards.
  public var body: some View {
    let cards = cards
    if !cards.isEmpty {
      let current = min(index, cards.count - 1)
      let card = cards[current]
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        if cards.count > 1 {
          HStack(spacing: Theme.Spacing.small) {
            Label(headline(cards: cards), systemImage: "hand.raised.fill")
              .font(Theme.Typography.section)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Previous Request", systemImage: "chevron.left") { index = max(0, current - 1) }
              .labelStyle(.iconOnly)
              .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
              .disabled(current == 0)
              .accessibilityIdentifier("decision-dock-previous")
            Text("\(current + 1) of \(cards.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("decision-dock-position")
            Button("Next Request", systemImage: "chevron.right") {
              index = min(cards.count - 1, current + 1)
            }
            .labelStyle(.iconOnly)
            .disabled(current == cards.count - 1)
            .accessibilityIdentifier("decision-dock-next")
          }
          .buttonStyle(.borderless)
        }
        BoundedScrollView(
          maxHeight: layoutWidth == .compact
            ? Theme.Control.compactDockHeight : Theme.Control.dockHeight
        ) {
          DecisionCardView(
            card: card, phase: state.phase(of: card), isReadOnly: state.header.readOnly,
            respond: actions.respond.map { respond in { respond(card, $0) } },
            validate: actions.validateForm.map { validate in { validate(card, $0) } },
            draft: drafts.binding(card.id)
          )
          // The same card also shows inline in the transcript; the dock's copy has its own ids.
          .environment(\.decisionIDPrefix, "dock-")
          .id(card.id)
        }
        // With a single card the dock is just this scroll view, which then carries
        // `decision-dock` instead.
        .accessibilityIdentifier("decision-dock-scroll")
      }
      .padding(.top, Theme.Spacing.small)
      .readingColumn()
      .environment(
        \.openURL,
        OpenURLAction { url in
          if let open = actions.openURL {
            open(url)
            return .handled
          }
          return .systemAction
        }
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Pending requests")
      .accessibilityIdentifier("decision-dock")
      .onChange(of: cards.map(\.id)) { _, ids in
        drafts.drafts = drafts.drafts.filter { ids.contains($0.key) }
      }
    }
  }
}
