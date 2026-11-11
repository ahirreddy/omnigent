public import SwiftUI

extension EnvironmentValues {
  /// The view belongs to a tab that stays built while another tab shows (``KeptAliveTabs``):
  /// it takes no input, publishes no commands or toolbar and leaves its transcript as it was.
  @Entry public var isTabContentHidden = false
}

/// Where a kept tab goes: out of sight, over the whole content, or in one pane of a split.
nonisolated enum KeptTabPlace: Hashable, Sendable {
  /// Built, and not on screen.
  case hidden
  /// The only tab on screen.
  case whole
  /// One of two tabs side by side; the focused pane's tab publishes commands and toolbar.
  case pane(TabPane, isFocused: Bool)

  /// The pane the tab shows in, when the content is split.
  var pane: TabPane? {
    if case .pane(let pane, _) = self { return pane }
    return nil
  }

  /// Whether the tab is the quiet one of two on screen.
  var isUnfocusedPane: Bool {
    if case .pane(_, isFocused: false) = self { return true }
    return false
  }
}

/// Shows one tab, or two side by side (``TabSplitView``), and keeps a few recently shown ones
/// built underneath, hidden, so switching back to them shows their views as they were (scroll
/// position included) instead of building them again. Hidden tabs take no clicks, are hidden
/// from accessibility, show no toolbar, commands or right panel (see
/// ``EnvironmentValues/isTabContentHidden``). The shown conversation's toolbar items are placed
/// here, so switching tabs updates them instead of replacing them.
public struct KeptAliveTabs<Item: Identifiable, Content: View>: View {
  private let items: [Item]
  private let place: (Item) -> KeptTabPlace
  private let fraction: Double
  private let hinge: CGRect?
  private let content: (Item) -> Content
  @State private var sizes = KeptAliveSizes()
  /// The column has had a size of its own. A conversation built during the split view's
  /// placeholder pass builds rows at that width, and takes the column's width after them.
  @State private var hasColumnSize = !KeptAliveLayout.startsAtPlaceholder

  /// Creates the view.
  /// - Parameters:
  ///   - items: The tabs to keep built, the shown one among them, in a stable order.
  ///   - shownID: The tab on screen.
  ///   - content: A tab's content.
  public init(
    _ items: [Item], shownID: Item.ID, @ViewBuilder content: @escaping (Item) -> Content
  ) {
    self.init(
      items, fraction: 0.5, hinge: nil, place: { $0.id == shownID ? .whole : .hidden },
      content: content)
  }

  /// Creates the view for content that may be split in two panes.
  /// - Parameters:
  ///   - items: The tabs to keep built, the shown ones among them, in a stable order.
  ///   - fraction: The left pane's share of the width.
  ///   - hinge: An unfolded device's hinge, which the panes sit either side of.
  ///   - place: Where a tab goes.
  ///   - content: A tab's content.
  init(
    _ items: [Item], fraction: Double, hinge: CGRect?, place: @escaping (Item) -> KeptTabPlace,
    @ViewBuilder content: @escaping (Item) -> Content
  ) {
    self.items = items
    self.fraction = fraction
    self.hinge = hinge
    self.place = place
    self.content = content
  }

  /// The view.
  public var body: some View {
    KeptAliveLayout(sizes: sizes, fraction: fraction, hinge: hinge) {
      if hasColumnSize {
        ForEach(items) { item in
          let place = place(item)
          let isHidden = place == .hidden
          HeldWhileHidden(content: content(item), isHidden: isHidden)
            .equatable()
            .modifier(PaneTabContent(place: place))
            .modifier(HiddenTabContent(isHidden: isHidden))
            .layoutValue(key: KeptAliveKey.self, value: place)
        }
      }
    }
    .onGeometryChange(for: Bool.self) { proxy in
      KeptAliveLayout.isColumnHeight(proxy.size.height)
    } action: { isColumnHeight in
      if isColumnHeight { hasColumnSize = true }
    }
    .hostsConversationToolbar()
  }
}

