import SwiftUI
import UniformTypeIdentifiers

extension ProjectBoardLane {
  /// The lane's color, after the sidebar's marks: the theme's warning, running, unread and
  /// success colors, and the secondary text color for drafts.
  var tint: ThemeColor {
    switch self {
    case .draft: ThemeColor.secondary
    case .needsAttention: Theme.warning
    case .working: Theme.running
    case .unread: Theme.unread
    case .done: Theme.success
    }
  }
}

/// A card dragged across the board: its payload, so a lane knows which card it is.
nonisolated enum ProjectBoardDrag {
  static let prefix = "omnigent-board-card:"

  /// The text a drag of the card carries.
  static func payload(_ cardID: String) -> String { prefix + cardID }

  /// The card a payload names; `nil` for other text.
  static func cardID(_ payload: String) -> String? {
    guard payload.hasPrefix(prefix) else { return nil }
    let id = String(payload.dropFirst(prefix.count))
    return id.isEmpty ? nil : id
  }
}

/// A lane as a drop target: it takes a card the core lets move there (Unread and Done, both
/// ways), and refuses the rest, which snap back.
struct ProjectBoardLaneDrop: DropDelegate {
  let lane: ProjectBoardLane
  let state: ProjectBoardViewState
  let actions: ProjectBoardActions
  @Binding var dragging: String?
  @Binding var targeted: ProjectBoardLane?

  /// The card `cardID` names when this lane takes it.
  func card(_ cardID: String?) -> ProjectBoardCard? {
    guard let cardID, let card = state.card(cardID), card.lane != lane, actions.drop != nil,
      actions.accepts(card.lane, lane)
    else { return nil }
    return card
  }

  /// Drops `cardID` here: the board marks it read or unread. Returns whether the lane took it.
  @discardableResult
  func drop(_ cardID: String?) -> Bool {
    defer {
      dragging = nil
      targeted = nil
    }
    guard let card = card(cardID), let drop = actions.drop else { return false }
    drop(card, lane)
    return true
  }

  func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

  func dropEntered(info: DropInfo) { targeted = lane }

  func dropExited(info: DropInfo) {
    if targeted == lane { targeted = nil }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: card(dragging) == nil ? .forbidden : .move)
  }

  func performDrop(info: DropInfo) -> Bool { drop(dragging) }
}

/// One lane beside the others: its title, symbol and count over its cards, which scroll on their
/// own. While a card is dragged, a lane that would take it is outlined.
struct ProjectBoardLaneView<Card: View>: View {
  let column: ProjectBoardColumn
  let emptyLabel: String
  /// The lane takes the card being dragged.
  let accepts: Bool
  /// A dragged card is over it.
  let isTargeted: Bool
  /// Room under the last card, so it scrolls clear of the floating composer.
  let bottomClearance: CGFloat
  /// A pager's tab names the lane already, so it shows no title.
  var showsHeader = true
  @ViewBuilder let card: (ProjectBoardCard) -> Card

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showsHeader { header }
      ScrollView {
        LazyVStack(spacing: Theme.Spacing.small + 2) {
          ForEach(column.cards) { card in
            self.card(card)
          }
          if column.cards.isEmpty {
            Text(emptyLabel)
              .font(.callout)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, Theme.Spacing.extraSmall)
              .accessibilityIdentifier("project-board-lane-empty-\(column.lane.rawValue)")
          }
        }
        .padding(.horizontal, showsHeader ? Theme.Spacing.small : Theme.Spacing.large)
        .padding(.top, showsHeader ? 0 : Theme.Spacing.medium)
        .padding(.bottom, Theme.Spacing.small + bottomClearance)
      }
      .scrollIndicators(.automatic)
    }
    .frame(maxHeight: .infinity, alignment: .top)
    .background {
      // A pager's lane is the page, edge to edge.
      RoundedRectangle(
        cornerRadius: showsHeader ? Theme.Radius.large : 0, style: .continuous
      )
      .fill(
        isTargeted && accepts
          ? AnyShapeStyle(column.lane.tint.opacity(0.12)) : AnyShapeStyle(ProjectBoardSurface.lane)
      )
    }
    .overlay {
      if accepts {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
          .strokeBorder(
            isTargeted ? AnyShapeStyle(column.lane.tint) : AnyShapeStyle(.secondary.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1.5, dash: isTargeted ? [] : [5, 4])
          )
          .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(column.lane.title)
    .accessibilityIdentifier("project-board-lane-\(column.lane.rawValue)")
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.small) {
      Label {
        Text(column.lane.title)
      } icon: {
        Image(systemName: column.lane.systemImage).foregroundStyle(column.lane.tint)
      }
      .font(.callout.weight(.semibold))
      Spacer(minLength: Theme.Spacing.extraSmall)
      Text("\(column.cards.count)")
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel(
          column.cards.count == 1 ? "1 session" : "\(column.cards.count) sessions")
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.top, Theme.Spacing.medium)
    .padding(.bottom, Theme.Spacing.small)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A phone's board: one lane at a time, picked from a strip of lanes with their counts or by
/// swiping; it opens on the first lane with cards.
struct ProjectBoardLanePager<Lane: View>: View {
  let columns: [ProjectBoardColumn]
  @Binding var lane: ProjectBoardLane
  @ViewBuilder let content: (ProjectBoardColumn) -> Lane

  var body: some View {
    VStack(spacing: 0) {
      strip
      Divider()
      #if os(iOS)
        TabView(selection: $lane) {
          ForEach(columns) { column in
            content(column).tag(column.lane)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
      #else
        if let column = columns.first(where: { $0.lane == lane }) { content(column) }
      #endif
    }
  }

  private var strip: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Theme.Spacing.small) {
          ForEach(columns) { column in
            chip(column).id(column.lane)
          }
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.small)
      }
      .onChange(of: lane, initial: true) { _, lane in
        withAnimation { proxy.scrollTo(lane, anchor: .center) }
      }
    }
  }

  private func chip(_ column: ProjectBoardColumn) -> some View {
    let selected = column.lane == lane
    return Button {
      withAnimation { lane = column.lane }
    } label: {
      HStack(spacing: Theme.Spacing.extraSmall) {
        Image(systemName: column.lane.systemImage)
          .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(column.lane.tint))
          .accessibilityHidden(true)
        Text(column.lane.title)
        Text("\(column.cards.count)")
          .monospacedDigit()
          .opacity(0.7)
      }
      .font(.subheadline.weight(selected ? .semibold : .regular))
      .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
      .padding(.horizontal, Theme.Spacing.medium)
      .padding(.vertical, Theme.Spacing.small - 2)
      // The selected lane in the window's accent, as a selected filter chip is.
      .background(Capsule().fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quinary)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("project-board-lane-tab-\(column.lane.rawValue)")
  }
}

