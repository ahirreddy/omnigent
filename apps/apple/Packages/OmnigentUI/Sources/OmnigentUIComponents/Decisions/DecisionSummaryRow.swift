import SwiftUI

/// One request in one line, plus the agent or session: "Run `cargo test -p omnigent-core auth`"
/// · "Codex". When the whole payload fits, the row answers directly (Reject and Approve, or the
/// answers); anything substantial shows "Review", which opens the full card.
struct DecisionSummaryRow: View {
  let card: DecisionCard
  let phase: DecisionPhase
  let context: String?
  let canRespond: Bool
  /// Inline answers are offered (the compact dock); `false` in the expanded request list.
  let showsActions: Bool
  var isSelected = false
  let act: (DecisionResponse) -> Void
  let open: () -> Void
  @Environment(\.decisionIDPrefix) private var idPrefix
  @Environment(\.decisionShortcutCardID) private var shortcutCardID
  @Environment(\.layoutWidth) private var layoutWidth

  private var summary: DecisionSummary { DecisionSummary(card) }

  var body: some View {
    let summary = summary
    ViewThatFits(in: .horizontal) {
      HStack(spacing: Theme.Spacing.medium) {
        lead(summary)
        trailing(summary)
      }
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        lead(summary)
        HStack(spacing: Theme.Spacing.small) {
          Spacer(minLength: 0)
          trailing(summary)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("\(idPrefix)decision-row-\(card.id)")
  }

  private func lead(_ summary: DecisionSummary) -> some View {
    Button(action: open) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        DecisionStateGlyph(card: card, phase: phase)
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          SummaryText(summary: summary)
            .lineLimit(1)
            .truncationMode(.middle)
          if let secondary = secondaryLine(summary) {
            Text(secondary)
              .font(.caption)
              .foregroundStyle(isFailed ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.secondary))
              .lineLimit(layoutWidth == .compact ? 2 : 1)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(minHeight: Theme.Control.target)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, Theme.Spacing.extraSmall)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        .fill(isSelected ? AnyShapeStyle(ThemeColor.selection) : AnyShapeStyle(.clear))
    )
    .hoverHighlight()
    .accessibilityLabel(
      [summary.plain, secondaryLine(summary)].compactMap(\.self).joined(separator: ", ")
    )
    .accessibilityHint(showsActions ? "Shows the full request" : "Selects this request")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    .accessibilityIdentifier(
      showsActions
        ? "\(idPrefix)decision-open-\(card.id)" : "\(idPrefix)decision-select-\(card.id)")
  }

  @ViewBuilder private func trailing(_ summary: DecisionSummary) -> some View {
    switch phase {
    case .resolving:
      ProgressView().controlSize(.small).accessibilityLabel("Sending your response")
    case .answered(let text):
      Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    case .pending, .failed:
      if showsActions {
        if summary.answersInline { inlineActions } else { reviewButton }
      }
    }
  }

  @ViewBuilder private var inlineActions: some View {
    switch card.kind {
    case .approval:
      HStack(spacing: Theme.Spacing.small) {
        Button("Reject") { act(.decline) }
          .buttonStyle(.bordered)
          .tint(.primary)
          .disabled(!canRespond)
          .accessibilityIdentifier("\(idPrefix)approval-decline-\(card.id)")
        ApproveButton(
          title: "Approve", cardID: card.id, isEnabled: canRespond,
          ownsShortcut: shortcutCardID == card.id,
          identifier: "\(idPrefix)approval-approve-\(card.id)", controlSize: .regular,
          isProminent: shortcutCardID == nil || shortcutCardID == card.id
        ) { act(.approve) }
      }
      .fixedSize()
    case .choice(_, let options):
      HStack(spacing: Theme.Spacing.small) {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
          Button(option) { act(.answer(value: option)) }
            .buttonStyle(.bordered)
            .tint(.primary)
            .disabled(!canRespond)
            .accessibilityIdentifier("\(idPrefix)decision-option-\(card.id)-\(index)")
        }
      }
      .fixedSize()
    case .form, .unsupported:
      reviewButton
    }
  }

  private var reviewButton: some View {
    Button(action: open) {
      Label("Review", systemImage: "chevron.right")
        .labelStyle(TrailingIconLabelStyle())
    }
    .buttonStyle(.bordered)
    .tint(.primary)
    .accessibilityHint("Shows the full request")
    .accessibilityIdentifier("\(idPrefix)decision-review-\(card.id)")
  }

  private var isFailed: Bool {
    if case .failed = phase { return true }
    return false
  }

  private func secondaryLine(_ summary: DecisionSummary) -> String? {
    if case .failed(let message) = phase { return message }
    let parts = [summary.secondary, context].compactMap(\.self).filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
  }
}

/// The summary with its command or file name monospaced.
struct SummaryText: View {
  let summary: DecisionSummary

  var body: some View {
    if let code = summary.code {
      Text("\(summary.lead) \(Text(verbatim: code).font(Theme.codeFont))")
        .font(Theme.Typography.label)
    } else {
      Text(summary.lead).font(Theme.Typography.label)
    }
  }
}

/// Title first, then the icon ("Review ›").
struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      configuration.title
      configuration.icon.imageScale(.small)
    }
  }
}
