public import SwiftUI

// One decision surface at a time. A pending request is answered from its inline card while that
// card is on screen, and from the dock otherwise; the dock then shows it as one summary line.

/// Where a pending request's actions are shown.
nonisolated enum DecisionSurface: Hashable, Sendable {
  /// The card inline in the transcript (or a sub-agent group's row).
  case inline
  /// The dock above the composer (or its iPhone sheet).
  case dock
}

/// The one Approve that answers Command-Return, and the surface that shows it.
nonisolated struct DecisionShortcutTarget: Hashable, Sendable {
  let cardID: String
  let surface: DecisionSurface
}

/// An inline card's frame and its scroll view's visible bounds, both in global coordinates.
nonisolated struct InlineDecisionPlacement: Hashable, Sendable {
  var card: CGRect
  var viewport: CGRect
  /// The inline surface shows Approve without expanding (a full card, or a row answering in place).
  var showsApprove: Bool
}

/// The inline cards on screen, as the dock and the shortcut need them.
nonisolated struct InlineDecisionVisibility: Hashable, Sendable {
  var onScreen: Set<String> = []
  /// The on-screen cards whose inline surface shows Approve.
  var approvable: Set<String> = []

  /// Whether a card counts as on screen. It enters once half of it (or half the viewport, for a
  /// card taller than that) is visible above the bottom bar, and leaves below a fifth, so the
  /// dock resizing as a card crosses the line never makes it flicker. A sliver never counts
  /// (``minimumVisible``): over a short viewport the dock collapsing would scroll the card away
  /// and bring it back, without end.
  /// - Parameters:
  ///   - placement: The card and its viewport.
  ///   - bottomBarTop: The top of the dock and composer, which cover the viewport's bottom.
  ///   - wasOnScreen: The card counted as on screen before this change.
  /// - Returns: Whether it is on screen now.
  static func isOnScreen(
    _ placement: InlineDecisionPlacement, bottomBarTop: CGFloat?, wasOnScreen: Bool
  ) -> Bool {
    let top = placement.viewport.minY
    let bottom = min(placement.viewport.maxY, bottomBarTop ?? .infinity)
    guard bottom > top, placement.card.height > 0 else { return false }
    let visible = min(placement.card.maxY, bottom) - max(placement.card.minY, top)
    guard visible > 0 else { return false }
    let fraction = wasOnScreen ? 0.2 : 0.5
    let sliver = min(placement.card.height, wasOnScreen ? minimumVisible / 4 : minimumVisible)
    return visible >= max(min(placement.card.height, bottom - top) * fraction, sliver)
  }

  /// Points of a card that must show before it counts as on screen: its title and a row of
  /// actions. A quarter as many keep it there.
  static let minimumVisible: CGFloat = 88
}

/// Tracks which inline decision cards are on screen for one conversation. The transcript's
/// cards report their placement and the screen reports the bottom bar; the dock reads
/// ``visibility``, which only changes when a card enters or leaves.
@Observable
public final class DecisionSurfaces {
  private(set) var visibility = InlineDecisionVisibility()
  @ObservationIgnored private var placements: [String: InlineDecisionPlacement] = [:]
  @ObservationIgnored private var bottomBarTop: CGFloat?

  /// Creates an empty tracker.
  public init() {}

  /// Records where an inline card is, or that it left the transcript (`nil`).
  func report(_ cardID: String, placement: InlineDecisionPlacement?) {
    if placements[cardID] == placement { return }
    placements[cardID] = placement
    update()
  }

  /// Records the top of the dock and composer in global coordinates.
  func setBottomBarTop(_ top: CGFloat?) {
    if bottomBarTop == top { return }
    #if DEBUG
      LoopProbe.record(
        "decision bottom bar \(probeTag)",
        "top \(String(describing: bottomBarTop)) -> \(String(describing: top))")
    #endif
    bottomBarTop = top
    update()
  }

  #if DEBUG
    /// A short tag for this conversation in loop reports.
    private var probeTag: String {
      String(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000)
    }
  #endif

  private func update() {
    var next = InlineDecisionVisibility()
    for (id, placement) in placements
    where InlineDecisionVisibility.isOnScreen(
      placement, bottomBarTop: bottomBarTop, wasOnScreen: visibility.onScreen.contains(id))
    {
      next.onScreen.insert(id)
      if placement.showsApprove { next.approvable.insert(id) }
    }
    guard next != visibility else { return }
    #if DEBUG
      LoopProbe.record(
        "decision visibility \(probeTag)",
        "on screen \(next.onScreen.sorted()), bar top \(String(describing: bottomBarTop)), "
          + "placements \(placements)")
    #endif
    visibility = next
  }
}

extension View {
  /// Gives `target`'s Approve the emphasis, and Command-Return when it shows on `surface` and
  /// the draft does not own the shortcut.
  func decisionApproveShortcut(
    _ target: DecisionShortcutTarget?, on surface: DecisionSurface, owner: CommandReturnOwner?
  ) -> some View {
    decisionApproveShortcut(
      target?.cardID, isLive: owner != .send && target?.surface == surface)
  }

  /// Reports this inline card's placement to the conversation's ``DecisionSurfaces``.
  func reportsInlineDecision(_ cardID: String, showsApprove: Bool) -> some View {
    modifier(InlineDecisionReporter(cardID: cardID, showsApprove: showsApprove))
  }

  /// Marks the bar under the transcript (the dock and composer) so cards behind it are not
  /// counted as on screen.
  /// - Parameter surfaces: The conversation's tracker.
  /// - Returns: The view.
  public func decisionBottomBar(_ surfaces: DecisionSurfaces) -> some View {
    onGeometryChange(for: CGFloat.self) { proxy in
      proxy.frame(in: .global).minY.rounded()
    } action: { top in
      surfaces.setBottomBarTop(top)
    }
  }
}

private struct InlineDecisionReporter: ViewModifier {
  let cardID: String
  let showsApprove: Bool
  @Environment(DecisionSurfaces.self) private var surfaces: DecisionSurfaces?

  func body(content: Content) -> some View {
    if let surfaces {
      let showsApprove = showsApprove
      content
        .onGeometryChange(for: InlineDecisionPlacement?.self) { proxy in
          guard let viewport = proxy.bounds(of: .scrollView) else { return nil }
          let card = proxy.frame(in: .global).integral
          return InlineDecisionPlacement(
            card: card, viewport: viewport.offsetBy(dx: card.minX, dy: card.minY).integral,
            showsApprove: showsApprove)
        } action: { placement in
          surfaces.report(cardID, placement: placement)
        }
        .onDisappear { surfaces.report(cardID, placement: nil) }
    } else {
      content
    }
  }
}