/// Where arrow keys move the focus among the cards: up and down within a lane, left and right
/// to the nearest card at the same height in the next lane that has cards.
nonisolated enum ProjectBoardFocus {
  enum Direction {
    case above, below, left, right

    /// The direction an arrow key moves; `nil` for other keys.
    init?(_ key: KeyEquivalent) {
      switch key {
      case .upArrow: self = .above
      case .downArrow: self = .below
      case .leftArrow: self = .left
      case .rightArrow: self = .right
      default: return nil
      }
    }
  }

  /// The card after `current` in `direction`; the first card when nothing is focused.
  static func next(
    from current: String?, _ direction: Direction, in columns: [ProjectBoardColumn]
  ) -> String? {
    let lanes = columns.map { $0.cards.map(\.id) }
    guard let current,
      let laneIndex = lanes.firstIndex(where: { $0.contains(current) }),
      let row = lanes[laneIndex].firstIndex(of: current)
    else { return lanes.first { !$0.isEmpty }?.first }
    let lane = lanes[laneIndex]
    switch direction {
    case .above: return lane[max(0, row - 1)]
    case .below: return lane[min(lane.count - 1, row + 1)]
    case .left, .right:
      let step = direction == .left ? -1 : 1
      var index = laneIndex + step
      while lanes.indices.contains(index) {
        if !lanes[index].isEmpty { return lanes[index][min(row, lanes[index].count - 1)] }
        index += step
      }
      return current
    }
  }
}

/// The board's fills: lanes a step off the window's canvas, and cards a step lighter than their
/// lane in either appearance, so a card stands off its lane in dark mode too.
enum ProjectBoardSurface {
  /// A lane's well.
  static var lane: Color { Color.primary.opacity(0.045) }

  /// A card's fill: the theme's surface, lightened.
  static func card(cornerRadius: CGFloat) -> some View {
    CardFill(cornerRadius: cornerRadius)
  }

  private struct CardFill: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
      let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      shape.fill(ThemeColor.surface)
        .overlay(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.8)))
    }
  }
}

/// The lanes' measures beside one another.
enum ProjectBoardLayout {
  static var laneSpacing: CGFloat { Theme.Spacing.medium }

  /// Room the floating composer covers at the foot of each lane.
  static var composerClearance: CGFloat { 180 }

  /// Each lane's width: the room shared five ways, from 220 up to the web's 456 points.
  static func laneWidth(for available: CGFloat) -> CGFloat {
    let count = CGFloat(ProjectBoardLane.allCases.count)
    let room = available - 2 * Theme.Spacing.large - (count - 1) * laneSpacing
    return min(456, max(220, room / count))
  }
}
