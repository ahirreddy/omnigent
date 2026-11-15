public import SwiftUI

/// A Settings tab: one of the shell's own, or one the app adds from packages the desktop shell
/// does not depend on (for example Appearance from the UI components, or Terminal from the
/// terminal package).
public struct SettingsTabItem: Identifiable {
  /// The tab title, also its identity.
  public let title: String
  /// An SF Symbol.
  public let systemImage: String
  /// The tab's content, usually a `Form`.
  public let content: AnyView
  /// The content sizes itself (a split view) instead of taking the form width.
  public let isWide: Bool

  /// Creates a tab.
  /// - Parameters:
  ///   - title: The tab title.
  ///   - systemImage: An SF Symbol.
  ///   - isWide: The content sizes itself instead of taking the form width.
  ///   - content: The tab's content.
  public init(
    _ title: String, systemImage: String, isWide: Bool = false,
    @ViewBuilder content: () -> some View
  ) {
    self.title = title
    self.systemImage = systemImage
    self.isWide = isWide
    self.content = AnyView(content())
  }

  /// The title.
  public var id: String { title }
}
