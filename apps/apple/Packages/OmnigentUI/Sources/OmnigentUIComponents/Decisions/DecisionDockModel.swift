import SwiftUI

/// The dock's choices, kept out of the view so they can be tested.
struct DecisionDockModel {
  /// Rows shown before "Show N more".
  static let compactLimit = 3
  /// On a phone: one actionable request and the count.
  static let phoneCompactLimit = 1

  let state: ConversationViewState
  let selectedID: String?
  let isExpanded: Bool
  let layoutWidth: LayoutWidth
  /// The inline cards on screen; the dock leaves those to the transcript.
  var inline = InlineDecisionVisibility()

  /// Every card, unanswered first, so a pending card is always on top. The iPhone sheet lists
  /// these.
  var cards: [DecisionCard] {
    state.decisions.filter { !$0.answered } + state.decisions.filter(\.answered)
  }

  /// The cards the dock answers: every card except those on screen inline.
  var dockCards: [DecisionCard] { cards.filter { !inline.onScreen.contains($0.id) } }

  /// Pending cards answered inline right now.
  var aboveCount: Int { cards.count { inline.onScreen.contains($0.id) } }

  var compactLimit: Int { layoutWidth == .compact ? Self.phoneCompactLimit : Self.compactLimit }

  var compactCards: [DecisionCard] { Array(dockCards.prefix(compactLimit)) }

  var hiddenCount: Int { max(0, dockCards.count - compactLimit) }

  /// The selected dock card, else the first pending one.
  var selected: DecisionCard? {
    dockCards.first { $0.id == selectedID } ?? dockCards.first
  }

  var headline: String {
    let pending = state.pendingDecisions.count
    if pending == cards.count {
      return "\(pending) \(pending == 1 ? "request needs" : "requests need") you"
    }
    return "\(pending) of \(cards.count) requests \(pending == 1 ? "needs" : "need") you"
  }

  /// The headline, plus how many are answered above when the dock lists the rest.
  var dockHeadline: String {
    aboveCount == 0 ? headline : "\(headline) \u{00B7} \(aboveCount) above"
  }

  /// The agent, or "Subagent" for a card mirrored from a child session.
  func context(for card: DecisionCard) -> String? {
    if let child = SubagentGroup.context(for: card, in: state) { return child }
    return state.header.settings.map { HarnessAppearance(harness: $0.harness).label }
  }

  func canRespond(_ card: DecisionCard, hasResponder: Bool) -> Bool {
    guard hasResponder, !state.header.readOnly else { return false }
    switch state.phase(of: card) {
    case .pending, .failed: return true
    case .resolving, .answered: return false
    }
  }

  /// The one Approve that answers Command-Return, on whichever surface shows it: the selected
  /// approval when the dock is expanded, else the first pending approval whose Approve is in
  /// view, inline or in a dock row. Plan reviews never take it.
  var shortcutTarget: DecisionShortcutTarget? {
    if isExpanded, let selected, isPlainApproval(selected) {
      return DecisionShortcutTarget(cardID: selected.id, surface: .dock)
    }
    for card in cards where isPlainApproval(card) {
      if inline.onScreen.contains(card.id) {
        if inline.approvable.contains(card.id) {
          return DecisionShortcutTarget(cardID: card.id, surface: .inline)
        }
      } else if !isExpanded, DecisionSummary(card).answersInline,
        compactCards.contains(where: { $0.id == card.id })
      {
        return DecisionShortcutTarget(cardID: card.id, surface: .dock)
      }
    }
    return nil
  }

  var shortcutCardID: String? { shortcutTarget?.cardID }

  private func isPlainApproval(_ card: DecisionCard) -> Bool {
    guard case .approval = card.kind, card.permissions.plan == nil else { return false }
    return canRespond(card, hasResponder: true)
  }
}
