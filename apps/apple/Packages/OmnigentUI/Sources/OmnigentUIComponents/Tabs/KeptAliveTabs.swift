public import SwiftUI

extension EnvironmentValues {
  /// The view belongs to a tab that stays built while another tab shows (``KeptAliveTabs``):
  /// it takes no input, publishes no commands or toolbar and leaves its transcript as it was.
  @Entry public var isTabContentHidden = false
}

/// Shows one tab and keeps a few recently shown ones built underneath, hidden, so switching back
/// to them shows their views as they were (scroll position included) instead of building them
/// again. Hidden tabs take no clicks, are hidden from accessibility, show no toolbar, commands
/// or right panel (see ``EnvironmentValues/isTabContentHidden``).
public struct KeptAliveTabs<Item: Identifiable, Content: View>: View {
  private let items: [Item]
  private let shownID: Item.ID
  private let content: (Item) -> Content

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
    ZStack {
      ForEach(items) { item in
        content(item).modifier(HiddenTabContent(isHidden: item.id != shownID))
      }
    }
  }
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
