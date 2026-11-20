public import SwiftUI

/// One session the recent-sessions switcher offers.
nonisolated public struct RecentSessionRow: Hashable, Sendable, Identifiable {
  /// The session.
  public var id: String
  /// Its title.
  public var title: String
  /// Its agent: "Claude Code", "Codex".
  public var agent: String

  /// Creates a row.
  public init(id: String, title: String, agent: String) {
    self.id = id
    self.title = title
    self.agent = agent
  }
}

/// The switcher Control-Tab holds open (web `RecentSessionsSwitcher`): the most recently active
/// sessions, one selected; releasing Control opens it.
nonisolated public struct RecentSessionsSwitcherState: Hashable, Sendable {
  /// The sessions, most recently active first.
  public var rows: [RecentSessionRow]
  /// The selected row.
  public var selected: Int

  /// How many sessions the switcher offers.
  public static let limit = 5

  /// The switcher as Control-Tab (`offset` 1) or Control-Shift-Tab (`-1`) opens it: the row after
  /// the open session, or before it, wrapping; the first, or the last, when the open session
  /// isn't listed. `nil` with no rows.
  /// - Parameters:
  ///   - rows: The sessions.
  ///   - active: The open session.
  ///   - offset: The direction.
  public init?(rows: [RecentSessionRow], active: String?, offset: Int) {
    guard !rows.isEmpty else { return nil }
    self.rows = rows
    if let index = rows.firstIndex(where: { $0.id == active }) {
      selected = Self.wrapped(index + offset, count: rows.count)
    } else {
      selected = offset < 0 ? rows.count - 1 : 0
    }
  }

  /// Moves the selection by `offset`, wrapping.
  public mutating func step(by offset: Int) {
    selected = Self.wrapped(selected + offset, count: rows.count)
  }

  /// The selected session.
  public var selectedID: String? { rows.indices.contains(selected) ? rows[selected].id : nil }

  private static func wrapped(_ index: Int, count: Int) -> Int {
    ((index % count) + count) % count
  }
}

/// What Control-Tab does in the key window: opens the recent-sessions switcher, or moves its
/// selection by the given offset.
public struct RecentSessionsAction {
  /// Opens the switcher or moves its selection: `1` down, `-1` up.
  public let step: @MainActor (Int) -> Void

  /// Creates the action.
  /// - Parameter step: Opens the switcher or moves its selection.
  public init(_ step: @escaping @MainActor (Int) -> Void) {
    self.step = step
  }
}

extension FocusedValues {
  /// The key window's recent-sessions switcher (the Mac's Control-Tab).
  @Entry public var recentSessions: RecentSessionsAction?
}

/// The recent-sessions switcher's panel: a heading, the sessions with their agents, and how to
/// use it, drawn as a floating Mac panel near the top of the window.
public struct RecentSessionsSwitcherView: View {
  let state: RecentSessionsSwitcherState
  let select: @MainActor (Int) -> Void
  let commit: @MainActor () -> Void

  /// Creates the panel.
  /// - Parameters:
  ///   - state: The sessions and the selection.
  ///   - select: Selects a row, as hovering does.
  ///   - commit: Opens the selected session, as a click does.
  public init(
    state: RecentSessionsSwitcherState, select: @escaping @MainActor (Int) -> Void,
    commit: @escaping @MainActor () -> Void
  ) {
    self.state = state
    self.select = select
    self.commit = commit
  }

  /// The panel.
  public var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Text("Recent Sessions")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: Theme.Spacing.tiny) {
        ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
          Button {
            select(index)
            commit()
          } label: {
            rowView(row, selected: index == state.selected)
          }
          .buttonStyle(.plain)
          .onHover { if $0 { select(index) } }
        }
      }
      Text("Press Tab to cycle \u{00B7} Release Control to switch \u{00B7} Esc to cancel")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: 480)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator)
    )
    .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recent-sessions-switcher")
  }

  private func rowView(_ row: RecentSessionRow, selected: Bool) -> some View {
    HStack(spacing: Theme.Spacing.medium) {
      Text(row.title).lineLimit(1)
      Spacer(minLength: Theme.Spacing.medium)
      Text(row.agent)
        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        .lineLimit(1)
    }
    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.extraSmall)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
    )
    .contentShape(Rectangle())
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("recent-session-\(row.id)")
  }
}
