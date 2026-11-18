import SwiftUI

/// What a reasoning row shows, in both transcript styles.
nonisolated enum ReasoningText {
  /// The thought's text, when it has any to show.
  static func text(_ activity: Activity) -> String? {
    guard let text = activity.detail("summary"),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return text
  }

  /// The first prose line a settled thought previews, which the core puts in its summary;
  /// `nil` while it streams or when no line has prose.
  static func preview(_ activity: Activity, isStreaming: Bool) -> String? {
    guard !isStreaming, text(activity) != nil, !activity.summary.isEmpty else { return nil }
    return activity.summary
  }
}

/// Reasoning opens while it streams and folds when it settles, unless the reader chose. A
/// settled thought previews its first line ("Thinking: …"), else the header names how long it
/// thought when this view saw it stream; one with nothing to show does not open. As the web's.
struct ReasoningRowView: View {
  let row: Row
  let activity: Activity
  // No choice follows the stream: open while streaming. A new stream clears the reader's choice.
  @RowDisclosure private var disclosure
  @State private var startedAt: Date?
  @State private var duration: TimeInterval?

  private var disclosureKey: String { "reasoning-\(row.id)" }
  private var isExpanded: Bool {
    canExpand && (disclosure.choice(disclosureKey) ?? row.isStreaming)
  }
  private var canExpand: Bool { row.isStreaming || ReasoningText.text(activity) != nil }

  static func title(isStreaming: Bool, duration: TimeInterval?) -> String {
    if isStreaming { return "Thinking\u{2026}" }
    guard let duration else { return "Thought for a few seconds" }
    return "Thought for \(duration.formatted(.number.precision(.fractionLength(1)))) seconds"
  }

  var body: some View {
    let preview = ReasoningText.preview(activity, isStreaming: row.isStreaming)
    VStack(alignment: .leading, spacing: 0) {
      ExpandableHeader(
        isExpanded: Binding(
          get: { isExpanded }, set: { disclosure.choose($0, for: disclosureKey) }),
        systemImage: "brain",
        title: preview ?? Self.title(isStreaming: row.isStreaming, duration: duration),
        titleLead: preview == nil ? nil : "Thinking:", titleLineLimit: preview == nil ? 2 : 1,
        isEnabled: canExpand, identifier: "reasoning-toggle-\(row.id)"
      ) {
        if row.isStreaming { LiveIndicator(color: .secondary) }
      }
      .onChange(of: row.isStreaming, initial: true) { _, streaming in
        if streaming {
          if disclosure.choice(disclosureKey) != nil { disclosure.forget(disclosureKey) }
          if startedAt == nil { startedAt = Date() }
        } else if let startedAt, duration == nil {
          duration = Date().timeIntervalSince(startedAt)
        }
      }
      if isExpanded {
        MarkdownView(ReasoningText.text(activity) ?? "", isStreaming: row.isStreaming)
          .font(.callout)
          .foregroundStyle(.secondary)
          .padding(.leading, Theme.Spacing.section)
          .padding(.trailing, Theme.Spacing.small)
          .padding(.bottom, Theme.Spacing.small)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reasoning-\(row.id)")
  }
}
