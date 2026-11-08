public import SwiftUI

extension EnvironmentValues {
  /// The view belongs to a tab that stays built while another tab shows (``KeptAliveTabs``):
  /// it takes no input, publishes no commands or toolbar and leaves its transcript as it was.
  @Entry public var isTabContentHidden = false
}

/// Shows one tab and keeps a few recently shown ones built underneath, hidden, so switching back
/// to them shows their views as they were (scroll position included) instead of building them
/// again. Hidden tabs take no clicks, are hidden from accessibility, show no toolbar, commands
/// or right panel (see ``EnvironmentValues/isTabContentHidden``). Hidden tabs keep the size they
/// last showed at, so a window resize or rotation lays out only the shown one. The shown
/// conversation's toolbar items are placed here, so switching tabs updates them instead of
/// replacing them.
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
          .layoutValue(key: KeptAliveKey.self, value: isHidden ? String(describing: item.id) : nil)
      }
    }
    .hostsConversationToolbar()
  }
}

/// Each hidden tab's last shown size, kept outside observation: layout reads and writes it, on
/// the main thread only.
nonisolated private final class KeptAliveSizes: @unchecked Sendable {
  var byID: [String: CGSize] = [:]
  var shownSize: CGSize?
}

/// A hidden tab's id, so the layout can hold its size; `nil` for the shown tab.
nonisolated private struct KeptAliveKey: LayoutValueKey {
  static let defaultValue: String? = nil
}

/// A `ZStack` that proposes the shown tab the whole space and each hidden tab the size it had
/// when it was last shown: an unchanged proposal, so resizing does not lay hidden tabs out again.
private struct KeptAliveLayout: Layout {
  let sizes: KeptAliveSizes

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let shown = subviews.filter { $0[KeptAliveKey.self] == nil }
    let sizes = shown.map { $0.sizeThatFits(proposal) }
    return CGSize(
      width: sizes.map(\.width).max() ?? proposal.replacingUnspecifiedDimensions().width,
      height: sizes.map(\.height).max() ?? proposal.replacingUnspecifiedDimensions().height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    // The shown tab's size, or the last one it had during a pass before the column has its size.
    if Self.isMeasured(bounds.size) { sizes.shownSize = bounds.size }
    for subview in subviews {
      guard let id = subview[KeptAliveKey.self] else {
        subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        continue
      }
      // A tab hidden since before it was measured takes the shown tab's size.
      let size = sizes.byID[id] ?? sizes.shownSize ?? bounds.size
      if Self.isMeasured(size) { sizes.byID[id] = size }
      subview.place(at: bounds.origin, proposal: ProposedViewSize(size))
    }
    // A shown tab's frozen size is dropped, so it freezes at its newest size when hidden again.
    let hidden = Set(subviews.compactMap { $0[KeptAliveKey.self] })
    sizes.byID = sizes.byID.filter { hidden.contains($0.key) }
  }

  /// Whether `size` is the column's, not that of a pass made while the split view sized the
  /// column at its placeholder minimum (``UnmeasuredMinimum``) in either dimension, or before it
  /// had a size. A tab
  /// frozen at that minimum lays its right panel out smaller than its content.
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
