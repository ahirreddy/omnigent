import Observation
import SwiftUI

/// One user turn on the turn rail: the user message's segment id and its text.
nonisolated struct TranscriptTurn: Hashable, Sendable, Identifiable {
  let id: String
  let text: String
}

/// What the turn rail shows. Only the rail reads it, so the transcript publishes turns and the
/// active turn here without re-rendering itself.
@MainActor
@Observable
final class TurnRailModel {
  private(set) var turns: [TranscriptTurn] = []
  /// The turn owning the middle of the screen.
  private(set) var activeID: String?

  func setTurns(_ turns: [TranscriptTurn]) {
    if turns != self.turns { self.turns = turns }
  }

  func setActive(_ id: String?) {
    if id != activeID { activeID = id }
  }

  /// The turn owning the middle of the visible rows: the nearest user turn at or above it, or
  /// the first turn when every visible row sits above them all (the web's `activeTurnId`).
  /// - Parameters:
  ///   - order: Every rendered row id, top to bottom.
  ///   - turns: The ids in `order` that are user turns.
  ///   - visible: The ids on screen.
  /// - Returns: The active turn, or `nil` with nothing on screen.
  nonisolated static func activeTurn(
    order: [String], turns: Set<String>, visible: Set<String>
  ) -> String? {
    let shown = order.indices.filter { visible.contains(order[$0]) }
    guard !shown.isEmpty else { return nil }
    let middle = shown[shown.count / 2]
    if let owner = order[...middle].last(where: turns.contains) { return owner }
    return order.first(where: turns.contains)
  }

  /// The leading text of the reply after `turnID`: its first non-empty assistant message.
  /// - Parameters:
  ///   - turnID: The user turn.
  ///   - entries: The transcript's segments.
  /// - Returns: Up to 240 characters, or `""` without a reply yet.
  nonisolated static func responsePreview(after turnID: String, in entries: [SegmentEntry])
    -> String
  {
    guard let start = entries.firstIndex(where: { $0.id == turnID }) else { return "" }
    for entry in entries[(start + 1)...] {
      guard case .item(.message(let row)) = entry.segment else { continue }
      if row.role == .user { return "" }
      let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if row.role == .assistant, !text.isEmpty { return String(text.prefix(240)) }
    }
    return ""
  }
}

/// The web's turn rail: a minimap at the transcript's leading edge with one tick per user turn.
/// Pointing at a tick previews the turn; clicking scrolls to it. Left out at compact widths (the
/// web hides it on phones). Scrolling the rail to its top pages in older history.
struct TurnRail: View {
  let model: TurnRailModel
  let jump: (String) -> Void
  let preview: (String) -> String
  let loadOlder: () -> Void

  @State private var hoveredID: String?
  @State private var previewY: CGFloat = 0
  @State private var tracker = TurnRailScroll()

  /// Each tick's band, the whole of it clickable.
  static let pitch: CGFloat = 8
  /// The faded inset above and below the ticks.
  static let fade: CGFloat = 24
  static let maxHeight: CGFloat = 288

  var body: some View {
    // A tick is not built again for a new jump, so it reaches the latest one through here.
    tracker.jump = jump
    return content
  }

  @ViewBuilder private var content: some View {
    if model.turns.count >= 2 {
      rail
        .overlay(alignment: .topLeading) { previewBox }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Turns")
        .accessibilityIdentifier("turn-rail")
    }
  }

