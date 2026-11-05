public import SwiftUI

/// Reads a tab's live status line for its tooltip (for example `Waiting for you · 2 requests`).
/// The tab reads it in its own body, so only the tab redraws when the line changes, not the
/// window that builds the strip's state.
public struct TabStatusDetails: Equatable {
  private let owner: ObjectIdentifier
  private let read: @MainActor (String) -> String?

  /// Creates the reader.
  /// - Parameters:
  ///   - owner: The object the reader reads from; readers with the same owner are equal.
  ///   - read: The status line of the tab with this id, or `nil` for the status's own label.
  public init(owner: AnyObject, read: @escaping @MainActor (String) -> String?) {
    self.owner = ObjectIdentifier(owner)
    self.read = read
  }

  /// The status line of a tab.
  /// - Parameter tabID: The tab.
  /// - Returns: The line, or `nil` when the tab has none.
  @MainActor public func detail(of tabID: String) -> String? { read(tabID) }

  /// Equal when they read from the same owner.
  public static func == (lhs: Self, rhs: Self) -> Bool { lhs.owner == rhs.owner }
}

extension EnvironmentValues {
  /// Reads the selected tab's status line for the strip's tooltip; `nil` uses
  /// ``TabItemState/statusDetail``.
  @Entry public var tabStatusDetails: TabStatusDetails?
}
