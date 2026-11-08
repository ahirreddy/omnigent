public import SwiftUI

extension EnvironmentValues {
  /// The view belongs to a tab that stays built while another tab shows (``KeptAliveTabs``):
  /// it takes no input, publishes no commands or toolbar and leaves its transcript as it was.
  @Entry public var isTabContentHidden = false
}

/// Shows one tab and keeps a few recently shown ones built underneath, hidden, so switching back
/// to them shows their views as they were (scroll position included) instead of building them
/// again. Hidden tabs take no clicks, are hidden from accessibility, show no toolbar, commands
/// or right panel (see ``EnvironmentValues/isTabContentHidden``). The shown conversation's
/// toolbar items are placed here, so switching tabs updates them instead of replacing them.
public struct KeptAliveTabs<Item: Identifiable, Content: View>: View {
  private let items: [Item]
  private let shownID: Item.ID
  private let content: (Item) -> Content
  @State private var sizes = KeptAliveSizes()

  /// Creates the view.
  /// - Parameters:
  ///   - items: The tabs to keep built, the shown one among them, in a stable order.
  ///   - shownID: The tab on screen.
  ///   - content: A tab's content.
  public init(
    _ items: [Item], shownID: Item.ID, @ViewBuilder content: @escaping (Item) -> Content
  ) {
    self.items = items
    self.shownID = shownID
    self.content = content
  }

  /// The view.
  public var body: some View {
    KeptAliveLayout(sizes: sizes) {
      ForEach(items) { item in
        let isHidden = item.id != shownID
        HeldWhileHidden(content: content(item), isHidden: isHidden)
          .equatable()
          .modifier(HiddenTabContent(isHidden: isHidden))
          .layoutValue(key: KeptAliveKey.self, value: isHidden)
      }
    }
    .hostsConversationToolbar()
  }
}

/// The column's last measured size, kept outside observation: layout reads and writes it, on
/// the main thread only.
nonisolated private final class KeptAliveSizes: @unchecked Sendable {
  var lastMeasured: CGSize?
}

/// Whether a tab is hidden, so the layout can hold its size through placeholder passes.
nonisolated private struct KeptAliveKey: LayoutValueKey {
  static let defaultValue = false
}

/// A `ZStack` that proposes every tab the whole space, except while the split view lays the
/// column out at its placeholder minimum (``UnmeasuredMinimum``): hidden tabs then keep the
/// column's last measured size. A hidden tab at another size than the column (frozen at a size
/// from the column's first passes, or laid out smaller than its content) has its right panel
/// loop on constraint passes.
private struct KeptAliveLayout: Layout {
  let sizes: KeptAliveSizes

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let shown = subviews.filter { !$0[KeptAliveKey.self] }
    let sizes = shown.map { $0.sizeThatFits(proposal) }
    return CGSize(
      width: sizes.map(\.width).max() ?? proposal.replacingUnspecifiedDimensions().width,
      height: sizes.map(\.height).max() ?? proposal.replacingUnspecifiedDimensions().height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    if Self.isMeasured(bounds.size) { sizes.lastMeasured = bounds.size }
    let hiddenSize = sizes.lastMeasured ?? bounds.size
    for subview in subviews {
      let size = subview[KeptAliveKey.self] ? hiddenSize : bounds.size
      subview.place(at: bounds.origin, proposal: ProposedViewSize(size))
    }
  }

  /// Whether `size` is the column's, not that of a pass made while the split view sized the
  /// column at its placeholder minimum in either dimension, or before it had a size.
  static func isMeasured(_ size: CGSize) -> Bool {
    let placeholder = UnmeasuredMinimum.column
    return size.width > placeholder.width && size.height > placeholder.height
  }
}

/// A tab's content that ignores new values from above while it stays hidden: the window
/// re-renders for the sidebar and the tab strip, and a hidden conversation need not follow.
/// Its own observed state still updates it; it takes the latest values when it shows again.
private struct HeldWhileHidden<Content: View>: View, Equatable {
  let content: Content
  let isHidden: Bool

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isHidden && rhs.isHidden
  }

  var body: some View { content }
}

/// A kept tab's content while another tab shows: invisible, inert and quiet.
private struct HiddenTabContent: ViewModifier {
  let isHidden: Bool

  func body(content: Content) -> some View {
    content
      .transformEnvironment(\.isActiveTabPane) { if isHidden { $0 = false } }
      .environment(\.isTabContentHidden, isHidden)
      .opacity(isHidden ? 0 : 1)
      .allowsHitTesting(!isHidden)
      .accessibilityHidden(isHidden)
      .zIndex(isHidden ? 0 : 1)
  }
}
