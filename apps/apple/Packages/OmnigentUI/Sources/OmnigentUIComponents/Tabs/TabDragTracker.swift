public import Observation
import SwiftUI

/// Tracks a tab dragged out of the strip so the content can preview and take the drop. The
/// shell puts one in the environment; the strip reports the pointer, the split view its frame.
@Observable
public final class TabDragTracker {
  /// How much of each side of the content is a drop target for that pane.
  static let edgeShare = 0.3

  /// The dragged tab, while it is over the content.
  public private(set) var draggedID: String?
  /// Its pane in a split window.
  private(set) var draggedPane: TabPane?
  /// The pointer, in global coordinates, while it is below the strip.
  private(set) var location: CGPoint?
  /// The content area, in global coordinates.
  @ObservationIgnored var contentFrame: CGRect = .zero
  /// The content shows two panes.
  @ObservationIgnored var isSplit = false
  /// Where the panes' divider is, in global coordinates, so the strip's sections line up.
  var dividerX: CGFloat?

  /// Creates a tracker.
  public init() {}

  /// The pane a release would show the dragged tab in: either edge of the content, and not
  /// the pane it is already in.
  public var target: TabPane? {
    guard let location, contentFrame.width > 0, contentFrame.contains(location) else {
      return nil
    }
    let share = (location.x - contentFrame.minX) / contentFrame.width
    let pane: TabPane
    if share < Self.edgeShare {
      pane = .leading
    } else if share > 1 - Self.edgeShare {
      pane = .trailing
    } else {
      return nil
    }
    if isSplit, draggedPane == pane { return nil }
    return pane
  }

  /// The drag moved.
  /// - Parameters:
  ///   - id: The tab.
  ///   - pane: Its pane, in a split window.
  ///   - location: The pointer in global coordinates, or `nil` while it is over the strip.
  func update(id: String, pane: TabPane?, location: CGPoint?) {
    if draggedID != id { draggedID = id }
    if draggedPane != pane { draggedPane = pane }
    if self.location != location { self.location = location }
  }

  /// The drag ended.
  func end() {
    draggedID = nil
    draggedPane = nil
    location = nil
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
