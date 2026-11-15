public import Foundation
public import SwiftUI

/// A server window's Settings page, as Omnigent > Settings and the menu bar reach it.
public struct WindowSettingsPage {
  /// Whether the window shows Settings now.
  public var isShown: () -> Bool
  /// Shows Settings over the window's content, or goes back to that content.
  public var setShown: (Bool) -> Void

  /// Creates a page.
  /// - Parameters:
  ///   - isShown: Whether the window shows Settings now.
  ///   - setShown: Shows Settings, or goes back to the window's content.
  public init(isShown: @escaping () -> Bool, setShown: @escaping (Bool) -> Void) {
    self.isShown = isShown
    self.setShown = setShown
  }
}

/// Every server window's Settings page, and which of the windows is in front.
final class WindowSettingsPages {
  private var pages: [UUID: WindowSettingsPage] = [:]
  /// The windows from back to front: one that becomes key, or opens, goes last.
  private var recency: [UUID] = []
  /// Settings was asked for with no window open; the next window shows it.
  private(set) var awaitsWindow = false

  /// The front window that has a Settings page.
  var front: (instance: UUID, page: WindowSettingsPage)? {
    for instance in recency.reversed() {
      if let page = pages[instance] { return (instance, page) }
    }
    return nil
  }

  func register(_ page: WindowSettingsPage, for instance: UUID) {
    pages[instance] = page
    if !recency.contains(instance) { recency.append(instance) }
    guard awaitsWindow else { return }
    awaitsWindow = false
    page.setShown(true)
  }

  func becameKey(_ instance: UUID) {
    recency.removeAll { $0 == instance }
    recency.append(instance)
  }

  func remove(_ instance: UUID) {
    pages[instance] = nil
    recency.removeAll { $0 == instance }
  }

  func showInNextWindow() {
    awaitsWindow = true
  }
}

extension View {
  /// Lets Omnigent > Settings and the menu bar show Settings in this server window. Apply it
  /// beside `View.serverWindow(_:desktop:...)`, which forgets the page when the window closes.
  /// - Parameters:
  ///   - instance: The window's instance.
  ///   - desktop: The shell services.
  ///   - page: The window's Settings page.
  /// - Returns: The configured view.
  public func serverWindowSettings(
    _ instance: UUID, desktop: DesktopController, page: WindowSettingsPage
  ) -> some View {
    onAppear { desktop.registry.setSettingsPage(for: instance, page) }
  }
}