  private var rail: some View {
    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(model.turns) { turn in
            TurnTick(
              turn: turn, isHovered: hoveredID == turn.id,
              isActive: hoveredID == nil && model.activeID == turn.id
            ) { [tracker] in tracker.jump(turn.id) }
            .id(turn.id)
          }
        }
        .padding(.vertical, Self.fade)
        .padding(.leading, Theme.Spacing.small)
      }
      .scrollIndicators(.hidden)
      .frame(width: 28)
      .frame(height: railHeight)
      .mask(TurnRailFadeMask())
      .onScrollGeometryChange(for: CGFloat.self) {
        $0.contentOffset.y
      } action: { _, offset in
        tracker.offset = offset
        // Scrolling the rail up to its top pages in older history, as the web's rail.
        if offset < 40, tracker.isInteracting { loadOlder() }
      }
      .onScrollPhaseChange { _, phase in tracker.isInteracting = phase.isScrolling }
      .onContinuousHover { phase in hover(phase) }
      .onChange(of: model.activeID) { _, id in
        LoopProbe.record("turn rail active", id ?? "none")
        guard let id, hoveredID == nil else { return }
        proxy.scrollTo(id, anchor: .center)
      }
    }
  }

  /// The ticks' height, up to ``maxHeight``; past it the rail scrolls.
  private var railHeight: CGFloat {
    min(Self.maxHeight, CGFloat(model.turns.count) * Self.pitch + 2 * Self.fade)
  }

  @ViewBuilder private var previewBox: some View {
    if let hoveredID, let turn = model.turns.first(where: { $0.id == hoveredID }) {
      TurnPreview(text: turn.text, response: preview(turn.id))
        .alignmentGuide(.top) { $0[VerticalAlignment.center] - previewY }
        .alignmentGuide(.leading) { _ in -32 }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  /// Picks the tick under the pointer from its height in the rail and the rail's scroll.
  private func hover(_ phase: HoverPhase) {
    guard case .active(let location) = phase else {
      if hoveredID != nil { hoveredID = nil }
      return
    }
    let index = Int(((location.y + tracker.offset - Self.fade) / Self.pitch).rounded(.down))
    guard model.turns.indices.contains(index) else {
      if hoveredID != nil { hoveredID = nil }
      return
    }
    let id = model.turns[index].id
    if id != hoveredID {
      hoveredID = id
      previewY = Self.fade + (CGFloat(index) + 0.5) * Self.pitch - tracker.offset
    }
  }
}

/// The rail's scroll offset, whether the reader is scrolling it and the transcript's latest
/// jump, read by the hover, the paging and the ticks without re-rendering the rail.
@MainActor
private final class TurnRailScroll {
  var offset: CGFloat = 0
  var isInteracting = false
  var jump: (String) -> Void = { _ in }
}

extension ScrollPhase {
  fileprivate var isScrolling: Bool { self == .tracking || self == .interacting }
}

/// One tick: a short dash, darker for the active or hovered turn and wider on hover.
private struct TurnTick: View, Equatable {
  let turn: TranscriptTurn
  let isHovered: Bool
  let isActive: Bool
  /// Left out of `==`, so it must do the same thing however old the tick is.
  let action: () -> Void

  nonisolated static func == (left: Self, right: Self) -> Bool {
    left.turn == right.turn && left.isHovered == right.isHovered
      && left.isActive == right.isActive
  }

  var body: some View {
    Button(action: action) {
      Capsule()
        .fill(isHovered || isActive ? Color.primary : Color.secondary.opacity(0.4))
        .frame(width: isHovered ? 16 : 7, height: 2)
        .frame(width: 20, height: TurnRail.pitch, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .animation(.easeOut(duration: 0.15), value: isHovered)
    .accessibilityLabel("Jump to: \(turn.text.prefix(80))")
    .accessibilityAddTraits(isActive ? .isSelected : [])
    .accessibilityIdentifier("turn-rail-tick-\(turn.id)")
  }
}

/// The hover preview: the user's message, then the start of the reply.
private struct TurnPreview: View {
  let text: String
  let response: String

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
      Text(text.isEmpty ? "(no text)" : text)
        .font(.callout.weight(.medium))
        .lineLimit(2)
      if !response.isEmpty {
        Text(response).font(.callout).foregroundStyle(.secondary).lineLimit(3)
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .frame(width: 320, alignment: .leading)
    .background(.background, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(.separator)
    }
    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    .accessibilityHidden(true)
  }
}

/// Fades the ticks out at the rail's top and bottom edges, as the web's mask.
private struct TurnRailFadeMask: View {
  var body: some View {
    VStack(spacing: 0) {
      LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
        .frame(height: TurnRail.fade)
      Rectangle()
      LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
        .frame(height: TurnRail.fade)
    }
  }
}

/// Puts the ``TurnRail`` at the transcript's leading edge, vertically centered, wherever the
/// width is regular (Mac, iPad); compact widths leave it out, as the web does on phones.
struct TurnRailOverlay: ViewModifier {
  let model: TurnRailModel
  let jump: (String) -> Void
  let preview: (String) -> String
  let loadOlder: () -> Void
  @Environment(\.layoutWidth) private var layoutWidth

  func body(content: Content) -> some View {
    content.overlay(alignment: .leading) {
      if layoutWidth == .regular {
        TurnRail(model: model, jump: jump, preview: preview, loadOlder: loadOlder)
      }
    }
  }
}
