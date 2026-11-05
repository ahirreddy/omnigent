import SwiftUI

/// Where previous and next user message go, from the rows on screen (web `UserMessageNav`).
nonisolated enum TranscriptNavigation {
  /// A direction to move.
  enum Direction {
    /// The user message above the top of the screen.
    case previous
    /// The user message below the top of the screen.
    case next
  }

  /// The user message to move to.
  /// - Parameters:
  ///   - direction: Up or down.
  ///   - order: Every rendered segment id, top to bottom.
  ///   - userMessages: The ids in `order` that are user messages.
  ///   - visible: The ids on screen, in any order.
  /// - Returns: The target id, or `nil` when there is none in that direction.
  static func target(
    _ direction: Direction, order: [String], userMessages: Set<String>, visible: Set<String>
  ) -> String? {
    let top = order.firstIndex { visible.contains($0) }
    let users = order.indices.filter { userMessages.contains(order[$0]) }
    switch direction {
    case .previous:
      guard let top else { return users.last.map { order[$0] } }
      return users.last { $0 < top }.map { order[$0] }
    case .next:
      guard let top else { return nil }
      return users.first { $0 > top }.map { order[$0] }
    }
  }

  /// The segment ids that are user messages.
  static func userMessages(_ entries: [SegmentEntry]) -> Set<String> {
    Set(
      entries.compactMap { entry in
        if case .item(.message(let row)) = entry.segment, row.role == .user { return entry.id }
        return nil
      })
  }
}

/// Scroll facts the transcript acts on but never renders, so updating them on every scroll does
/// not re-render the rows.
@MainActor
final class TranscriptReadingPosition {
  /// The segment ids on screen.
  var visible: Set<String> = []
  /// The top segment when older history was requested; it is put back at the top once the
  /// older rows land above it.
  var prependAnchor: String?
  /// Older history was requested and its rows have not landed yet.
  var awaitsPage = false
  /// Jump to top is paging in the rest of the history first.
  var seeksTop = false

  /// Another session opened.
  func reset() {
    visible = []
    prependAnchor = nil
    awaitsPage = false
    seeksTop = false
  }
}

/// Jump to top and previous and next user message, at the transcript's trailing edge.
struct TranscriptNavigator: View {
  let jumpToTop: () -> Void
  let previous: () -> Void
  let next: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      button(
        "Jump to top", symbol: "arrow.up.to.line", id: "transcript-jump-top", action: jumpToTop)
      button(
        "Previous message", shortcut: "\u{2318}\u{2325}\u{2191}", symbol: "chevron.up",
        id: "transcript-previous-message", action: previous
      )
      .keyboardShortcut(AppShortcuts.previousMessage)
      button(
        "Next message", shortcut: "\u{2318}\u{2325}\u{2193}", symbol: "chevron.down",
        id: "transcript-next-message", action: next
      )
      .keyboardShortcut(AppShortcuts.nextMessage)
    }
    .font(Theme.Typography.label)
    .glassSurface(in: Capsule(), isInteractive: true)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Message navigation")
  }

  private func button(
    _ title: String, shortcut: String? = nil, symbol: String, id: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(width: Theme.Control.target, height: Theme.Control.target)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .help(shortcut.map { "\(title) (\($0))" } ?? title)
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
  }
}