/// A size a layout last had, kept outside observation: layout reads and writes it, on the main
/// thread only.
nonisolated private final class KeptAliveSizes: @unchecked Sendable {
  var lastMeasured: CGSize?
}

/// Where a tab goes, so the layout can place it, and hold a hidden one's size through
/// placeholder passes.
nonisolated private struct KeptAliveKey: LayoutValueKey {
  static let defaultValue = KeptTabPlace.whole
}

/// A `ZStack` that proposes a whole tab the whole space and a pane's tab its pane, except while
/// the split view lays the column out at its placeholder minimum (``UnmeasuredMinimum``):
/// hidden tabs then keep the column's last measured size. A hidden tab at another size than the
/// column (frozen at a size from the column's first passes, or laid out smaller than its
/// content) has its right panel loop on constraint passes.
private struct KeptAliveLayout: Layout {
  let sizes: KeptAliveSizes
  let fraction: Double
  let hinge: CGRect?

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    LayoutTally.count("kept tabs measure")
    // Panes fill what is offered, as hidden tabs do: only a whole tab is measured.
    let shown = subviews.filter { $0[KeptAliveKey.self] == .whole }
    let sizes = shown.map { $0.sizeThatFits(proposal) }
    return CGSize(
      width: sizes.map(\.width).max() ?? proposal.replacingUnspecifiedDimensions().width,
      height: sizes.map(\.height).max() ?? proposal.replacingUnspecifiedDimensions().height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    LayoutTally.count("kept tabs place")
    if Self.isMeasured(bounds.size) { sizes.lastMeasured = bounds.size }
    let hiddenSize = sizes.lastMeasured ?? bounds.size
    let panes = TabSplitLayout(width: bounds.width, fraction: fraction, hinge: hinge)
    for subview in subviews {
      switch subview[KeptAliveKey.self] {
      case .hidden:
        subview.place(at: bounds.origin, proposal: ProposedViewSize(hiddenSize))
      case .whole:
        subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
      case .pane(let pane, _):
        let frame = panes.frame(of: pane, in: bounds)
        subview.place(
          at: CGPoint(x: frame.midX, y: frame.midY), anchor: .center,
          proposal: ProposedViewSize(frame.size))
      }
    }
  }

  /// Whether a column is first laid out at the placeholder: on Mac, where the split view is.
  static var startsAtPlaceholder: Bool {
    #if os(macOS)
      true
    #else
      false
    #endif
  }

  /// Whether `height` is a column's own: no window is short enough for a column of the
  /// placeholder's height.
  static func isColumnHeight(_ height: CGFloat) -> Bool {
    height > UnmeasuredMinimum.column.height
  }

  /// Whether `size` is the column's, not that of a pass made while the split view sized the
  /// column at its placeholder minimum in either dimension, or before it had a size.
  static func isMeasured(_ size: CGSize) -> Bool {
    let placeholder = UnmeasuredMinimum.column
    return size.width > placeholder.width && size.height > placeholder.height
  }
}

/// A tab's content that ignores new values from above while it is hidden: the window re-renders
/// for the sidebar and the tab strip, and for the switch that hides the tab, and a hidden
/// conversation need not follow. Its own observed state still updates it; it takes the latest
/// values when it shows again.
private struct HeldWhileHidden<Content: View>: View, Equatable {
  let content: Content
  let isHidden: Bool

  static func == (lhs: Self, rhs: Self) -> Bool {
    rhs.isHidden
  }

  var body: some View { content }
}

extension View {
  /// On Mac, keeps the view at the size it last had on screen while its tab is hidden
  /// (``HeldTabSize``). Elsewhere the view is unchanged.
  @ViewBuilder func holdsSizeWhileTabHidden() -> some View {
    #if os(macOS)
      modifier(HoldsSizeWhileTabHidden())
    #else
      self
    #endif
  }
}

