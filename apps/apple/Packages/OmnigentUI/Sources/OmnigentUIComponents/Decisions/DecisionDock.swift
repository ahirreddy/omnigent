public import SwiftUI

/// Pending and just-answered decision cards, docked above the composer so they can never be
/// scrolled out of view. Several cards page with a counter; form drafts are kept per card.
public struct DecisionDock: View {
  private let state: ConversationViewState
  private let actions: ConversationActions

  @State private var index = 0
  @State private var drafts: [String: FormDraft] = [:]
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
      VStack(alignment: .leading, spacing: 8) {
        if cards.count > 1 {
          HStack(spacing: 8) {
            Label(headline(cards: cards), systemImage: "hand.raised.fill")
              .font(.caption.weight(.semibold))
              .foregroundStyle(Theme.attention)
            Spacer()
            Button("Previous Request", systemImage: "chevron.left") { index = max(0, current - 1) }
              .labelStyle(.iconOnly)
              .disabled(current == 0)
            Text("\(current + 1) of \(cards.count)")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            Button("Next Request", systemImage: "chevron.right") {
              index = min(cards.count - 1, current + 1)
            }
            .labelStyle(.iconOnly)
            .disabled(current == cards.count - 1)
          }
          .buttonStyle(.borderless)
        }
        BoundedScrollView(maxHeight: layoutWidth == .compact ? 340 : 460) {
          DecisionCardView(
            card: card, phase: state.phase(of: card), isReadOnly: state.header.readOnly,
            respond: actions.respond.map { respond in { respond(card, $0) } },
            validate: actions.validateForm.map { validate in { validate(card, $0) } },
            draft: Binding(
              get: { drafts[card.id, default: FormDraft()] },
              set: { drafts[card.id] = $0 })
          )
          .id(card.id)
        }
      }
      .padding(.horizontal, layoutWidth == .compact ? 10 : 16)
      .padding(.top, 8)
      .frame(maxWidth: Theme.transcriptWidth)
      .frame(maxWidth: .infinity)
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
        drafts = drafts.filter { ids.contains($0.key) }
      }
    }
  }
}
