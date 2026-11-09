public import Observation
import SwiftUI

/// Tracks a tab dragged out of the strip so the content can preview and take the drop. The
/// shell puts one in the environment; the strip reports the pointer, the split view its frame.
@Observable
public final class TabDragTracker {
  /// How much of each side of a single pane is a drop target that splits the window.
  static let edgeShare = 0.3

  /// The dragged tab, while it is over the content.
  public private(set) var draggedID: String?
  /// Its pane in a split window.
  private(set) var draggedPane: TabPane?
  /// The pointer, in global coordinates, while it is below the strip.
  private(set) var location: CGPoint?
  /// The other pane, while the tab is over that pane's section of the strip.
  private(set) var section: TabPane?
  /// The content area, in global coordinates.
  @ObservationIgnored var contentFrame: CGRect = .zero
  /// The content shows two panes.
  @ObservationIgnored var isSplit = false
  /// Where the panes' divider is, in global coordinates, so the strip's sections line up.
  var dividerX: CGFloat?

  /// Creates a tracker.
  public init() {}

  /// The pane a release would show the dragged tab in. In a split it is the other pane, under
  /// the pointer or under the strip section the tab is over; else either edge of the content.
  public var target: TabPane? {
    if let section { return section }
    guard let location, contentFrame.width > 0, contentFrame.contains(location) else {
      return nil
    }
    if isSplit {
      let pane: TabPane = location.x < (dividerX ?? contentFrame.midX) ? .leading : .trailing
      return pane == draggedPane ? nil : pane
    }
    let share = (location.x - contentFrame.minX) / contentFrame.width
    if share < Self.edgeShare { return .leading }
    return share > 1 - Self.edgeShare ? .trailing : nil
  }

  /// The drag moved.
  /// - Parameters:
  ///   - id: The tab.
  ///   - pane: Its pane, in a split window.
  ///   - location: The pointer in global coordinates, or `nil` while it is over the strip.
  ///   - section: The other pane, while the pointer is over that pane's section of the strip.
  func update(id: String, pane: TabPane?, location: CGPoint?, section: TabPane? = nil) {
    if draggedID != id { draggedID = id }
    if draggedPane != pane { draggedPane = pane }
    if self.location != location { self.location = location }
    if self.section != section { self.section = section }
  }

  /// The drag ended.
  func end() {
    draggedID = nil
    draggedPane = nil
    location = nil
    section = nil
  }
}

/// The text a tab drags as on iPad, so only a tab from this app's strip drops into a pane.
enum TabDropPayload {
  static let prefix = "omnigent-tab:"

  static func text(for id: String) -> String { prefix + id }

  static func tabID(in text: String) -> String? {
    text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
  }
}