#if os(macOS)
  /// Reads the tab's state for ``HeldTabSize``, so a switch runs this body and not the content's.
  private struct HoldsSizeWhileTabHidden: ViewModifier {
    @Environment(\.isTabContentHidden) private var isHidden
    @State private var sizes = KeptAliveSizes()

    func body(content: Content) -> some View {
      HeldTabSize(isHidden: isHidden, sizes: sizes) { content }
    }
  }

  /// Lays a hidden tab's content out at the size it last had on screen, so resizing the window
  /// behind another tab moves nothing in it. It takes the size it is offered either way: what
  /// holds it, such as the right panel's column, still follows the window.
  private struct HeldTabSize: Layout {
    let isHidden: Bool
    let sizes: KeptAliveSizes

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      LayoutTally.count(isHidden ? "hidden tab measure" : "shown tab measure")
      let offered = proposal.replacingUnspecifiedDimensions()
      return isHidden ? offered : subviews.first?.sizeThatFits(proposal) ?? offered
    }

    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      LayoutTally.count(isHidden ? "hidden tab place" : "shown tab place")
      // Not a pass at the split view's placeholder: content held that small is not the tab's.
      if !isHidden, KeptAliveLayout.isMeasured(bounds.size) { sizes.lastMeasured = bounds.size }
      let size = isHidden ? sizes.lastMeasured ?? bounds.size : bounds.size
      for subview in subviews {
        subview.place(at: bounds.origin, proposal: ProposedViewSize(size))
      }
    }
  }
#endif

/// A kept tab's content in a split's pane: clipped to the pane, and quiet in the pane without
/// focus. The same views either way, so splitting and unsplitting rebuild nothing.
private struct PaneTabContent: ViewModifier {
  let place: KeptTabPlace

  func body(content: Content) -> some View {
    content
      .transformEnvironment(\.isActiveTabPane) { if place.isUnfocusedPane { $0 = false } }
      .clipShape(PaneClip(isPane: place.pane != nil))
  }
}

/// A pane's bounds, or no clip at all for a whole tab, whose content reaches under the toolbar
/// and a floating sidebar. A rectangle either way, so the clip is a bounds clip, not a mask.
nonisolated private struct PaneClip: Shape {
  /// Further than any content reaches outside its bounds.
  static let unclipped: CGFloat = 100_000

  let isPane: Bool

  func path(in rect: CGRect) -> Path {
    Path(isPane ? rect : rect.insetBy(dx: -Self.unclipped, dy: -Self.unclipped))
  }
}

/// A kept tab's content while another tab shows: invisible, inert and quiet.
struct HiddenTabContent: ViewModifier {
  let isHidden: Bool

  func body(content: Content) -> some View {
    content
      .modifier(HeldLayoutWidth(isHidden: isHidden))
      .transformEnvironment(\.isActiveTabPane) { if isHidden { $0 = false } }
      .environment(\.isTabContentHidden, isHidden)
      // One layer per tab: hiding it changes that layer. Without it, each AppKit view in the
      // tab (text, scroll and glass views) is taken out of the window and put back.
      .compositingGroup()
      .opacity(isHidden ? 0 : 1)
      .allowsHitTesting(!isHidden)
      .accessibilityHidden(isHidden)
      .zIndex(isHidden ? 0 : 1)
  }
}

/// The width class a tab last had on screen, kept outside observation: only a body writes it.
private final class HeldLayoutWidthValue {
  var onScreen: LayoutWidth?
}

/// Keeps a hidden tab at the width class it last had on screen: a window resized across the
/// compact width behind another tab renders nothing in it. It takes the column's class in the
/// pass that shows it; a tab that never showed follows the column.
private struct HeldLayoutWidth: ViewModifier {
  let isHidden: Bool
  @Environment(\.layoutWidth) private var layoutWidth
  @State private var held = HeldLayoutWidthValue()

  func body(content: Content) -> some View {
    let width = isHidden ? held.onScreen ?? layoutWidth : layoutWidth
    if !isHidden { held.onScreen = width }
    return content.environment(\.layoutWidth, width)
  }
}
