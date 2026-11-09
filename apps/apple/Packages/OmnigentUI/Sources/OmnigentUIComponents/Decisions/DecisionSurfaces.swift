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

/// An inline card's frame and the part of its scroll view that isn't under a bar (the dock and
/// composer inset the scroll view), in the card's own coordinates.
nonisolated struct InlineDecisionPlacement: Hashable, Sendable {
  var card: CGRect
  var viewport: CGRect
}

/// The inline cards on screen, as the dock and the shortcut need them.
nonisolated struct InlineDecisionVisibility: Hashable, Sendable {
  var onScreen: Set<String> = []
  /// The on-screen cards whose inline surface shows Approve.
  var approvable: Set<String> = []

  /// Whether a card counts as on screen. It enters once half of it (or half the viewport, for a
  /// card taller than that) is visible, and leaves below a fifth, so the dock resizing as a card
  /// crosses the line never makes it flicker. A sliver never counts (``minimumVisible``): over a
  /// short viewport the dock collapsing would scroll the card away and bring it back, without end.
  /// - Parameters:
  ///   - placement: The card and its viewport.
  ///   - wasOnScreen: The card counted as on screen before this change.
  /// - Returns: Whether it is on screen now.
  static func isOnScreen(_ placement: InlineDecisionPlacement, wasOnScreen: Bool) -> Bool {
    let top = placement.viewport.minY
    let bottom = placement.viewport.maxY
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

/// Tracks which inline decision cards are on screen for one conversation. Each card decides for
/// itself; the dock reads ``visibility``, which only changes when a card enters or leaves.
@Observable
public final class DecisionSurfaces {
  private(set) var visibility = InlineDecisionVisibility()

  /// Creates an empty tracker.
  public init() {}

  /// Records whether an inline card is on screen, and whether it shows Approve when it is.
  func report(_ cardID: String, isOnScreen: Bool, showsApprove: Bool) {
    var next = visibility
    if isOnScreen {
      next.onScreen.insert(cardID)
    } else {
      next.onScreen.remove(cardID)
    }
    if isOnScreen, showsApprove {
      next.approvable.insert(cardID)
    } else {
      next.approvable.remove(cardID)
    }
    guard next != visibility else { return }
    #if DEBUG
      LoopProbe.record("decision visibility \(probeTag)", "on screen \(next.onScreen.sorted())")
    #endif
    visibility = next
  }

  #if DEBUG
    /// A short tag for this conversation in loop reports.
    private var probeTag: String {
      String(UInt(bitPattern: ObjectIdentifier(self).hashValue) % 10_000)
    }
  #endif
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

  /// Tells the conversation's ``DecisionSurfaces`` whether this inline card is on screen.
  func reportsInlineDecision(_ cardID: String, showsApprove: Bool) -> some View {
    modifier(InlineDecisionReporter(cardID: cardID, showsApprove: showsApprove))
  }
}

/// Reports whether its card is on screen rather than where it is: a resize's layout passes
/// disagree by a point and a bottom-anchored scroll view moves its content by more, so positions
/// flip within a frame, which SwiftUI logs as a cycling geometry action.
private struct InlineDecisionReporter: ViewModifier {
  let cardID: String
  let showsApprove: Bool
  @Environment(DecisionSurfaces.self) private var surfaces: DecisionSurfaces?
  @State private var isOnScreen = false

  func body(content: Content) -> some View {
    if let surfaces {
      content
        .onGeometryChange(for: Bool.self) { [isOnScreen] proxy in
          guard let viewport = proxy.bounds(of: .scrollView) else { return false }
          let card = CGRect(origin: .zero, size: proxy.size)
          return InlineDecisionVisibility.isOnScreen(
            InlineDecisionPlacement(card: card, viewport: viewport), wasOnScreen: isOnScreen)
        } action: { shows in
          isOnScreen = shows
          surfaces.report(cardID, isOnScreen: shows, showsApprove: showsApprove)
        }
        .onChange(of: showsApprove) { _, approves in
          surfaces.report(cardID, isOnScreen: isOnScreen, showsApprove: approves)
        }
        .onAppear { surfaces.report(cardID, isOnScreen: isOnScreen, showsApprove: showsApprove) }
        .onDisappear { surfaces.report(cardID, isOnScreen: false, showsApprove: showsApprove) }
    } else {
      content
    }
  }
}
