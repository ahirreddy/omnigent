public import CoreGraphics

/// The tab overview's card pictures: what each tab looked like the last time the overview
/// opened over it. Only the shown tab is captured, when the overview opens, so no hidden tab is
/// ever drawn for a picture; a tab never captured shows its icon and title instead.
@MainActor
public final class TabThumbnails {
  /// The app's pictures, shared by its windows (tab ids are unique across sessions).
  public static let shared = TabThumbnails()

  /// The most pictures kept; the least recently captured go first.
  let capacity: Int
  /// The longest side a picture keeps, in pixels: enough for the zoom's first frame.
  let longestSide: CGFloat
  private var images: [String: CGImage] = [:]
  /// Tab ids, least recently captured first.
  private var order: [String] = []

  /// Creates an empty store.
  /// - Parameters:
  ///   - capacity: The most pictures kept.
  ///   - longestSide: The longest side a picture keeps, in pixels.
  public init(capacity: Int = 10, longestSide: CGFloat = 1_000) {
    self.capacity = max(1, capacity)
    self.longestSide = longestSide
  }

  /// A tab's picture, if it has one.
  /// - Parameter tabID: The tab.
  /// - Returns: Its last picture.
  public func image(for tabID: String) -> CGImage? { images[tabID] }

  /// Keeps a tab's new picture, dropping the oldest past ``capacity``.
  /// - Parameters:
  ///   - image: The picture.
  ///   - tabID: The tab.
  public func store(_ image: CGImage, for tabID: String) {
    images[tabID] = image
    order.removeAll { $0 == tabID }
    order.append(tabID)
    while order.count > capacity {
      images[order.removeFirst()] = nil
    }
  }

  /// Forgets a closed tab's picture.
  /// - Parameter tabID: The tab.
  public func remove(_ tabID: String) {
    images[tabID] = nil
    order.removeAll { $0 == tabID }
  }

  /// The drawing scale for a view of `size` points, so its longest side stays within
  /// ``longestSide`` pixels and never above `screenScale`.
  /// - Parameters:
  ///   - size: The view's size in points.
  ///   - screenScale: The screen's scale.
  /// - Returns: The scale to draw at.
  public func scale(for size: CGSize, screenScale: CGFloat) -> CGFloat {
    let side = max(size.width, size.height)
    guard side > 0 else { return 1 }
    return min(screenScale, longestSide / side)
  }
}
