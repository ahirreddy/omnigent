import Foundation
import SwiftUI

/// The live turn's elapsed time, shared by the chat and CLI styles: "Working · 12s" in chat and
/// "Working (12s · esc to interrupt)" in CLI, as the Codex CLI shows it.
nonisolated enum TurnElapsed {
  /// When the running turn started: the store's time, else the timestamp of the message that
  /// started it. `nil` when neither is known, so no wrong time is shown.
  /// - Parameter state: The conversation.
  /// - Returns: The start, while a turn runs.
  static func start(in state: ConversationViewState) -> Date? {
    guard state.header.status == .running else { return nil }
    if let started = state.turnStartedAt { return started }
    guard let prompt = state.rows.last(where: { $0.role == .user }) else { return nil }
    return state.timestamps[prompt.id]
  }

  /// "12s" or "1m 4s" since `start`.
  static func elapsed(since start: Date, now: Date) -> String {
    TurnLayout.duration(max(0, now.timeIntervalSince(start)).rounded(.down))
  }

  /// "Working · 12s", or "Working" without a start.
  static func label(since start: Date?, now: Date) -> String {
    guard let start else { return "Working" }
    return "Working \u{00B7} \(elapsed(since: start, now: now))"
  }

  /// "Worked for 3s" under a settled answer.
  static func worked(_ duration: TimeInterval) -> String {
    "Worked for \(TurnLayout.duration(duration))"
  }
}

/// Re-renders its content once a second while a start is known; otherwise once.
struct ElapsedTimeline<Content: View>: View {
  let start: Date?
  @ViewBuilder let content: (Date) -> Content

  var body: some View {
    if let start {
      TimelineView(.periodic(from: start, by: 1)) { context in content(context.date) }
    } else {
      content(Date())
    }
  }
}

/// "Worked for 3s" under a settled answer, with when it finished on hover.
struct WorkedForLabel: View {
  let duration: TimeInterval
  let finished: Date?

  var body: some View {
    Text(TurnElapsed.worked(duration))
      .font(.caption)
      .foregroundStyle(.secondary)
      .help(finished.map { "Finished \(MessageTimestamp.format($0, now: Date()))" } ?? "")
      .accessibilityIdentifier("worked-for")
  }
}

/// A turn's status line: a glyph in a fixed column, then the text, so "Working", "Responding",
/// "Preparing a reply" and "Interrupted" share one indent, one size and one color.
struct TurnStatusRow<Glyph: View, Caption: View>: View {
  @ViewBuilder let glyph: Glyph
  @ViewBuilder let label: Caption

  /// The glyph column: as wide as the typing dots.
  static var glyphWidth: CGFloat { 26 }

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      glyph
        .frame(width: Self.glyphWidth, alignment: .leading)
        .accessibilityHidden(true)
      label
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }
}
