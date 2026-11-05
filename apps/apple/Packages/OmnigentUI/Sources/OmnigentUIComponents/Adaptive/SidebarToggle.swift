public import SwiftUI

/// Shows or hides a window's sidebar from outside ``AppShell`` (the palette's Toggle Sidebar and
/// its Option-Command-[ alias), where iPad has no responder-chain action for it. The shell fills
/// in ``toggle`` on each update; keep one per window in `@State`.
@MainActor
public final class SidebarToggle {
  var toggle: (@MainActor () -> Void)?

  /// Creates an empty toggle.
  public init() {}

  /// Shows the sidebar when hidden, and hides it otherwise.
  public func callAsFunction() { toggle?() }

  /// The visibility after a toggle: a hidden sidebar shows, a shown one hides.
  /// - Parameter visibility: The current visibility.
  /// - Returns: The new visibility.
  nonisolated static func toggled(_ visibility: NavigationSplitViewVisibility)
    -> NavigationSplitViewVisibility
  {
    visibility == .detailOnly ? .all : .detailOnly
  }
}

extension EnvironmentValues {
  /// The window's sidebar toggle, for ``AppShell`` to drive; `nil` where nothing toggles it.
  @Entry public var sidebarToggle: SidebarToggle?
}
