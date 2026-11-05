import SwiftUI

/// Reasoning opens while it streams and folds when it settles, unless the reader chose; the
/// header names how long it thought when this view saw it stream, as the web's.
struct ReasoningRowView: View {
  let row: Row
  let activity: Activity
  // `nil` follows the stream: open while streaming. A new stream clears the reader's choice.
  // swiftlint:disable:next discouraged_optional_boolean
  @State private var expandedOverride: Bool?
  @State private var startedAt: Date?
  @State private var duration: TimeInterval?

  private var isExpanded: Bool { expandedOverride ?? row.isStreaming }

  static func title(isStreaming: Bool, duration: TimeInterval?) -> String {
    if isStreaming { return "Thinking\u{2026}" }
    guard let duration else { return "Thought for a few seconds" }
    return "Thought for \(duration.formatted(.number.precision(.fractionLength(1)))) seconds"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExpandableHeader(
        isExpanded: Binding(get: { isExpanded }, set: { expandedOverride = $0 }),
        systemImage: "brain",
        title: Self.title(isStreaming: row.isStreaming, duration: duration),
        subtitle: isExpanded ? nil : activity.summary, identifier: "reasoning-toggle-\(row.id)"
      ) {
        if row.isStreaming { LiveIndicator(color: .secondary) }
      }
      .onChange(of: row.isStreaming, initial: true) { _, streaming in
        if streaming {
          if expandedOverride != nil { expandedOverride = nil }
          if startedAt == nil { startedAt = Date() }
        } else if let startedAt, duration == nil {
          duration = Date().timeIntervalSince(startedAt)
        }
      }
      if isExpanded {
        MarkdownView(activity.detail("summary") ?? activity.summary, isStreaming: row.isStreaming)
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
